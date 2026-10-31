import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQUIKit

/// The monitor card of the shared shell (Windows app and Mac `SQ_SHARED_UI`): the Program monitor (`MonitorHost`), the
/// Source monitor (`SourceHost`) as its second tab, the slip / trim two-up, and their wiring to the shell: the Program |
/// Source tabs, the Project panel's double-click, one monitor playing at a time, Source drags onto the timeline, the
/// picture tools (Create, Edit Dynamic Zoom, Show All Angles), Export Frame and the monitor commands.
/// The platform parts are the Program engine and the backend (AppPlatform.swift); the Timeline panel is a value the app
/// owns, reached through `withTimeline`.
@MainActor
public final class MonitorCardHost {
    public let monitor: MonitorHost
    public let source: SourceHost
    public let program: any AppMonitorEngine
    private let backend: AppMonitorBackend
    private let session: EditorSession
    private unowned let shell: ShellHost
    /// The app's Timeline panel, changed in place (drops) or read (tool state).
    public var withTimeline: (_ change: (inout TimelinePanel) -> Void) -> Void = { _ in }
    /// The keys held now (Cmd inserts, Alt replaces on a drop).
    public var modifiers: () -> InputModifiers = { [] }
    /// The Graphics panel's editor (the Type tool's text layers, the Create tool's shapes).
    public var graphics: () -> GraphicsEditor? = { nil }
    /// A drop placed media on the timeline: the app refreshes its media tables.
    public var onPlaced: (() -> Void)?
    /// The monitor tab the dock showed last (`syncTab`).
    private var lastDocked: PanelID?

    public init(session: EditorSession, shell: ShellHost, program: any AppMonitorEngine, backend: AppMonitorBackend,
                effects: EffectControlsModel, projectList: ProjectListView, timelineHost: TimelineHost,
                qualityDefaults: UserDefaults? = .standard) {
        self.session = session
        self.shell = shell
        self.program = program
        self.backend = backend
        let menus = shell.menuBar.controller
        monitor = MonitorHost(session: session, menus: menus)
        source = SourceHost(session: session, shell: shell, backend: backend)
        monitor.sourceMediaID = { [weak source] in source?.core.mediaID }
        wireProgram(effects: effects, timelineHost: timelineHost)
        wireSource(projectList: projectList, menus: menus)
        wireTools()
        // MON-33: Finder files dropped on the Source monitor are imported, then the first opens in Source.
        source.panel.model.onDropFiles = { [weak self] urls in
            guard let self, let model = shell.projectModel else { return }
            shell.spawn { [weak self] in
                await model.importFiles(urls)
                guard let self else { return }
                shell.onProjectChanged?()
                if let id = urls.lazy.compactMap({ model.mediaID(forImported: $0) }).first { source.open(id) }
            }
        }
        // Preferences > Dropped Frames: the Program monitor's drop dot (EditorPanels.applySettings).
        monitor.model.dropIndicatorEnabled = AppSettings.load(from: qualityDefaults ?? .standard).dropIndicator
        let nextDots = shell.onSettingsChanged
        shell.onSettingsChanged = { [weak monitor] s in nextDots?(s); monitor?.model.dropIndicatorEnabled = s.dropIndicator }
        if let qualityDefaults {
            monitor.rememberQuality(in: qualityDefaults)
            let next = shell.onSettingsChanged
            shell.onSettingsChanged = { [weak monitor] s in next?(s); monitor?.applyQuality?(s) }
        }
    }

    private var toolState: ToolState {
        var s = ToolState()
        withTimeline { s = $0.toolState }
        return s
    }

    private func wireProgram(effects: EffectControlsModel, timelineHost: TimelineHost) {
        let m = monitor
        m.onAction = { [weak self] in self?.applyMonitor($0) }
        m.attachOverlay(effects: effects, modifiers: { [weak self] in self?.modifiers() ?? [] })
        m.onCommand = { [weak shell] in _ = shell?.execute($0) }
        // Program monitor options > Full Screen (the Mac `ProgramPresentation`): the shell shows only the picture, Esc leaves.
        m.model.onFullScreen = { [weak shell] in _ = shell?.enterProgramFullScreen() }
        m.onStatus = { [weak shell] in shell?.onStatus?($0) }
        m.maskToolNow = { [weak self] in
            guard let s = self?.toolState, s.tool == .mask else { return nil }
            return s.maskMode
        }
        // The Type tool (Create slot in Text mode) and the graphic text edits (MonitorTextHost).
        m.text.graphics = { [weak self] in self?.graphics() }
        m.panel.handToolOn = { [weak self] in self?.toolState.tool == .hand }
        m.panel.typeToolOn = { [weak self] in
            guard let s = self?.toolState else { return false }
            return s.tool == .type && s.createMode == .text
        }
        let slip = SlipTwoUpHost(session: session, backend: backend)
        m.slip = slip
        timelineHost.slipTwoUp = { [weak slip] two, preview in slip?.sync(two, preview: preview) }
    }

