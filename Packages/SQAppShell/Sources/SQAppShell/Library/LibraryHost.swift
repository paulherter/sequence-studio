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

/// The Library panel of the shared shell (Windows dock, Mac `SQ_SHARED_UI`): the draw `LibraryDrawPanel` on the
/// `LibraryPanelModel` the Mac AppKit panel uses, with the Mac host's flows on the shell's SQ dialogs and file choosers
/// (`LibraryPanelView` addFolder / export / import / delete, `LibraryPackFlow`, `EditorPanels` whoosh, title and preset
/// apply) and its drags routed onto the timeline (`LibraryDropRoute`). The "..." options sit in the dock's tab strip.
/// shortcut: import picks one preset or pack file at a time (`ShellFilePicker.chooseFile`); upgrade when the picker has a
/// multi-file chooser.
/// Coordinates: `frame` in points, events arrive in pixels.
@MainActor
public final class LibraryHost {
    public let model: LibraryPanelModel
    public let panel: LibraryDrawPanel
    public private(set) var frame: CGRect = .zero
    public private(set) var hasFocus = false
    private var isPressed = false
    private let session: EditorSession
    private let shell: ShellHost
    private let menus: MenuController
    let options: PanelStripOptions
    /// The timeline panel the drags land on (the host owns it).
    public var withTimeline: (_ change: (inout TimelinePanel) -> Void) -> Void = { _ in }
    public var modifiers: () -> InputModifiers = { [] }
    /// The poster of a media file (the host's thumbnail atlas); nil = the kind icon.
    public var poster: (@MainActor (URL) -> ProjectPoster?)?
    /// Files were imported and placed (the host refreshes its media tables).
    public var onPlaced: (@MainActor () -> Void)?
    /// The clip shown in Effect Controls when the window point is over that panel (a drop there adds to it); nil elsewhere.
    public var inspectorDropClip: (@MainActor (CGPoint) -> Clip.ID?)?
    /// The sequence is playing: a Library preview pauses (the Mac panel pauses it when the sequence starts).
    public var isSequencePlaying: () -> Bool = { false }
    /// The live picture of the playing preview video (image slot and pixel size); nil = the poster shows.
    public var previewFrame: (@MainActor () -> (slot: Int, size: CGSize)?)? {
        get { panel.previewFrame }
        set { panel.previewFrame = newValue }
    }
    /// The pointer in window pixels while a drag runs (the host draws the drag label there).
    public private(set) var dragLabel: (title: String, x: Float, y: Float)?

    public init(session: EditorSession, menus: MenuController, shell: ShellHost, defaults: UserDefaults = .standard) {
        self.session = session
        self.shell = shell
        self.menus = menus
        model = LibraryDrawServices.makeModel(defaults: defaults)
        panel = LibraryDrawPanel(model: model, defaults: defaults)
        options = PanelStripOptions(panel: .library, dock: shell.dock)
        let librarySearch = panel
        shell.factProviders.append { f in if librarySearch.isEditingSearch { f.textEditing = true } }
        panel.canWhoosh = true
        shell.runWhooshAtCuts = { [weak self] in self?.whooshFromSFXBin() }
        panel.picture = { [weak self] item, rect in
            guard item.entry.kind == .video || item.entry.kind == .image, let p = self?.poster?(item.url) else { return nil }
            return (p.slot, p.cropped(toFill: rect))
        }
        panel.onMenu = { [weak self] items, p in self?.present(items, at: p) }
        panel.onRequest = { [weak self] r in self?.run(r) }
        panel.onDrag = { [weak self] payload, phase, p in self?.dragged(payload, phase, at: p) }
        options.onOpen = { [weak self] p in
            guard let self else { return }
            menus.present(items: panel.optionsMenu(), at: p)
        }
        model.onInsertTitleBlock = { [weak self] item, time in
            guard let self else { return }
            shell.onStatus?(TextTemplatePlacement.insertTitle(item, at: time, session: session))
        }
        model.onApplyPreset = { [weak self] item, mode in
            guard let self else { return }
            if !session.applyPreset(item, mode: mode ?? PresetApplyModeSetting.load()) {
                shell.onStatus?(session.lastError ?? SQL10n.string("The preset could not be applied."))
            }
        }
        // The preview player stops the sequence (the Mac `preview.onWillPlay`).
        model.preview.onWillPlay = { [weak session] in session?.stopPlayback() }
        let model = model
        shell.spawn { await LibraryDrawServices.start(model, defaults: defaults) }
    }

