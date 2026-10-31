import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQLibrary
import SQTimelineUI
import SQUIKit

/// Window > Keystones for both shared shells (the Mac `EditorPanels+Keystones` with `KeystonesPanelView`, translated
/// first in Windows `AppController+TimelineEditors`): the `KeystonesPanelModel` list kept in step with the Library's
/// preset store, the shared `KeystonePalette` (floating over the timeline area or docked in a dock card), drags onto
/// clips, double-click and menu Apply, Save Keystone from Selected Clip, Edit Curve, Delete / Reset to Built-in.
/// The timeline panel stays a value in the app, reached through `withTimeline`.
/// Coordinates: `palette.frame` in window points, events arrive in pixels.
@MainActor
public final class KeystonesHost {
    public var palette = KeystonePalette()
    public let model = KeystonesPanelModel()
    private let session: EditorSession
    private let shell: ShellHost
    private let menus: MenuController
    private let store: PresetStore
    var options: PanelStripOptions?
    public var withTimeline: (_ change: (inout TimelinePanel) -> Void) -> Void = { _ in }
    /// The timeline's host, for the bridge that applies a drop.
    public var timelineHost: () -> TimelineHost? = { nil }
    /// The clip shown in Effect Controls when the point (window points) is over that card (the Mac `effectView.onDropKeystone`).
    public var inspectorDropClip: (@MainActor (CGPoint) -> Clip.ID?)?
    /// Edit Curve: the shared ease popover (`InspectorHost.openEase`), anchor in window points.
    public var openEase: ((any EaseCurveSource, CGRect) -> Void)?

    public init(session: EditorSession, menus: MenuController, shell: ShellHost, store: PresetStore = LibraryStores.presetStore,
                loadLibrary: Bool = true) {
        self.session = session
        self.shell = shell
        self.menus = menus
        self.store = store
        model.onSave = { [weak self] k in Task { @MainActor in _ = await self?.storeKeystone(k) } }
        model.onSaveStored = { [weak self] k in await self?.storeKeystone(k) ?? false }
        model.onDelete = { [weak self, store] id in
            Task { @MainActor in
                try? await store.delete(id)
                await self?.reload()
            }
        }
        if loadLibrary { Task { @MainActor [weak self] in await self?.reload() } }
    }

    /// The docked panel: its "..." sits in the dock's tab strip (the Mac panel header's options button).
    public func dock(in dock: ShellDock) {
        let o = PanelStripOptions(panel: .keystones, dock: dock)
        o.onOpen = { [weak self] p in self?.showMenu(nil, options: true, at: p) }
        options = o
    }

    public func reload() async {
        model.presets = await store.presets(kind: .keystone)
    }

    // MARK: Frame

    /// Floating over the timeline area (Windows), window points.
    public func layout(floatingIn area: CGRect, scale: Float, theme: DrawTheme) {
        palette.theme = theme
        if palette.isVisible {
            palette.keystones = model.keystones
            palette.changed = Set(model.keystones.filter { $0.isBuiltIn && model.canDelete($0.id) }.map(\.id))
        }
        palette.layout(in: area, scale: scale)
    }

    /// Docked in its dock card (nil: the tab is not shown), window points.
    public func layout(docked card: CGRect?, scale: Float, theme: DrawTheme) {
        palette.theme = theme
        palette.keystones = model.keystones
        palette.changed = Set(model.keystones.filter { $0.isBuiltIn && model.canDelete($0.id) }.map(\.id))
        palette.layout(docked: card, scale: scale)
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        options?.draw(&c, theme: theme)
        palette.draw(&c)
    }

    // MARK: Events