    private func wireSource(projectList: ProjectListView, menus: MenuController) {
        let s = source
        s.panel.onMenu = { [weak menus] items, anchor, pointer in
            guard let menus else { return }
            if let pointer { menus.present(items: items, at: pointer, pointer: pointer) }
            else { menus.present(items: items, at: CGPoint(x: anchor.minX, y: anchor.maxY), anchor: anchor) }
        }
        monitor.panel.tabs = ["Program", "Source"]
        monitor.panel.selectedTab = 0
        let select: (Int) -> Void = { [weak self] i in
            guard let self else { return }
            source.isShown = i == 1
            shell.focus = i == 1 ? .sourceMonitor : .programMonitor
        }
        monitor.panel.onSelectTab = select
        s.panel.onSelectTab = select
        // Only one monitor plays: starting the Source stops the Program (the Program side is checked per frame).
        s.core.onStartedPlaying = { [weak session] in session?.stopPlayback() }
        s.core.onRevealInProject = { [weak projectList] id in projectList?.reveal(media: id) }
        projectList.onOpenMedia = { [weak s] id in s?.open(id) }
        s.panel.onSourceDrag = { [weak self] streams, phase, x, y in self?.sourceDragged(streams, phase, x: x, y: y) }
        let next = shell.onCommand
        shell.onCommand = { [weak s, weak projectList, weak shell] c in
            if c == .setPosterFrame || c == .clearPosterFrame, let s, let projectList, let model = shell?.projectModel {
                let core = s.core
                let at = core.mediaID.map { (media: $0, time: core.currentTime) }
                if let line = PosterFrameCommand.run(clear: c == .clearPosterFrame, selected: projectList.selection, source: at,
                                                     hovered: projectList.hoveredFrame, model: model) { shell?.onStatus?(line) }
                return true
            }
            return s?.command(c) == true || next?(c) == true
        }
    }

    /// The monitors' picture tools (App/Sources/EditorPanels+CreateTool.swift, +DynamicZoomEdit.swift, +AnglesGrid.swift):
    /// the Create tool's mode, Edit Dynamic Zoom and the multi-angle Source view.
    private func wireTools() {
        let m = monitor, s = source
        m.panel.createModeNow = { [weak self] in
            guard let t = self?.toolState, t.tool == .type, t.createMode != .text else { return nil }
            return t.createMode
        }
        m.attachPictureTools(graphics: { [weak self] in self?.graphics() })
        s.core.onToggleAngles = { [weak self] in
            guard let self else { return }
            source.showsAllAngles.toggle()
            refreshAnglesGrid()
        }
        s.core.anglesAvailable = { [weak self] in self?.anglesPiece() != nil }
        s.core.model.onPickAngle = { [weak self] i in
            guard let self, let piece = anglesPiece() else { return }
            session.setAngle(i, on: piece.id)
        }
        let next = shell.onCommand
        shell.onCommand = { [weak self] c in
            guard let self else { return next?(c) == true }
            switch c {
            case .editDynamicZoom:
                if !monitor.toggleDynamicZoomEdit() {
                    shell.onStatus?("Select a video clip and put the playhead on it to edit its zoom.")
                }
            // View > Safe Margins and Show Overlays: the Program monitor's own remembered switches.
            case .toggleSafeAreas: monitor.model.safeMargins.toggle()
            case .toggleOverlays: monitor.model.toggleOverlays()
            default: return next?(c) == true
            }
            return true
        }
        shell.menuChecks.append { [weak m] in
            guard let m else { return [] }
            var s: Set<EditorCommand> = []
            if m.model.safeMargins { s.insert(.toggleSafeAreas) }
            if !m.model.overlaysHidden { s.insert(.toggleOverlays) }
            return s
        }
    }

