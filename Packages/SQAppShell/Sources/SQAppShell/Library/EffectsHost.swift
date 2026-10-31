import Foundation
import SQCore
import SQDrawKit
import SQDrawLibrary
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQLibrary
import SQUIKit

/// The Effects panel of the shared shell (Windows dock, Mac `SQ_SHARED_UI`): the draw `EffectsDrawPanel` with the Mac
/// `EditorPanels` wiring (double-click applies through `EffectsApply`, drags land through `LibraryDropRoute`, the saved
/// presets of the Library's model are listed under "Presets"). The "..." options sit in the dock's tab strip.
/// Coordinates: `frame` in points, events arrive in pixels.
@MainActor
public final class EffectsHost {
    public let panel: EffectsDrawPanel
    /// The grid's tile stills (image slot `EffectsTileAtlas.slot`; the hosts upload `tileImage`).
    public let tilePictures = EffectsTileAtlas()
    /// The still atlas for the renderer: (slot, image, generation), nil before the first still.
    public var tileImage: (Int, RGBAImage, Int)? {
        tilePictures.image.height > 0 ? (EffectsTileAtlas.slot, tilePictures.image, tilePictures.generation) : nil
    }
    public private(set) var frame: CGRect = .zero
    public private(set) var hasFocus = false
    private var isPressed = false
    private let session: EditorSession
    private let shell: ShellHost
    private let menus: MenuController
    private let library: LibraryPanelModel
    let options: PanelStripOptions
    private var presetIDs: [UUID]?
    private var scale: CGFloat = 1
    public var withTimeline: (_ change: (inout TimelinePanel) -> Void) -> Void = { _ in }
    public var modifiers: () -> InputModifiers = { [] }
    /// An effect, preset or transition was placed from a drag.
    public var onPlaced: (@MainActor () -> Void)?
    /// The clip shown in Effect Controls when the window point is over that panel (a drop there adds to it); nil elsewhere.
    public var inspectorDropClip: (@MainActor (CGPoint) -> Clip.ID?)?
    /// Effects released on the Graphics card: the selected layer takes them (`GraphicsHost.dropEffects`); true when taken.
    public var graphicsDrop: (@MainActor ([String], CGPoint) -> Bool)?
    /// The drag is over window point `p` (nil: it ended): the Graphics card tints the layer row under it.
    public var graphicsDragOver: (@MainActor (CGPoint?) -> Void)?
    public private(set) var dragLabel: (title: String, x: Float, y: Float)?