    /// A Library sound -> a copy centered on each selected cut (the Mac `EditorPanels.whoosh`).
    public func whoosh(_ url: URL) {
        var edges: [EdgeRef] = []
        withTimeline { edges = $0.interaction.edgeSelection?.edges ?? [] }
        let cuts = session.selectedCuts(edges: edges)
        guard !cuts.isEmpty else {
            shell.onStatus?(SQL10n.string("Select a cut first: click an edge, or select clips next to each other.")); return
        }
        guard let project = shell.projectModel else { return }
        let session = session, shell = shell
        shell.spawn { [weak self] in
            await project.importFiles([url])
            shell.onProjectChanged?()
            guard let id = project.mediaID(forImported: url), session.addWhoosh(media: id, atCuts: cuts) else {
                shell.onStatus?(session.lastError ?? SQL10n.string("Could not place the sound on the cuts.")); return
            }
            self?.onPlaced?()
        }
    }

    /// The menu command: the SFX bin's whoosh sound, or the bin is made and the status line says what to do (the Mac
    /// `EditorPanels.whooshFromSFXBin`).
    func whooshFromSFXBin() {
        let model = model, shell = shell
        shell.spawn { [weak self] in
            if let url = model.whooshSound { self?.whoosh(url); return }
            let existed = model.sfxFolder != nil
            await model.ensureSFXBin()
            shell.onStatus?(SQL10n.string(existed ? "The SFX folder is empty. Add sound files to it (Library item menu: Add to SFX Folder)."
                                                  : "SFX bin created in the Library. Add whoosh sounds to it, then run this again."))
        }
    }

    func present(_ items: [SQMenuItem], at p: CGPoint) {
        let q = CGPoint(x: p.x + frame.minX, y: p.y + frame.minY)
        menus.present(items: items, at: q, pointer: q)
    }

    // MARK: Requests (dialogs, file choosers, timeline)

    func run(_ r: LibraryRequest) {
        let model = model, shell = shell, session = session
        switch r {
        case .addFolder:
            shell.spawn {
                guard let url = await shell.files?.chooseFolder(prompt: SQL10n.string("Add Folder")) else { return }
                _ = await model.addFolder(url: url)
            }
        case .reveal(let urls):
            shell.reveal(urls)
        case .whoosh(let url): whoosh(url)
        case .applyTextTemplate(let id):
            guard let entry = TextTemplateCatalog.entry(id: id) else { return }
            if entry.isCTA { session.addCTAEndCard() } else if let g = entry.graphicPresetID { session.addGraphicPreset(g) }
            else { session.addTextClip(template: entry.template) }
        case .exportPreset(let p):
            shell.spawn {
                guard let url = await shell.files?.chooseExportLocation(suggestedName: PresetFile.suggestedFileName(for: p.name),
                                                                        fileExtension: PresetFile.fileExtension,
                                                                        prompt: SQL10n.string("Export Preset")) else { return }
                do { try await model.exportPreset(p.id, to: url) } catch {
                    let m = LibraryLabels.presetError(error)
                    shell.presentMessage(SQL10n.string("The preset could not be exported."), m.detail)
                }
            }
        case .importPresets:
            shell.spawn {
                guard let url = await shell.files?.chooseFile(prompt: SQL10n.string("Import Presets"), directory: nil) else { return }
                if url.pathExtension.lowercased() == SQPackFormat.fileExtension { await Self.importPack(url, model: model, shell: shell); return }
                for f in await model.importPresets(from: [url]) {
                    let m = LibraryLabels.presetError(f.error, file: f.url)
                    shell.presentMessage(m.title, m.detail)
                }
            }
        case .deletePreset(let p):
            shell.spawn {
                let d = ShellDialog(SQL10n.format("Delete “%@”?", p.name),
                                    informative: SQL10n.string("The preset is removed from the Library. Clips that use it keep their keyframes."))
                d.addButton(SQL10n.string("Delete"), role: .destructive)
                d.addButton(SQL10n.string("Cancel"), role: .cancel)
                guard await shell.ask(d) == .first else { return }
                await model.deletePreset(p.id)
            }
        case .exportPack(let ids, let name):
            guard !ids.isEmpty else { return }
            shell.spawn { await Self.exportPack(ids: ids, suggestedName: name, model: model, shell: shell) }
        case .importPack:
            shell.spawn {
                guard let url = await shell.files?.chooseFile(prompt: SQL10n.string("Import Pack"), directory: nil) else { return }
                await Self.importPack(url, model: model, shell: shell)
            }
        }
    }