    // MARK: Commands

    /// Program monitor commands (the Mac AppController's MonitorAction routing for the Program monitor).
    public func applyMonitor(_ a: MonitorAction) {
        switch a {
        case .markIn: session.markIn()
        case .markOut: session.markOut()
        case .goToIn: session.goToIn()
        case .goToOut: session.goToOut()
        case .clearIn: session.clearIn()
        case .clearOut: session.clearOut()
        case .clearInOut: session.clearInOut()
        case .addMarker: session.addMarkerAtPlayhead()
        case .lift: session.liftRange()
        case .extract: session.extractRange()
        case .loop: session.toggleLoop()
        case .playInToOut: session.playInToOut()
        case .playPause: session.playPause()
        case .stepBack: session.stepFrames(-1)
        case .stepForward: session.stepFrames(1)
        case .toggleSafeMargins: monitor.model.safeMargins.toggle()
        case .exportFrame: exportFrame()
        case .insert, .overwrite, .replace, .fitToFill: source.core.perform(a)
        }
    }

    /// Export Frame for the Program monitor (the Mac `exportProgramFrame`): the platform engine's frame as a PNG.
    public func exportFrame() {
        program.exportFrame(suggestedName: (session.activeTimeline?.name ?? "Frame") + ".png",
                            files: shell.files as? PanelFileChooser) { [weak shell] in shell?.onStatus?($0) }
    }

    // MARK: Project drops on the monitor

    /// Project items dragged over the shown monitor (`MonitorPanelView.performDragOperation`): the card shows its drop
    /// highlight, the Program names the half under the pointer; on release the Program inserts (left half) or overwrites
    /// (right half) at the playhead, the Source opens the clips. `x, y` are window pixels. True when the release was taken.
    @discardableResult
    public func projectDragged(_ refs: [BinItemRef], phase: TimelineDropRoute.Phase, x: Float, y: Float) -> Bool {
        let panel = source.isShown ? source.panel : monitor.panel
        func clear() { for p in [monitor.panel, source.panel] { p.dropHighlight = false; p.dropZone = nil } }
        let ids = refs.compactMap { if case .media(let id) = $0 { id } else { nil } }
        let k = CGFloat(max(panel.scale, 0.01))
        let local = CGPoint(x: CGFloat(x) / k - panel.frame.minX, y: CGFloat(y) / k - panel.frame.minY)
        let over = !ids.isEmpty && phase != .canceled && panel.frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        guard over else { clear(); return false }
        let zone = MonitorDropZone.zone(atX: local.x, width: panel.frame.width)
        if phase == .moved {
            clear()
            panel.dropHighlight = true
            panel.dropZone = panel.model.mode == .program ? zone : nil
            return false
        }
        clear()
        if panel.model.mode == .program {
            _ = session.placeMedia(ids, mode: zone == .insert ? .insert : .overwrite)   // SH-54: drop media = Insert / Overwrite at the playhead
            onPlaced?()
        } else {
            _ = source.core.open(all: ids)
        }
        return true
    }

    /// Finder files dragged over the Source tab (`MonitorPanelView.droppedFiles`): the card shows its drop highlight; on release
    /// the files are imported and the first one opens in Source (MON-33). True when the release was taken. The Program tab
    /// leaves Finder files to the timeline and the import fallback. `x, y` are window pixels.
    @discardableResult
    public func filesDragged(_ urls: [URL], phase: TimelineDropRoute.Phase, x: Float, y: Float) -> Bool {
        let panel = source.panel
        func clear() { panel.dropHighlight = false; panel.dropZone = nil }
        let k = CGFloat(max(panel.scale, 0.01))
        let files = urls.filter { !$0.hasDirectoryPath }
        let over = source.isShown && !files.isEmpty && phase != .canceled && panel.frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        clear()
        guard over else { return false }
        if phase == .moved { panel.dropHighlight = true; return false }
        panel.model.onDropFiles?(files)
        return true
    }

    // MARK: Source drags