    /// `library` is the Library host's model: its saved presets show under "Presets" and apply from here.
    public init(session: EditorSession, menus: MenuController, shell: ShellHost, library: LibraryPanelModel,
                defaults: UserDefaults = .standard) {
        self.session = session
        self.shell = shell
        self.menus = menus
        self.library = library
        panel = EffectsDrawPanel(defaults: defaults)
        let effectsSearch = panel
        shell.factProviders.append { f in if effectsSearch.isEditingSearch { f.textEditing = true } }
        options = PanelStripOptions(panel: .effects, dock: shell.dock)
        panel.onMenu = { [weak self] items, p in
            guard let self else { return }
            let q = CGPoint(x: p.x + frame.minX, y: p.y + frame.minY)
            menus.present(items: items, at: q, pointer: q)
        }
        options.onOpen = { [weak self] p in
            guard let self else { return }
            menus.present(items: panel.optionsMenu(), at: p)
        }
        panel.onApply = { [weak self] id in self?.apply(id) }
        panel.askName = { [weak shell] title, initial, answer in
            guard let shell else { answer(nil); return }
            shell.spawn {
                let d = ShellDialog(title)
                d.form = ShellForm([.field(id: "name", label: SQL10n.string("Name"), value: initial)])
                d.addButton(SQL10n.string("OK"), role: .default)
                d.addButton(SQL10n.string("Cancel"), role: .cancel)
                let ok = await shell.ask(d) == .first
                let name = (d.form?.text("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                answer(ok && !name.isEmpty ? name : nil)
            }
        }
        panel.onDrag = { [weak self] ids, phase, p in self?.dragged(ids, phase, at: p) }
        panel.picture = { [weak self] in self?.tilePictures.picture(for: $0) }
    }

    func apply(_ id: String) {
        var edges: EdgeSelection?
        withTimeline { edges = $0.interaction.edgeSelection }
        EffectsApply.apply(id, session: session, presets: library.presets, edges: edges) { [weak shell] in shell?.onStatus?($0) }
    }

    func dragged(_ ids: [String], _ phase: EffectsDrawPanel.DragPhase, at p: CGPoint) {
        let s = Float(scale)
        let x = Float(p.x + frame.minX) * s, y = Float(p.y + frame.minY) * s
        let ph: TimelineDropRoute.Phase = switch phase { case .moved: .moved; case .ended: .ended; case .canceled: .canceled }
        let title = ids.first.flatMap { id in panel.allEntries.first { $0.id == id }?.title } ?? ""
        dragLabel = phase == .moved ? (title, x, y) : nil
        graphicsDragOver?(phase == .moved ? CGPoint(x: p.x + frame.minX, y: p.y + frame.minY) : nil)
        let mods = modifiers()
        let context = LibraryDropRoute.Context(presets: library.presets, importAndPlace: { _, _ in },
                                               status: { [weak shell] in shell?.onStatus?($0) })
        var placed = false
        withTimeline { [session] panel in
            placed = LibraryDropRoute.drag(.effects(ids), phase: ph, x: x, y: y, modifiers: mods, panel: &panel, session: session,
                                           context: context)
        }
        if !placed, phase == .ended, let clip = inspectorDropClip?(CGPoint(x: p.x + frame.minX, y: p.y + frame.minY)) {
            placed = LibraryDropRoute.dropOnClips(ids, targets: [clip], session: session, context: context)
        }
        // The Graphics card takes plain effects for its selected layer (not presets, not transitions).
        if !placed, phase == .ended {
            let kinds = ids.filter { !$0.hasPrefix(LibraryDropRoute.presetPrefix) && EffectDragPayload.transitionKind(forID: $0) == nil }
            if !kinds.isEmpty, graphicsDrop?(kinds, CGPoint(x: p.x + frame.minX, y: p.y + frame.minY)) == true { return }
        }
        if placed { onPlaced?() }
    }

    public func drawDragLabel(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        guard let d = dragLabel, !d.title.isEmpty else { return }
        PanelDragLabel.draw(&c, d.title, at: CGPoint(x: CGFloat(d.x) / CGFloat(scale), y: CGFloat(d.y) / CGFloat(scale)), theme: theme)
    }

    /// Places the panel on the dock's Effects card (`card` in points, nil while hidden) and picks up preset changes.
    public func layout(_ card: CGRect?, scale s: Float) {
        scale = CGFloat(s)
        let ids = library.presets.map(\.id)
        if ids != presetIDs {
            presetIDs = ids
            panel.presetEntries = EffectsCatalog.presetEntries(library.presets)
        }
        frame = card ?? .zero
        guard frame.width > 0 else { hasFocus = false; return }
        panel.size = frame.size
        tilePictures.prepare(panel.visibleTileIDs)
        tilePictures.advance(now: ProcessInfo.processInfo.systemUptime)
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        options.draw(&c, theme: theme)
        guard frame.width > 0, frame.height > 0 else { return }
        panel.theme = theme
        c.saveGState()
        c.clip(to: frame)
        c.translateBy(x: frame.minX, y: frame.minY)
        panel.draw(&c)
        c.restoreGState()
    }

    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        if options.handle(e, scale: scale) { return true }
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
            isPressed = true
            panel.mouseDown(at: q, modifiers: m)
        case .mouseDragged(let x, let y):
            guard isPressed else { return false }
            panel.mouseDragged(to: local(x, y))
        case .mouseUp(let x, let y):
            guard isPressed else { return false }
            isPressed = false
            panel.mouseUp(at: local(x, y))
        case .mouseMoved(let x, let y):
            let q = local(x, y)
            if inside(q) { HostHover.current.offerTip(panel.help(at: q)) }
            tilePictures.setHover(inside(q) ? panel.tileID(at: q) : nil, now: ProcessInfo.processInfo.systemUptime)
            return false
        case .scroll(let x, let y, _, let dy, _):
            guard inside(local(x, y)) else { return false }
            panel.scroll(dy: CGFloat(dy / scale))
        case .keyDown(let k, let m):
            guard hasFocus else { return false }
            if k == .character("f"), m == .command { panel.focusSearch(); return true }
            return panel.key(k, modifiers: m)
        }
        return true
    }
}