    static let authorKey = "sq.pack.author"

    /// "Export as Pack…": name, author and version, then where to save (`LibraryPackFlow.export`).
    static func exportPack(ids: [UUID], suggestedName: String, model: LibraryPanelModel, shell: ShellHost) async {
        let d = ShellDialog(SQL10n.string("Export as Pack"),
                            informative: ids.count == 1 ? SQL10n.string("One preset goes into the pack.")
                                : SQL10n.format("%@ presets go into the pack.", "\(ids.count)"))
        d.form = ShellForm([.field(id: "name", label: SQL10n.string("Name"), value: suggestedName),
                            .field(id: "author", label: SQL10n.string("Author"), value: UserDefaults.standard.string(forKey: authorKey) ?? ""),
                            .field(id: "version", label: SQL10n.string("Version"), value: "1.0")])
        d.addButton(SQL10n.string("Export…"), role: .default)
        d.addButton(SQL10n.string("Cancel"), role: .cancel)
        guard await shell.ask(d) == .first else { return }
        let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = trim(d.form?.text("name")), by = trim(d.form?.text("author"))
        UserDefaults.standard.set(by, forKey: authorKey)
        do { try SQPackFormat.validateName(title) } catch {
            shell.presentMessage(SQL10n.string("Choose another name"),
                                 SQL10n.string("A pack name needs 1 to 120 characters and no slashes or colons."))
            return
        }
        let manifest = SQPackManifest(name: title, author: by, version: trim(d.form?.text("version")))
        guard let url = await shell.files?.chooseExportLocation(suggestedName: SQPackFormat.suggestedFileName(for: title),
                                                                fileExtension: SQPackFormat.fileExtension,
                                                                prompt: SQL10n.string("Export as Pack")) else { return }
        do { try await model.exportPack(ids: ids, manifest: manifest, to: url) } catch {
            shell.presentMessage(SQL10n.string("The pack could not be saved"), LibraryLabels.packError(error))
        }
    }

    /// Reads and checks a `.sqpack`, asks only when names clash, then adds it (`LibraryPackFlow.importFile`).
    static func importPack(_ url: URL, model: LibraryPanelModel, shell: ShellHost) async {
        let failed = SQL10n.format("“%@” could not be imported", url.lastPathComponent)
        let read: SQPackReadResult
        do { read = try await model.readPack(at: url) } catch { shell.presentMessage(failed, LibraryLabels.packError(error)); return }
        let clashes = await model.packConflicts(read.pack)
        var policy = SQPackConflict.rename
        if !clashes.isEmpty {
            let d = ShellDialog(SQL10n.format("“%@” is already in the Library", read.pack.manifest.name),
                                informative: SQL10n.plural(clashes.count, one: "%@ preset has the same name as one you already imported from this pack.",
                                                           other: "%@ presets have the same name as one you already imported from this pack."))
            d.addButton(SQL10n.string("Keep Both"), role: .default)
            d.addButton(SQL10n.string("Replace"))
            d.addButton(SQL10n.string("Skip Existing"))
            d.addButton(SQL10n.string("Cancel"), role: .cancel)
            switch await shell.ask(d) {
            case .first: policy = .rename
            case .second: policy = .replace
            case .third: policy = .skip
            default: return
            }
        }
        do {
            let s = try await model.importPack(read, conflict: policy)
            if s.unreadable > 0 {
                shell.presentMessage(SQL10n.format("“%@” was imported", s.packName),
                                     SQL10n.plural(s.unreadable, one: "%@ preset in it needs a newer version of Sequence Studio and was left out.",
                                                   other: "%@ presets in it need a newer version of Sequence Studio and were left out."))
            }
        } catch { shell.presentMessage(failed, LibraryLabels.packError(error)) }
    }

