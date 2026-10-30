import Foundation
import SQAnalysis
import SQAppShell
import SQCore
import SQDrawEditor
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQMedia
import SQMediaFFmpeg
import SQPlayback
import SQTranscribe
import SQTimelineUI
import SQUIKit
import Synchronization

/// Glue between the portable editor screen and the editor session: reads a snapshot each frame, applies intents
/// through the session API (no view edits the model itself) and keeps the engine's media paths current.
@MainActor
final class AppController {
    let session: EditorSession
    let engine: WinProgramEngine
    var screen = EditorScreen()
    /// The Timeline panel (SQDrawTimeline, the Mac panel translated) drawn over the screen's timeline area.
    var timelinePanel = TimelinePanel()
    /// The tool bar docked around (or floating over) the timeline area (SQDrawTimeline `ToolStrip`).
    var toolStrip = ToolStrip()
    /// The header bar above the timeline (sequence tabs, Normal | Fast Cut, toggles, Fit) and the Fast Cut strip.
    var timelineHeader = TimelineHeaderStrip()
    /// The app shell (SQDrawShell): menu bar in the top bar, dialogs, Ctrl shortcuts, project files, window title.
    let shell: ShellHost
    let atlas: GlyphAtlas
    /// Effect Controls (SQInspectorUI, the Mac panel translated) on the screen's inspector card.
    lazy var inspector = InspectorHost(session: session, menus: shell.menuBar.controller, shell: shell, sampler: WinScreenSampler())
    lazy var graphics: GraphicsHost = {
        inspector.onShowGraphics = { [weak self] in self?.shell.dock.show(.graphics) }
        inspector.onSaveTransitionPreset = { [weak self] in timelineEditors.dialogs?.saveSelectedTransitionAsPreset() }
        inspector.keystones = timelineDrags.keystones
        return makeGraphicsHost()
    }()
    /// The Text panel (List, Look, Templates) on the dock's Text card; its swatches open Controls' color picker.
    /// The Library and Effects panels on their dock cards (AppController+Library.swift).
    lazy var library: LibraryHost = makeLibraryHost()
    lazy var effects: EffectsHost = makeEffectsHost()
    lazy var captions: CaptionsHost = {
        let h = CaptionsHost(session: session, menus: shell.menuBar.controller, shell: shell)
        // The Windows speech engine: whisper.cpp (whisper.dll loaded at run time) over a downloaded Whisper model, audio
        // decoded by FFmpeg to 16 kHz mono (the design notes, "Speech on Windows").
        let whisper = WhisperRuntime()
        h.useTranscription { WhisperTranscriber(engine: whisper, audio: { try FFmpegAudioSource.monoSamples(url: $0) }) }
        h.pickColor = { [weak self] color, anchor, change in self?.inspector.pickColor(color, anchor: anchor, change) }
        return h
    }()
    /// The monitor card (SQAppShell `MonitorCardHost`): the Program monitor, the Source monitor as its second tab, the
    /// slip / trim two-up and their wiring to the shell.
    lazy var monitors: MonitorCardHost = {
        let h = MonitorCardHost(session: session, shell: shell, program: engine, backend: WinMonitorBackend(program: engine, paths: paths),
                                effects: inspector.model, projectList: projectList, timelineHost: timelineHost)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.modifiers = keyModifiers
        h.graphics = { [weak self] in self?.graphics.editor }
        h.onPlaced = { [weak self] in self?.mediaChanged() }
        // Transparency Grid: the engine composites over the checker (WinCompositor `transparent`), so the picture stays
        // opaque and `MonitorPanel.pictureHasAlpha` stays false (no second checker under it).
        let m = h.monitor
        // The Mask tool's Magic mode (EdgeTAM on ONNX Runtime + DirectML, WinMagicMasks.swift).
        let magic = WinMagicMasks(model: inspector.model, session: session) { [weak self] in self?.shell.onStatus?($0) }
        magic.onTracked = { [weak self] in self?.shell.magicHealth?.forget() }
        m.magic = magic
        engine.showsTransparencyGrid = m.model.showsTransparencyGrid
        m.model.onTransparencyGridChange = { [weak self] on in self?.engine.showsTransparencyGrid = on }
        return h
    }()
    /// The Program monitor (SQDrawMonitor, the Mac MonitorPanelView translated) on the screen's monitor card.
    var monitor: MonitorHost { monitors.monitor }
    /// The Source monitor, the second tab of the monitor card.
    var source: SourceHost { monitors.source }
    /// The audio meter strip right of the timeline and the Scopes card right of the monitor (SQDrawMonitor panels).
    lazy var meters: MeterScopesHost = {
        let h = MeterScopesHost(session: session, engine: engine, picture: engine, menus: shell.menuBar.controller)
        // The monitor menu's Scopes row shows or hides the Scopes panel of the dock.
        monitor.model.onShowScopes = { [weak self] in self?.shell.dock.toggle(.scopes) }
        h.monitorImage = { [weak self] in self?.monitor.slip?.image }
        return h
    }()
    /// The Color page (SQAppShell `ColorPageHost`): the Edit | Color switch, Color settings, Steps, Sources, viewer header.
    lazy var colorPage = makeColorPage()
    /// The window's own caption (no system title bar): the menu row with the window buttons, the title row below it
    /// (AppController+Chrome.swift).
    let caption = CaptionRowHost()
    lazy var titleRow = makeTitleRow()
    /// What the Timeline panel asks of the shell (commands, menus, other panels' editors): AppController+Timeline.swift.
    lazy var timelineHost = makeTimelineHost()
    var status = ""
    /// Opens the card import when a card is connected (WinCardWatcher.swift).
    var cardWatcher: WinCardWatcher?
    /// The local Edit API behind Preferences > Advanced (WinEditAPI.swift).
    var editAPI: WinEditAPI?
    var welcomeChecked = false
    let paths: PathStore
    /// The Project panel's model (bins, import): File > Import and Explorer drops land here, probed with FFmpeg.
    let projectModel: ProjectPanelModel
    /// The Project panel's list (SQDrawShell), left of the timeline.
    lazy var projectList = ProjectListView(host: shell)