    /// The Source picture (both streams) or a footer handle (one stream) dragged onto the timeline: the Project list's
    /// drop path with the Source clip and those streams (the Mac `dragItem` + `dropStreamsProvider`). The timeline shows its
    /// drop preview, `drawDragTile` the tile under the pointer (the Mac drag image).
    func sourceDragged(_ streams: SourceStreams, _ phase: MonitorDragPhase, x: Float, y: Float) {
        dragTile = phase == .moved ? (streams, x, y) : nil
        guard let id = source.core.mediaID else { return }
        let p: TimelineDropRoute.Phase = switch phase { case .moved: .moved; case .ended: .ended; case .canceled: .canceled }
        let mods = modifiers(), core = source.core
        var placed = false
        withTimeline { [session, shell] panel in
            placed = TimelineDropRoute.drag(.media([id]), streams: streams, phase: p, x: x, y: y, modifiers: mods,
                                            panel: &panel, session: session,
                                            sourceTime: { core.mediaID == $0 ? core.currentTime : nil },
                                            status: { shell.onStatus?($0) })
        }
        if placed { onPlaced?() }
    }

    /// The Source drag running now: its streams and the pointer in window pixels.
    public private(set) var dragTile: (streams: SourceStreams, x: Float, y: Float)?

    /// The Source drag's tile over every panel: the host calls it after the panels, before menus and popovers.
    public func drawDragTile(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        guard let d = dragTile else { return }
        let k = CGFloat(max(scale, 0.01))
        SourceDragGhost.draw(&c, streams: d.streams, pointer: CGPoint(x: CGFloat(d.x) / k, y: CGFloat(d.y) / k), theme: theme)
    }

    // MARK: Angles

    /// The video piece of an Angles clip under the playhead (the tiles show its picture angles).
    private func anglesPiece() -> Clip? {
        guard let tl = session.activeTimeline, let c = tl.anglesClip(at: session.playhead), c.kind == .video else { return nil }
        return c
    }

    /// Per frame while the Source shows: the tiles of every angle at the playhead (thumbnails from the timeline's atlas).
    func refreshAnglesGrid() {
        let model = source.core.model
        guard source.showsAllAngles, let tl = session.activeTimeline, let piece = anglesPiece(),
              let inner = piece.sequence.flatMap({ session.project.timeline($0) }) else {
            if model.angleTiles != nil { model.angleTiles = nil }
            return
        }
        let fd = tl.frameDuration
        let frames = inner.angleFrames(at: piece.angleInnerTime(at: session.playhead.snapped(to: fd)), frameDuration: fd)
        let names = inner.angleNames
        let active = min(max(piece.angle?.index ?? 0, 0), max(frames.count - 1, 0))
        let media = backend.timelineMedia
        let tiles = frames.enumerated().map { i, f in
            AngleTile(name: i < names.count ? names[i] : "Angle \(i + 1)",
                      picture: f.flatMap { frame in media?.picture(media: frame.media, at: frame.time) }
                          .map { AngleTile.Picture(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1) },
                      isActive: i == active)
        }
        if model.angleTiles != tiles { model.angleTiles = tiles }
    }

    // MARK: Frame and input

    /// The monitor header's Program | Source tabs and the dock's selected tab follow each other: a dock change (Window
    /// menu, Show Source Monitor) moves the header, a header click or an opened clip moves the dock. Call after the dock's
    /// layout.
    public func syncTab(dock d: ShellDock) {
        let docked: PanelID? = d.shows(.programMonitor) ? .programMonitor : d.shows(.sourceMonitor) ? .sourceMonitor : nil
        guard let docked else { return }
        let header: PanelID = source.isShown ? .sourceMonitor : .programMonitor
        if docked != lastDocked {
            lastDocked = docked
            if docked != header { source.isShown = docked == .sourceMonitor }
            monitor.panel.selectedTab = source.isShown ? 1 : 0
        } else if docked != header, d.groups.contains(where: { $0.panels.contains(header) && $0.panels.contains(docked) }) {
            d.show(header)
            lastDocked = header
        }
    }

    /// The monitor card: the shown tab lays out and draws; the hidden Source stops playing.
    public func draw(_ c: inout Canvas, card: DrawRect, scale: Float, isPlaying: Bool, theme: DrawTheme) {
        if source.core.isPlaying, isPlaying || !source.isShown { source.core.pause() }
        refreshOfflineAndSize()
        monitor.hidesTransformBox = shell.dock.store.page == .color
        monitor.panel.isFocused = shell.focus == .programMonitor
        source.panel.isFocused = shell.focus == .sourceMonitor
        if source.isShown {
            refreshAnglesGrid()
            source.layout(card, scale: scale)
            source.draw(&c, theme: theme)
        } else {
            monitor.layout(card, scale: scale, playhead: session.playhead, isPlaying: isPlaying,
                           hasPicture: program.hasPicture, dropped: program.skippedFrames)
            monitor.draw(&c, theme: theme)
        }
    }