    // MARK: Drags onto the timeline

    func dragged(_ payload: LibraryDragPayload, _ phase: LibraryDrawPanel.DragPhase, at p: CGPoint) {
        let s = Float(scale)
        let x = Float(p.x + frame.minX) * s, y = Float(p.y + frame.minY) * s
        let ph: TimelineDropRoute.Phase = switch phase { case .moved: .moved; case .ended: .ended; case .canceled: .canceled }
        dragLabel = phase == .moved ? (Self.label(payload, presets: model.presets), x, y) : nil
        let mods = modifiers()
        let context = LibraryDropRoute.Context(presets: model.presets, importAndPlace: { [weak self] urls, a in self?.importAndPlace(urls, at: a) },
                                               status: { [weak shell] in shell?.onStatus?($0) })
        var placed = false
        withTimeline { [session] panel in
            placed = LibraryDropRoute.drag(.library(payload), phase: ph, x: x, y: y, modifiers: mods, panel: &panel, session: session,
                                           context: context)
        }
        if !placed, phase == .ended, case .effectPreset(let id) = payload, let clip = inspectorDropClip?(CGPoint(x: p.x + frame.minX, y: p.y + frame.minY)) {
            placed = LibraryDropRoute.dropOnClips([LibraryDropRoute.presetPrefix + id.uuidString], targets: [clip], session: session, context: context)
        }
        if placed, case .files = payload {} else if placed { onPlaced?() }
    }

    static func label(_ payload: LibraryDragPayload, presets: [PresetItem]) -> String {
        switch payload {
        case .files(let urls): urls.count == 1 ? urls[0].lastPathComponent : SQL10n.format("%@ files", "\(urls.count)")
        case .textTemplate(let id): TextTemplateCatalog.entry(id: id)?.name ?? ""
        case .titleBlock(let id), .effectPreset(let id): presets.first { $0.id == id }?.name ?? ""
        }
    }

    func importAndPlace(_ urls: [URL], at a: TimelineAction) {
        guard let project = shell.projectModel else { return }
        let shell = shell, session = session
        shell.spawn { [weak self] in
            await project.importFiles(urls)
            shell.onProjectChanged?()
            let ids = urls.compactMap { project.mediaID(forImported: $0) }
            guard !ids.isEmpty else { shell.onStatus?(SQL10n.string("Could not import the dropped files.")); return }
            if !TimelineDrop.place(.media(ids), at: a, in: session), let e = session.lastError { shell.onStatus?(e) }
            self?.onPlaced?()
        }
    }

    /// The drag's name under the pointer over every panel (the Mac drag image); the host calls it after the panels.
    public func drawDragLabel(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        guard let d = dragLabel, !d.title.isEmpty else { return }
        PanelDragLabel.draw(&c, d.title, at: CGPoint(x: CGFloat(d.x) / CGFloat(scale), y: CGFloat(d.y) / CGFloat(scale)), theme: theme)
    }

    // MARK: Frame, draw, events

    private var scale: CGFloat = 1