    init(project: Project, fileURL: URL?, audio: Bool) throws {
        guard let atlas = GlyphAtlas() else { throw AppError("the Inter font did not load") }
        self.atlas = atlas
        let paths = PathStore()
        paths.set(project)
        self.paths = paths
        engine = WinProgramEngine(audio: audio) { id in
            guard let path = paths.path(id) else { throw AppError("no file for media \(id)") }
            return try FFmpegAudioSource(url: URL(fileURLWithPath: path))
        }
        engine.setMedia(project.media)
        let session = EditorSession(project: project, fileURL: fileURL, engine: engine)
        self.session = session
        // Proxies: the session hands its media to the proxy service at open and after every import (the Mac AutoProxy).
        session.autoProxy = WinProxies.shared.intake
        // The Mac EditorPanels wiring: imports are session edits; a large one fills the bin as one undo step.
        let probe: ProjectPanelModel.Probe = { try FFmpegMediaProbe.probe($0) }
        projectModel = ProjectPanelModel(project: session.project, probe: probe, onEdit: { [weak session] p, name in
            session?.perform(name) { $0 = p }
        })
        // The keys saved by Keyboard Shortcuts (sq.keymap), the default template until one is changed.
        shell = ShellHost(session: session, map: KeymapStore().load().map, recents: RecentProjects.load())
        shell.saveRecents = { $0.save() }
        shell.onStatus = { [weak self] in self?.status = $0 }
        // Find Scene Changes through FFmpeg; the job line shares the status line (WinAnalysisBackend.swift).
        shell.analysisBackend = WinAnalysisBackend()
        // Match Color to Clip, Weak Tracking and Quick Apply: frame capture off the Program engine, the matte store's health,
        // the Library's presets.
        shell.frameSampler = WinFrameSampler(engine: engine)
        let health = MagicTrackHealthCache { FrameMatteStore.shared.healthSamples(key: $0) }
        shell.magicHealth = health
        timelinePanel.trackWeakSpans = { [weak health] clip in health?.weakSpans(for: clip) }
        LibraryHost.connectQuickApply(shell: shell) { [weak self] in self?.library }
        shell.saveStackAsPreset = { timelineEditors.dialogs?.saveSelectedClipAsPreset() }
        shell.onJob = { [weak self] in self?.status = $0 ?? "" }
        shell.onProjectChanged = { [weak self] in self?.mediaChanged() }
        shell.menuBar.drawsBackground = false
        shell.menuBar.height = CaptionRowHost.height
        projectModel.onCoalescingEdit = { [weak session] p, name, key in session?.perform(name, coalescing: key) { $0 = p } }
        shell.projectModel = projectModel
        screen.projectWidth = 280
        projectList.onOpenSequence = { [weak session] in session?.openSequenceTab($0) }
        projectList.onCollect = { [weak shell] in if let shell { Task { await shell.collectFiles() } } }   // Fix > Collect
        shell.probe = probe
        shell.revealFile = { WinShell.reveal($0) }
        shell.openURL = { WinShell.open($0) }
        shell.fillMenuState = { $0.toolStripVisible = ToolStripPrefs.visible }
        wireExport()
        wireProjectPanel()
        shell.copyText = { WinShell.copy($0) }
        TextClipboard.shared.writeSystem = { WinShell.copy($0) }
        TextClipboard.shared.readSystem = { WinShell.pasteText() }
        shell.mediaClipboard = { WinShell.mediaClipboard() }
        shell.aboutSupporters = { WinShell.supporters() }
        wireEditAPI()
        // Preferences > Media > Card Import and the window that opens when a card is connected.
        shell.hasCardImport = true
        cardWatcher = WinCardWatcher(onCard: { [weak self] in self?.shell.openCardImport(volume: $0) },
                                     onGone: { [weak self] in self?.shell.closeCardImport(volume: $0) })
        // Saved template pictures in the Text panel's tiles (no ImageIO here).
        TemplatePictureDecoder.platform = WinStillDecoder.decode
        configureDock()
        configureChrome()
        configureViewOptions()
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            guard let self, change.contains(.project) else { return }
            if projectModel.project != session.project { projectModel.setProject(session.project) }
            mediaChanged()
        }
    }

    func mediaChanged() {
        engine.setMedia(session.project.media)
        let moved = paths.set(session.project)
        if !moved.isEmpty { winTimelineMedia?.forget(moved) }
    }

    var timeline: Timeline { session.activeTimeline ?? Timeline(name: "", frameDuration: Time(1, 25)) }

    func snapshot() -> EditorSnapshot {
        let playing = !engine.rate.isPaused
        var text = status
        if let e = session.lastError ?? engine.lastError { text = e }
        if text.isEmpty { text = engine.audioUnavailable ? "Audio off" : "Audio: \(engine.audioDevice ?? "")" }
        var snap = EditorSnapshot(projectName: session.displayName, timeline: timeline, labels: session.project.labelResolver,
                                  selection: session.selection, playhead: session.playhead, isPlaying: playing, status: text)
        snap.grade = colorPage.gradeStatus      // the Color page's grade text (the Mac `statusBar.setGrade`)
        return snap
    }

    /// Lays out and draws the window at `width x height`.
    func frame(width: Int, height: Int) -> DrawList {
        cardWatcher?.poll()
        let s = snapshot()
        let scale = screen.theme.scale
        HostRequests.shared.caret = nil
        screen.slots = layoutDock(width: width, height: height, scale: scale)
        screen.layout(width: Float(width), height: Float(height), s)
        // The monitor panel draws the picture; the dock's cards and tab strips go under the panels.
        var list = screen.draw(s, atlas: atlas, hasPicture: false) { [shell, atlas, screen] l in
            // Widen the canvas for the floating rectangles before anything draws there (no window-sized clips).
            let e = shell.dock.floating.canvasExtent
            if e.width > 0 { l.extendCanvas(width: Float(e.width) * scale, height: Float(e.height) * scale) }
            var c = Canvas(list: l, atlas: atlas, scale: scale)
            Self.drawChromeRows(&c, width: CGFloat(Float(width) / scale), theme: screen.theme)
            shell.dock.draw(&c, theme: screen.theme)
            l = c.list
        }
        timelinePanel.theme = screen.theme
        timelinePanel.isPlaying = s.isPlaying
        timelinePanel.sync(timeline: timeline, selection: session.selection, captions: session.captionSelection,
                           playhead: session.playhead, selectedTransition: session.selectedTransition,
                           labels: session.project.labelResolver, lineKeys: Set(session.selectedLineKeys.map(\.key)))
        meters.scopes.hint = colorPage.scopesHint
        layoutMeters(scale: scale)
        timelinePanel.layout(layoutToolStrip(screen.timelineView.frame), scale: screen.theme.scale)
        for a in timelinePanel.tick() { applyTimeline(a) }
        timelinePanel.gradeOutline = colorPage.gradeOutline
        timelinePanel.draw(into: &list, atlas: atlas)
        // The shell's menu titles cover the left of the top bar (its "Sequence Studio" label); menus and dialogs go on top.
        shell.measure = TextMeasure(atlas: atlas, scale: scale)
        shell.size = CGSize(width: CGFloat(Float(width) / scale), height: CGFloat(Float(height) / scale))
        var c = Canvas(list: list, atlas: atlas, scale: scale)
        drawToolStrip(&c)
        colorPage.layout()
        colorPage.refreshStepWindow(panel: monitor.panel, isEditingText: monitor.text.isEditing)
        monitors.draw(&c, card: screen.monitor, scale: scale, isPlaying: s.isPlaying, theme: screen.theme)
        meters.draw(&c, theme: screen.theme)
        inspector.layout(screen.inspector, scale: scale)
        inspector.draw(&c, theme: screen.theme)
        let k = CGFloat(scale), pr = screen.project
        projectList.frame = CGRect(x: CGFloat(pr.x) / k, y: CGFloat(pr.y) / k, width: CGFloat(pr.w) / k, height: CGFloat(pr.h) / k)
        projectList.draw(&c, theme: screen.theme)
        graphics.layout(shell.dock.contentFrame(.graphics)); graphics.draw(&c, theme: screen.theme)
        captions.layout(shell.dock.contentFrame(.text)); captions.draw(&c, theme: screen.theme)
        drawLibraryPanels(&c, scale: scale, theme: screen.theme)
        colorPage.draw(&c, theme: screen.theme)
        drawDockPlaceholders(&c)
        monitors.drawDragTile(&c, scale: scale, theme: screen.theme)
        drawLibraryDragLabels(&c, scale: scale, theme: screen.theme)
        inspector.drawPopover(&c, theme: screen.theme)
        drawChrome(&c)
        HostHover.shared.drawTooltip(&c, theme: screen.theme, now: ProcessInfo.processInfo.systemUptime)
        shell.drawOverlays(&c, theme: screen.theme)
        monitors.drawFullScreen(&c, size: shell.size, theme: screen.theme)   // Program Full Screen covers everything
        presentWelcomeOnce()
        WinPointer.frame(shape: pointerShape(), textEditing: monitor.text.isEditing)
        return c.list
    }

    func handle(_ e: InputEvent) {
        // Panels put their cursor and tip into HostHover while they see the event (the top-most offer wins).
        // WM_MOUSELEAVE arrives as a move far outside the window (Window.swift), which hides the tip.
        HostHover.shared.beginEvent(e)
        defer { HostHover.shared.endEvent(e, now: ProcessInfo.processInfo.systemUptime) }
        // The shell first while a menu or dialog is open, and for clicks on the menu titles; its key route after the panels.
        let scale = screen.theme.scale
        // Program Full Screen: Esc leaves it; keys otherwise route as usual, the mouse has nothing to hit.
        if shell.fullScreenKey(e) { return }
        if shell.isProgramFullScreen { if case .keyDown = e {} else { return } }
        if caption.handle(e, scale: scale) { return }
        if shell.ownsKeyboard { _ = shell.handle(e, scale: scale); mediaChanged(); return }
        if case .keyDown = e {} else if shell.handle(e, scale: scale) { return }
        if monitors.routeTextEditing(e, scale: scale) { return }
        focusDockPanel(e, scale: scale)
        monitors.dropFocus(e)
        if inspector.handlePopover(e, scale: scale) { return }
        if colorPage.handle(e, scale: scale) { return }
        if titleRow.handle(e, scale: scale) { return }
        if projectList.handle(e, scale: scale) { return }
        if graphics.handle(e, scale: scale) { return }
        if captions.handle(e, scale: scale) { return }
        if handleLibraryPanels(e, scale: scale) { return }
        if inspector.handle(e, scale: scale) { return }
        if monitors.handle(e, scale: scale) { return }
        if meters.handle(e) { return }
        if handleToolStrip(e) { return }
        // Timeline events go to the panel first; keys it does not take (transport, undo) fall through to the screen.
        let own: Bool
        switch e {
        case .mouseDown(let x, let y, _), .scroll(let x, let y, _, _, _): own = timelinePanel.contains(x: x, y: y)
        case .mouseDragged, .mouseUp: own = timelinePanel.isDragging
        case .mouseMoved: own = true
        case .keyDown(let k, let m):
            // Esc closes Trim mode first (the Mac key monitor, TL-08), unless a drag runs: that Esc cancels the drag.
            if k == .escape, m.isEmpty, !timelinePanel.isDragging, shell.trim.isActive { shell.trim.exit(); return }
            if let actions = timelinePanel.key(k, modifiers: m) { for a in actions { applyTimeline(a) }; return }
            if shell.handle(e, scale: scale) { mediaChanged(); return }
            own = false
        }
        if own {
            for a in timelinePanel.handle(e) { applyTimeline(a) }
            if case .mouseMoved = e {} else { return }
        }
        let s = snapshot()
        for intent in screen.handle(e, s) { apply(intent) }
    }

    func applyTimeline(_ a: TimelineAction) {
        if case .contextMenu(let p) = a { showTimelineMenu(at: p); return }
        if let m = TimelineSessionBridge.apply(a, to: session, host: timelineHost) { status = m }
        engine.setMedia(session.project.media)
        let moved = paths.set(session.project)
        if !moved.isEmpty { winTimelineMedia?.forget(moved) }
    }

    func apply(_ intent: EditorIntent) {
        switch intent {
        case .seek(let t): session.seek(to: t)
        case .beginScrub: session.beginScrub()
        case .scrub(let t): session.scrub(to: t)
        case .endScrub: session.endScrub()
        case .select(let ids): session.select(clips: ids)
        case .move(let id, let to, let track):
            let t = timeline
            var partners: [Clip.ID: Track.ID] = [:]
            if let clip = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), let link = clip.link {
                for tr in t.tracks { for c in tr.clips where c.link == link && c.id != id { partners[c.id] = tr.id } }
            }
            session.commit(TimelineCommit(timeline: t, edits: [.moveGroup(id, to: to, track: track, partners: partners)],
                                          undoName: "Move", selection: session.selection.union([id])))
            status = "Moved"
        case .razor(let at, let track):
            session.commit(TimelineCommit(timeline: timeline, edits: [.addEdit(at: at, tracks: [track])], undoName: "Cut",
                                          selection: session.selection))
            status = "Cut at \(TimecodeText.string(at, frameDuration: timeline.frameDuration))"
        case .delete(let ripple):
            session.deleteSelection(ripple: ripple)
            status = ripple ? "Ripple deleted" : "Deleted"
        case .undo: status = session.undo() ? "Undo" : "Nothing to undo"
        case .redo: status = session.redo() ? "Redo" : "Nothing to redo"
        case .playPause: session.playPause()
        case .shuttle(let a): session.apply(shuttle: a)
        case .step(let n): session.stepFrames(n)
        case .goToStart: session.goToStart()
        case .goToEnd: session.goToEnd()
        case .monitor(let a): applyMonitor(a)
        case .setMark(let end, let t):
            // The strip reports the stored end, one frame past Out (the Mac host's onMarkEdit).
            if end == .markIn { session.setInPoint(at: t) }
            if end == .markOut { session.setOutPoint(at: t - timeline.frameDuration) }
        case .setInOut(let r, let part): session.moveInOut(to: r, part: part)
        }
        engine.setMedia(session.project.media)
        let moved = paths.set(session.project)
        if !moved.isEmpty { winTimelineMedia?.forget(moved) }
    }
}