    /// True when the panel took the event (pointer moves go on).
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        if options?.handle(e, scale: scale) == true { return true }
        if case .mouseMoved(let x, let y) = e, palette.isVisible {
            let k = CGFloat(max(palette.scale, 0.01))
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            if palette.frame.contains(p) { HostHover.current.offerTip(palette.help(at: p)) }
        }
        guard let events = palette.handle(e) else { return false }
        // A click selects the row in the model too (Delete, the "..." menu and Edit Curve read `model.selected`).
        if model.selectedID != palette.selectedID, palette.selectedID != nil { model.selectedID = palette.selectedID }
        for ev in events { apply(ev) }
        if case .mouseMoved = e { return false }
        return true
    }

    func apply(_ ev: KeystonePaletteEvent) {
        switch ev {
        case .drag(let ks, let x, let y):
            withTimeline { p in if p.contains(x: x, y: y) { _ = p.keystoneHover(ks, x: x, y: y) } else { p.keystoneExit() } }
        case .drop(let ks, let x, let y):
            var actions: [TimelineAction] = []
            var overTimeline = false
            withTimeline { p in
                overTimeline = p.contains(x: x, y: y)
                if overTimeline { actions = p.keystoneDrop(ks, x: x, y: y) } else { p.keystoneExit() }
            }
            // Released on Effect Controls: the keystone lands on the clip shown there, whole clip.
            if !overTimeline, let clip = inspectorDropClip?(CGPoint(x: CGFloat(x / palette.scale), y: CGFloat(y / palette.scale))) {
                apply(ks, to: clip)
                return
            }
            let h = timelineHost()
            for a in actions { if let m = TimelineSessionBridge.apply(a, to: session, host: h) { shell.onStatus?(m) } }
        case .cancel:
            withTimeline { $0.keystoneExit() }
        case .apply(let ks):
            applyToSelection(ks)
        case .menu(let ks, let p):
            showMenu(ks, options: false, at: p)
        case .options(let p):
            showMenu(nil, options: true, at: p)
        case .delete(let ks):
            delete(ks)
        }
    }

    // MARK: Actions

    /// The menu actions (the Mac panel's `onApply`, `onSaveFromClip`, Edit Curve, `setEasing`, `onDelete`).
    public func actions() -> KeystonePaletteActions {
        KeystonePaletteActions(
            apply: { [weak self] k in self?.applyToSelection(k) },
            saveFromClip: { [weak self] in self?.saveFromSelectedClip() },
            editCurve: { [weak self] k in
                guard let self else { return }
                model.selectedID = k.id
                palette.selectedID = k.id
                let top = palette.isDocked ? palette.frame.minY : palette.frame.minY + KeystonePalette.headerHeight
                openEase?(KeystoneEaseSource(model: model, id: k.id), CGRect(x: palette.frame.minX, y: top, width: 1, height: 1))
            },
            useKeyframeEasing: { [weak self] k in self?.model.setEasing(nil, for: k.id) },
            delete: { [weak self] k in self?.delete(k) })
    }

    /// The Mac panel's apply: the keystone's own placement on the whole selected video clip, then its bar.
    public func applyToSelection(_ ks: Keystone) {
        guard let clip = session.singleSelectedClip, clip.kind == .video else {
            shell.onStatus?(SQL10n.format("Select a video clip to apply “%@”.", ks.name)); return
        }
        apply(ks, to: clip.id)
    }

    /// The keystone's own placement on the whole clip, then its bar on the timeline.
    func apply(_ ks: Keystone, to clipID: Clip.ID) {
        guard let landed = session.applyKeystone(ks, to: clipID, span: nil) else {
            shell.onStatus?(session.lastError ?? SQL10n.format("“%@” could not be applied.", ks.name)); return
        }
        let now = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }
        withTimeline { $0.setKeystoneBar(KeystoneBar(clip: clipID, span: landed, name: ks.name), clip: now) }
    }

    /// Delete Keystone / Reset to Built-in: only for a keystone the user saved or changed.
    public func delete(_ k: Keystone) {
        guard model.canDelete(k.id) else { return }
        model.onDelete?(k.id)
    }

    /// Delete on the selection (Edit > Delete while the panel has the selection, the Mac `deleteSelection`).
    public func deleteSelection() {
        guard let k = model.selected else { return }
        delete(k)
    }

    /// Right-click on a row (nil: on empty space) or the "...": the Mac panel's menus at `p` (window points).
    public func showMenu(_ k: Keystone?, options: Bool, at p: CGPoint) {
        if let k { model.selectedID = k.id; palette.selectedID = k.id }
        let items = options ? KeystonePalette.optionItems(selected: model.selected, actions())
            : KeystonePalette.contextItems(for: k, canDelete: k.map { model.canDelete($0.id) } ?? false, actions())
        menus.present(items: items, at: p, pointer: p)
    }

    /// The Mac "Save Keystone" sheet: a name, then the clip's Position, Scale, Rotation and Opacity keys go to the Library.
    public func saveFromSelectedClip() {
        guard let clip = session.singleSelectedClip, session.keystoneFromSelectedClip(name: "x") != nil else {
            shell.onStatus?(SQL10n.string("Select one video clip with at least two keyframes on Position, Scale, Rotation or Opacity."))
            return
        }
        let d = ShellDialog(SQL10n.string("Save Keystone"),
                            informative: SQL10n.string("Saves the keyframes of Position, Scale, Rotation and Opacity as a reusable keystone."))
        d.form = ShellForm([.field(id: "name", label: SQL10n.string("Name"), value: clip.name)])
        d.addButton(SQL10n.string("Save"))
        d.addButton(SQL10n.string("Cancel"), role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first else { return }
            let name = PresetSaveSheet.resolvedName(d.form?.text("name") ?? "", fallback: clip.name)
            guard let k = session.keystoneFromSelectedClip(name: name) else { return }
            guard await storeKeystone(k) else { return }
            model.selectedID = k.id
            palette.selectedID = k.id
            shell.onStatus?(SQL10n.format("Saved keystone “%@”.", name))
        }
    }

    /// `LibraryPanelModel.replacePreset` on the shared store, then the list.
    func storeKeystone(_ k: Keystone) async -> Bool {
        do {
            let item = try KeystoneLibrary.presetItem(for: k)
            if await store.preset(item.id) != nil {
                try await store.updatePayload(item.id, payload: item.payload, version: item.payloadVersion)
                try await store.rename(item.id, to: item.name)
            } else {
                try await store.add(item)
            }
            await reload()
            return true
        } catch {
            shell.onStatus?(SQL10n.format("The keystone could not be saved: %@", SQL10n.errorText(error)))
            return false
        }
    }
}