    /// Places the panel on the dock's Library card (`card` in points, nil while the card is hidden).
    public func layout(_ card: CGRect?, scale s: Float) {
        scale = CGFloat(s)
        frame = card ?? .zero
        guard frame.width > 0 else { hasFocus = false; panel.pausePreview(); return }   // another dock tab: the preview pauses
        if isSequencePlaying() { panel.pausePreview() }
        panel.size = frame.size
        panel.refresh()
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        options.draw(&c, theme: theme)
        guard frame.width > 0, frame.height > 0 else { return }
        panel.theme = theme
        c.saveGState()
        c.clip(to: frame)
        c.translateBy(x: frame.minX, y: frame.minY)
        panel.hasFocus = hasFocus
        panel.draw(&c)
        c.restoreGState()
    }

    /// Routes one event in pixels; true when the panel took it.
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
            let q = local(x, y)
            panel.mouseDragged(to: q)
            HostHover.current.request(panel.cursor(at: q))
        case .mouseUp(let x, let y):
            guard isPressed else { return false }
            isPressed = false
            panel.mouseUp(at: local(x, y))
        case .mouseMoved(let x, let y):
            let q = local(x, y)
            panel.mouseMoved(to: inside(q) ? q : nil)
            if inside(q) { HostHover.current.offerTip(panel.help(at: q)); HostHover.current.request(panel.cursor(at: q)) }
            return false
        case .scroll(let x, let y, _, let dy, _):
            let q = local(x, y)
            guard inside(q) else { return false }
            _ = panel.scroll(at: q, dy: CGFloat(dy / scale))
        case .keyDown(let k, let m):
            guard hasFocus else { return false }
            if k == .character("f"), m == .command { panel.focusSearch(); return true }
            return panel.key(k, modifiers: m)
        }
        return true
    }
}

/// The "..." options button a draw panel puts in its dock tab strip (the Mac panel header's options button): the dock
/// keeps its room free through `ShellDock.stripTools` (whoever set the seam before keeps theirs).
@MainActor
final class PanelStripOptions {
    static let width: CGFloat = 28
    let panel: PanelID
    weak var dock: ShellDock?
    /// Opens the options menu at a window point (points).
    var onOpen: ((CGPoint) -> Void)?
    private var hover = false

    init(panel: PanelID, dock: ShellDock) {
        self.panel = panel
        self.dock = dock
        let previous = dock.stripTools
        dock.stripTools = { p in p == panel ? Self.width : previous(p) }
    }

    /// The button rect in window points, nil while the panel is not the shown tab of its group.
    var rect: CGRect? {
        guard let g = dock?.groups.first(where: { $0.selected == panel }), g.strip.height > 0 else { return nil }
        let s = g.strip
        return CGRect(x: s.maxX - Self.width + 2, y: s.midY - 11, width: 22, height: 22)
    }

    func draw(_ c: inout Canvas, theme t: DrawTheme) {
        guard let r = rect else { return }
        if hover { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
        c.draw(icon: .ellipsis, at: CGPoint(x: r.midX - 7, y: r.midY - 7), size: 14, t.label2)
    }

    func handle(_ e: InputEvent, scale: Float) -> Bool {
        guard let r = rect else { hover = false; return false }
        switch e {
        case .mouseMoved(let x, let y):
            hover = r.contains(CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)))
            if hover { HostHover.current.offerTip(SQL10n.string("Options")) }
            return false
        case .mouseDown(let x, let y, let m):
            guard !m.contains(.secondary), r.contains(CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale))) else { return false }
            onOpen?(CGPoint(x: r.minX, y: r.maxY))
            return true
        default: return false
        }
    }
}

/// The name of what is dragged out of a panel, in a small pill beside the pointer (the Mac drag image).
enum PanelDragLabel {
    static func draw(_ c: inout Canvas, _ title: String, at p: CGPoint, theme t: DrawTheme) {
        let fs = CGFloat(DrawTheme.TypeSize.body)
        let w = min(c.size(of: title, fontSize: fs).width + 16, 240)
        let r = CGRect(x: p.x + 12, y: p.y + 8, width: w, height: 22)
        c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.panel)
        c.stroke(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), width: 1, t.separator)
        c.draw(title, in: r, fontSize: fs, t.label, inset: 8)
    }
}