    /// Full Screen: the Program picture alone over the whole window (call last), with the Mac's hint for the first seconds.
    public func drawFullScreen(_ c: inout Canvas, size: CGSize, theme: DrawTheme) {
        guard shell.isProgramFullScreen else { return }
        let full = CGRect(origin: .zero, size: size)
        c.fill(full, theme.monitorBackdrop)
        let f = session.activeTimeline?.format
        let r = ShellHost.fullScreenPictureRect(in: size, picture: (f?.displayWidth ?? 0, f?.height ?? 0))
        c.fill(r, .black)
        if program.hasPicture { c.list.video(c.px(r)) }
        if ProcessInfo.processInfo.systemUptime - shell.fullScreenStarted < 3 {
            c.draw(SQL10n.string("Press Esc to exit full screen"), in: CGRect(x: 0, y: size.height - 48, width: size.width, height: 20),
                   fontSize: 13, DrawColor.white.alpha(0.8), align: .center)
        }
    }

    /// The "Media offline" card and the resolution badge of both monitors, per frame like the AppKit
    /// `EditorPanels.refreshOfflineAndSize` (equal values are not re-assigned).
    public func refreshOfflineAndSize() {
        let project = session.project, model = shell.projectModel
        func name(_ id: UUID) -> String? { model?.isOffline(id) == true ? (project.media(id)?.name ?? "Media") : nil }
        let m = monitor.model
        if let tl = session.activeTimeline {
            let n = MediaOfflineCard.fileName(in: tl, at: session.playhead, offlineName: name)
            if m.offlineFileName != n { m.offlineFileName = n }
            let w = tl.format.displayWidth, h = tl.format.height
            if m.pictureSize?.width != w || m.pictureSize?.height != h { m.pictureSize = (w, h) }
        } else if m.offlineFileName != nil { m.offlineFileName = nil }
        let sm = source.core.model, id = source.core.mediaID
        let n = id.flatMap(name)
        if sm.offlineFileName != n { sm.offlineFileName = n }
        let v = id.flatMap { project.media($0)?.info?.video }
        if sm.pictureSize?.width != v?.width || sm.pictureSize?.height != v?.height {
            sm.pictureSize = v.map { (width: $0.width, height: $0.height) }
        }
    }

    /// The monitor card's events: the shown tab; a press on the card gives it keyboard focus, a press elsewhere takes the
    /// monitor focus away (`dropFocus`). While the Source has focus its keys go to the shell's key map first.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        if case .keyDown = e, source.isShown, source.isFocused, shell.handle(e, scale: scale) { return true }
        if source.isShown { return source.handle(e, scale: scale) }
        guard monitor.handle(e, scale: scale) else { return false }
        if case .mouseDown = e { shell.focus = .programMonitor }
        return true
    }

    /// The on-canvas text editor's keys and presses, before any other panel (Program tab only).
    public func routeTextEditing(_ e: InputEvent, scale: Float) -> Bool {
        if source.isShown { return source.panel.isEditingTimecode && MonitorHost.routeTimecode(e, scale: scale, panel: source.panel) }
        return monitor.routeTextEditing(e, scale: scale)
    }

    /// Go to Timecode (the Mac focuses the monitor's timecode field): the shown monitor's field opens, its text
    /// selected; false while the Source tab shows no clip.
    public func focusTimecodeField() -> Bool {
        if source.isShown, source.panel.model.duration <= .zero { return false }
        (source.isShown ? source.panel : monitor.panel).focusTimecodeField()
        return true
    }

    /// A press anywhere takes the monitor focus away (the card's own press gives it back).
    public func dropFocus(_ e: InputEvent) {
        if case .mouseDown = e, shell.focus == .sourceMonitor || shell.focus == .programMonitor { shell.focus = nil }
    }

    /// The engine whose picture the card shows now.
    public var shownEngine: any AppMonitorEngine { source.isShown ? source.engine : program }
}
