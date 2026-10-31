import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQUIKit

/// The Graphics panel of the shared UI (Windows app and Mac `SQ_SHARED_UI`): the shared-toolkit `GraphicsPanelDraw` (layer list, property rows, text
/// block, effects) in the dock's Graphics card, wired like the Mac host (App/Sources/EditorPanels.swift
/// `wireGraphics`). Coordinates: `frame` in points, events arrive in pixels.
@MainActor
public final class GraphicsHost {
    public let editor: GraphicsEditor
    public let panel: GraphicsPanelDraw
    public private(set) var frame: CGRect = .zero
    public private(set) var isDragging = false
    public private(set) var hasFocus = false
    /// The live keyboard modifiers (Alt copies while dragging layers); the platform reads its own keyboard.
    public var modifiers: @MainActor () -> InputModifiers = { [] }
    /// The Library's video effect presets for the Presets… menu (the store is an actor: refreshed after open and saves).
    private var presets: [(name: String, preset: EffectPreset)] = []
    private var presetsLoaded = false
    private weak var shell: ShellHost?
    /// Sequence > Save as Template… of the app (the name dialog and the Library).
    public var onSaveTemplate: (() -> Void)?

    public init(session: EditorSession, menus: MenuController, shell: ShellHost, inspector: InspectorHost) {
        self.shell = shell
        editor = GraphicsEditor(session: session)
        panel = GraphicsPanelDraw(editor: editor)
        panel.onMenu = { [weak self, weak menus] items, anchor in
            guard let self, let menus else { return }
            let r = anchor.offsetBy(dx: frame.minX, dy: frame.minY)
            menus.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r)
        }
        panel.onPickColor = { [weak self, weak inspector] color, anchor, change in
            guard let self else { return }
            inspector?.pickColor(color, anchor: anchor.offsetBy(dx: frame.minX, dy: frame.minY), change)
        }
        panel.onMakeGraphic = { [weak session] in _ = session?.makeGraphic() }
        panel.onSaveTemplate = { [weak self] in self?.onSaveTemplate?() }
        panel.effectPresets = { [weak self] in self?.presets ?? [] }
        panel.onSaveEffectPreset = { [weak self] preset in self?.saveEffectPreset(preset) }
        panel.askName = { [weak shell] title, initial, done in
            guard let shell else { return done(initial) }
            Task { @MainActor in done(await InspectorHost.ask(.name(title, initial: initial), shell)?.first) }
        }
        // Delete and Select All in the Graphics panel (the Mac `graphicsHasSelection` / `graphicsHasLayers`).
        shell.factProviders.append { [editor] f in
            f.graphicsHasSelection = !editor.selectedLayers.isEmpty
            f.graphicsHasLayers = !(editor.document?.layers.isEmpty ?? true)
        }
        // Controls follows the picked layer (the Mac `graphics.onSelectionChange`).
        editor.onSelectionChange = { [weak inspector] in inspector?.graphicsSelectionChanged() }
        inspector.useGraphicsEditor(editor)
        // Select Layer Above / Below step through the open Graphic's layers (the Mac AppController+TimelineOps).
        let next = shell.onCommand
        shell.onCommand = { [weak shell, weak inspector, editor] c in
            guard c == .selectLayerAbove || c == .selectLayerBelow else { return next?(c) == true }
            if editor.stepLayerSelection(up: c == .selectLayerAbove) { inspector?.graphicsSelectionChanged() }
            else { shell?.onStatus?("No Graphic with layers is open.") }
            return true
        }
    }

    private func loadPresets() {
        Task { @MainActor [weak self] in
            let items = await LibraryStores.presetStore.presets(kind: .effect)
            self?.presets = items.compactMap { item in
                guard let p = try? EffectPreset(payload: item.payload, version: item.payloadVersion),
                      p.trackKind == .video, !p.effects.isEmpty else { return nil }
                return (item.name, p)
            }
        }
    }

    private func saveEffectPreset(_ preset: EffectPreset) {
        guard let shell else { return }
        let initial = editor.selectedLayer?.name ?? "Layer Effects"
        Task { @MainActor [weak self, weak shell] in
            guard let shell, let typed = await InspectorHost.ask(.name("Save Effects as Preset", initial: initial), shell)?.first
            else { return }
            let name = PresetSaveSheet.resolvedName(typed, fallback: initial)
            do {
                try await LibraryStores.presetStore.add(try EditorSession.effectPresetItem(name: name, preset: preset))
                shell.onStatus?(SQL10n.format("Saved preset “%@”.", name))
                self?.loadPresets()
            } catch {
                shell.onStatus?(SQL10n.format("The preset could not be saved: %@", SQL10n.errorText(error)))
            }
        }
    }

    /// Effects released over the card (window points): they go to the one selected layer (the Mac
    /// `GraphicsPanelView.performDragOperation`). False when the card is not under `p` or no Graphic is open.
    @discardableResult
    public func dropEffects(_ kinds: [String], at p: CGPoint) -> Bool {
        guard frame.width > 0, frame.contains(p) else { return false }
        return panel.dropEffects(kinds, at: CGPoint(x: p.x - frame.minX, y: p.y - frame.minY))
    }

    /// An Effects drag is at window point `p` (nil: it ended or left): the layer row under it takes the accent tint.
    public func effectDragOver(at p: CGPoint?) {
        guard frame.width > 0, let p, frame.contains(p) else { panel.effectDragOver(at: nil); return }
        panel.effectDragOver(at: CGPoint(x: p.x - frame.minX, y: p.y - frame.minY))
    }

    /// Places the panel on the dock's Graphics card (`card` in points, nil while the card is hidden).
    public func layout(_ card: CGRect?) {
        frame = card ?? .zero
        guard frame.width > 0 else { hasFocus = false; return }
        if !presetsLoaded { presetsLoaded = true; loadPresets() }
        panel.size = frame.size
        panel.tick()
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        guard frame.width > 0, frame.height > 0 else { return }
        panel.theme = theme
        c.saveGState()
        c.clip(to: frame)
        c.translateBy(x: frame.minX, y: frame.minY)
        panel.draw(&c)
        c.restoreGState()
    }

    /// Routes one event in pixels; true when the panel took it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        guard frame.width > 0 else { return false }
        func local(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: CGFloat(x / scale) - frame.minX, y: CGFloat(y / scale) - frame.minY)
        }
        func inside(_ q: CGPoint) -> Bool { CGRect(origin: .zero, size: frame.size).contains(q) }
        switch e {
        case .mouseDown(let x, let y, let m):
            let q = local(x, y)
            hasFocus = inside(q)
            guard hasFocus else { return false }
            isDragging = true
            panel.mouseDown(at: q, modifiers: m)
        case .mouseDragged(let x, let y):
            guard isDragging else { return false }
            panel.mouseDragged(to: local(x, y), modifiers: modifiers())   // Alt copies
        case .mouseUp(let x, let y):
            guard isDragging else { return false }
            isDragging = false
            panel.mouseUp(at: local(x, y), modifiers: modifiers())
        case .mouseMoved(let x, let y):
            let q = local(x, y)
            panel.mouseMoved(to: inside(q) || isDragging ? q : nil)
            if inside(q) { HostHover.current.offerTip(panel.help(at: q)) }
            return false                       // hover also reaches the screen (cursor, other panels' hover end)
        case .scroll(let x, let y, _, let dy, let m):
            let q = local(x, y)
            guard inside(q) else { return false }
            panel.scroll(at: q, dy: CGFloat(dy / scale), precise: true, modifiers: m)
        case .keyDown(let k, let m):
            guard hasFocus else { return false }
            return panel.key(k, modifiers: m)
        }
        return true
    }
}