extension AppController {
    /// Program monitor commands (MonitorCardHost.applyMonitor, shared with the Mac shared UI).
    func applyMonitor(_ a: MonitorAction) { monitors.applyMonitor(a) }

    /// The pointer shape this frame (SQAppShell `AppPointer` rules).
    func pointerShape() -> AppPointerShape {
        let s = screen.theme.scale, (x, y) = WinPointer.position
        var f = AppPointer.Facts(divider: shell.dock.divider(at: CGPoint(x: CGFloat(x / s), y: CGFloat(y / s)))?.axis,
                                 keystoneEdge: timelinePanel.keystoneEdgeHovered(at: x, y: y), sampling: inspector.isSampling || colorPage.isPicking,
                                 textEditing: monitor.text.isEditing)
        let tool = timelinePanel.toolState
        f.typeToolOverPicture = !source.isShown && tool.tool == .type && tool.createMode == .text
            && monitor.panel.frame.contains(CGPoint(x: CGFloat(x / s), y: CGFloat(y / s)))
        f.handOverTimeline = tool.timelineTool == .hand && timelinePanel.contains(x: x, y: y)
        f.panel = HostHover.shared.cursor
        return AppPointer.shape(f)
    }
}

/// Media id -> file path, read by the audio feeder thread.
final class PathStore: Sendable {
    private let map = Mutex<[UUID: String]>([:])
    /// Files outside the project that get thumbnails too (start screen card pictures), one id per path.
    private let loose = Mutex<[String: UUID]>([:])
    /// Takes the project's paths; returns the media whose path changed (relinked), for the caches to forget.
    @discardableResult
    func set(_ p: Project) -> Set<UUID> {
        let new = Dictionary(p.media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        return map.withLock { old in
            let moved = Set(new.compactMap { id, path in old[id].map { $0 == path ? nil : id } ?? nil })
            old = new
            return moved
        }
    }
    func path(_ id: UUID) -> String? {
        map.withLock { $0[id] } ?? loose.withLock { l in l.first { $0.value == id }?.key }
    }
    func id(forPath path: String) -> UUID { loose.withLock { l in l[path] ?? { l[path] = UUID(); return l[path]! }() } }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
