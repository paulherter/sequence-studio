import AppKit
import CoreVideo
import Metal
import SQAnalysis
import SQAppShell
import SQCore
import SQDrawEditor
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQEditorUI
import SQMedia
import SQExport
import SQInspectorUI
import SQMonitorUI
import SQPlayback
import SQText
import SQTimelineUI
import SQTranscribe
import SQUIKit

/// The Mac app on the shared draw-list UI (the Windows port plan, "Panel status: Mac on shared UI"): the same SQDrawShell
/// shell (menu bar, dock, start screen, dialogs), EditorScreen and SQDrawTimeline panels the Windows app runs, drawn by
/// `CoreGraphicsRenderer` in `SharedUIView`. The default on the Mac; the AppKit UI runs only with `SQ_APPKIT_UI=1` (or `--appkit-ui`).
/// It mirrors the Windows `AppController` (Windows/SQWinApp) and runs the hosts moved to SQAppShell (Effect Controls with the
/// shared color picker, Graphics, Captions, Library, Effects, audio meters, Scopes, the Program and Source monitors). The Program and Source pictures are Metal `PlaybackEngine`s presenting into
/// `viewer` / the backend's `sourceViewer` under the UI view, each inside a clipping container placed on the picture quad.
@MainActor
final class SharedUIController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var isRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SQ_SHARED_UI"] == "1" || env["SQ_SHARED_UI_SHOT"] != nil || CommandLine.arguments.contains("--shared-ui") { return true }
        // The AppKit UI is the fallback: SQ_APPKIT_UI=1 (or --appkit-ui), and the AppKit-only panel render mode.
        return env["SQ_APPKIT_UI"] != "1" && !CommandLine.arguments.contains("--appkit-ui") && env["SQ_RENDER_PANELS"] == nil
    }

    /// Panels this host draws; the others get `ShellDock.drawPlaceholder`.
    static let hostedPanels: Set<PanelID> = [.programMonitor, .sourceMonitor, .effectControls, .project, .timeline, .audioMeter,
                                                    .scopes, .graphics, .text, .library, .effects, .colorInspector, .steps, .colorClips,
                                                    .keystones, .markerList]

    let session: EditorSession
    let engine: any ProgramEngine
    let shell: ShellHost
    let atlas: GlyphAtlas
    let projectModel: ProjectPanelModel
    /// Its plain bars stay undrawn: the title row and `StatusBarDraw` take their place.
    var screen: EditorScreen = { var s = EditorScreen(); s.drawsBars = false; return s }()
    var timelinePanel = TimelinePanel()
    var cacheStrip = CacheStripGate()
    var toolStrip = ToolStrip()
    /// The timeline's header bar (tabs, Normal | Fast Cut, Snapping, Linked Selection, Add Marker, Fit; SQAppShell).
    lazy var timelineHeader = TimelineHeaderHost(session: session, shell: shell, host: { [weak self] in self?.timelineHost }) {
        [weak self] change in if let self { change(&timelinePanel) }
    }
    lazy var timelineHost = makeTimelineHost()
    lazy var projectList = ProjectListView(host: shell)
    let files = MacShellFilePicker()
    /// Conform to Constant Frame Rate jobs of the Project menu.
    let conformRunner = ConformRunner()
    /// Background work of every kind (SharedUIController+Jobs.swift); polled while the app runs.
    let jobCenter = JobCenter()
    /// Dock progress and the "Export finished" notification.
    let exportNotifier = ExportNotifier()
    /// The Program picture: the engine's CAMetalLayer, under the UI view, moved onto the picture quad every frame.
    let viewer = ViewerView(frame: .zero)
    /// The clipping containers of the Program and Source viewers (a zoom above Fit makes the quad larger than its card).
    let viewerClip = NSView(frame: .zero)
    let sourceClip = NSView(frame: .zero)
    lazy var picture: MacPictureTap = {
        let t = MacPictureTap(engine: engine)
        t.window = { [weak self] in self?.window }
        return t
    }()
    let media: ProjectMediaResolver
    let mediaStore = MacTimelineMedia()
    let backend: MacMonitorBackend
    /// Effect Controls (SQAppShell `InspectorHost`) with the shared popovers (color picker, curves, Multiband, eyedropper).
    /// "..." in the tab strips of Controls, Text, Graphics and Marker List (the Mac strip's tab menu).
    lazy var tabOptions = TabMenuOptions(panels: [.effectControls, .text, .graphics, .markerList], dock: shell.dock,
                                         menus: shell.menuBar.controller)
    lazy var inspector: InspectorHost = {
        let h = InspectorHost(session: session, menus: shell.menuBar.controller, shell: shell, sampler: sampler)
        h.onShowGraphics = { [weak self] in self?.shell.dock.show(.graphics) }
        return h
    }()
    let sampler = MacScreenSampler()
    /// The Graphics card (SQAppShell `GraphicsHost`); its editor is the Type and Create tools' layer editor too.
    lazy var graphics: GraphicsHost = {
        let g = GraphicsHost(session: session, menus: shell.menuBar.controller, shell: shell, inspector: inspector)
        g.modifiers = { MacKeys.modifiers(flags: NSEvent.modifierFlags.rawValue) }
        return g
    }()
    lazy var monitors: MonitorCardHost = {
        let h = MonitorCardHost(session: session, shell: shell, program: picture, backend: backend, effects: inspector.model,
                                projectList: projectList, timelineHost: timelineHost)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.modifiers = { MacKeys.modifiers(flags: NSEvent.modifierFlags.rawValue) }
        h.graphics = { [weak self] in self?.graphics.editor }
        let magic = MacMagicMasks(model: inspector.model, session: session) { [weak self] in self?.shell.onStatus?($0) }
        magic.onTracked = { [weak self] in self?.shell.magicHealth?.forget() }
        h.monitor.magic = magic
        return h
    }()
    /// The Library and Effects cards (SharedUILibrary.swift).
    lazy var library: LibraryHost = makeLibraryHost()
    let libraryFrames = LibraryPreviewFrames()
    lazy var effects: EffectsHost = makeEffectsHost()
    /// The Text card; its swatches open Controls' color picker.
    lazy var captions: CaptionsHost = {
        let h = CaptionsHost(session: session, menus: shell.menuBar.controller, shell: shell)
        h.useTranscription { SpeechAnalyzerTranscriber() }
        shell.voiceover = Self.voiceoverBackend
        h.pickColor = { [weak self] color, anchor, change in self?.inspector.pickColor(color, anchor: anchor, change) }
        return h
    }()
    /// Voiceover from Text speaks with the Mac's voices (`SpeechRenderer`); the shell flow itself is portable.
    static var voiceoverBackend: ShellVoiceoverBackend {
        ShellVoiceoverBackend(
            voices: {
                let all = SpeechRenderer.voices()
                let first = SpeechRenderer.defaultVoiceID(in: all, remembered: VoiceoverMemory.voice())
                let ordered = all.filter { $0.id == first } + all.filter { $0.id != first }
                return ordered.map { (id: $0.id, title: "\($0.name) (\($0.language))" + ($0.isEnhanced ? " - enhanced" : "")) }
            },
            render: { text, voice, rate, url in
                do { return try await SpeechRenderer.render(text: text, voiceID: voice, rate: rate, to: url) }
                catch SpeechError.noAudio { throw ShellVoiceoverError.noAudio }
            })
    }
    /// Window > Keystones as a dock panel (SQAppShell `KeystonesHost`); Controls' text animations read its list.
    lazy var keystones: KeystonesHost = {
        let h = KeystonesHost(session: session, menus: shell.menuBar.controller, shell: shell)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.timelineHost = { [weak self] in self?.timelineHost }
        h.inspectorDropClip = { [weak self] in self?.inspectorDropClip($0) }
        h.openEase = { [weak self] source, anchor in self?.inspector.openEase(source, anchor: anchor) }
        h.dock(in: shell.dock)
        inspector.keystones = h.model
        return h
    }()
    /// Trim mode on screen: the Before / After two-up, the bar under the timeline (SQAppShell `TrimModeHost`).
    lazy var trimHost = TrimModeHost(shell: shell, slip: { [weak self] in self?.monitors.monitor.slip },
                                     selectEdges: { [weak self] in self?.timelinePanel.selectEdges($0) })
    /// Window > Marker List (SQAppShell `MarkerListHost`), also File > Export Markers as CSV….
    lazy var markerList = MarkerListHost(session: session, shell: shell)
    /// Track Volume and Pan, Sequence Volume, Save as Preset / Transition / Title Block / Template, New Color Matte,
    /// Create Angles Clip, caption text (the AppKit `EditorPanels` sheets on the shared dialog).
    lazy var editorDialogs: TimelineEditorDialogs = {
        let d = TimelineEditorDialogs(session: session, shell: shell)
        d.templateThumbnail = { [engine] in
            var png: Data?
            await engine.withFullSizeFrame { result in
                if case .frame(let texture) = result { png = EditorPanels.thumbnailPNG(texture) }
            }
            return png
        }
        return d
    }()
    lazy var meters: MeterScopesHost = {
        let h = MeterScopesHost(session: session, engine: engine, picture: picture, menus: shell.menuBar.controller)
        h.meter.meter.style = MeterStyle.current()
        // The monitor menu's Scopes row shows or hides the Scopes panel; the slip two-up rides the meters' image list.
        monitors.monitor.model.onShowScopes = { [weak self] in self?.shell.dock.toggle(.scopes) }
        h.monitorImage = { [weak self] in self?.monitors.monitor.slip?.image ?? self?.monitors.monitor.maskTint }
        h.dock(in: shell.dock)
        return h
    }()
    /// The Color page (SQAppShell `ColorPageHost`): the Edit | Color switch, Color settings, Steps, Sources, viewer header.
    lazy var colorPage: ColorPageHost = makeColorPage()
    /// The title row's name, edit time, Workspace popup and Export button (SQAppShell `TitleRowHost`).
    lazy var titleRow: TitleRowHost = makeTitleRow()
    /// When the project last changed (the AppKit `lastDirtyChange`): the status bar's backup check and the edit time.
    private var lastEdit: Date?
    private var imageCache: [Int: (generation: Int, image: CGImage)] = [:]
    /// A flash line (the AppKit `StatusBar.flash`): shown for `flashSeconds`, then the running job's line comes back.
    var status = "" { didSet { statusSet = Date() } }
    private var statusSet = Date.distantPast
    static let flashSeconds = 5.0
    /// A running background job's line ("Anonymize: analyzing ... 42 %", the AppKit `StatusBar.setJob`): stays until nil.
    var job: String?
    /// The status bar's message: a live flash, else the job line.
    var statusMessage: String {
        !status.isEmpty && Date().timeIntervalSince(statusSet) < Self.flashSeconds ? status : (job ?? "")
    }
    var window: NSWindow?
    /// The start screen's own window (nil in the offscreen shot, where the start screen stays an overlay).
    var startWindow: SharedUIStartWindow?
    /// The shell's menus in the macOS menu bar (the in-window bar shows no titles on the Mac).
    var systemMenu: SharedUIMainMenu?
    var view: SharedUIView?
    /// The floating panels' windows and the last full editor frame they show their parts of (SharedUIController+Floating.swift).
    var floatingWindows: [PanelID: SharedUIFloatingWindow] = [:]
    var canvasFrame: DrawList?
    /// `ShellFloating.revision` the OS windows were last matched to.
    var floatingRevision = -1
    private var welcomeChecked = false
    /// The card import's mount and unmount observers (SharedUIController+ShellHooks.swift).
    var cardObservers: [NSObjectProtocol] = []
    private var quitAllowed = false
    /// The local Edit API server, as the AppKit app's `AppController.editAPI`.
    private(set) lazy var editAPI = EditAPIController(session: session) { [weak self] in self?.timelinePanel.isDragging == true }

    override init() {
        // The Mac sets UI text in the system font, as the AppKit UI does; Inter where it cannot be read (and on Windows).
        guard let atlas = GlyphAtlas(font: GlyphRasterFont.macSystemUI ?? .inter) else { fatalError("no UI font loaded") }
        self.atlas = atlas
        atlas.pointScale = 2
        let media = ProjectMediaResolver()
        self.media = media
        var engine: any ProgramEngine = StubProgramEngine()
        let device = MTLCreateSystemDefaultDevice()
        if let device {
            do { engine = try PlaybackEngine(device: device, media: media, audio: AudioEngine(media: media)) } catch {
                SQLog.error("shared UI: playback engine unavailable: \(error)")
            }
        }
        self.engine = engine
        let session = EditorSession(engine: engine, media: media)
        self.session = session
        projectModel = ProjectPanelModel(project: session.project, onEdit: { [weak session] p, name in
            session?.perform(name) { $0 = p }
        })
        session.engine.audioScrubbing = AppSettings.load().audioScrubbing
        session.setSelectionFollowsPlayhead(AppSettings.load().selectionFollowsPlayhead)
        session.newSequenceEditMode = AppSettings.load().newSequenceEditMode
        shell = ShellHost(session: session, map: KeymapStore().load().map, recents: RecentProjects.load())
        shell.effectDefaultsLibrary = .shared   // Preferences > Editing lists the defaults the Mac list shows
        backend = MacMonitorBackend(device: device, media: media, mediaStore: mediaStore)
        super.init()
        backend.window = { [weak self] in self?.window }
        backend.registerEngine = { [weak session] in session?.addAuxiliaryEngine($0) }
        wireJobs()
        wireShell()
        wireMedia()
        wireExport()
        wireShellHooks()
        wireAnonymize()
    }

    private func wireShell() {
        shell.files = files
        shell.saveRecents = { $0.save() }
        shell.onStatus = { [weak self] in self?.status = $0 }
        shell.showCaptionSearch = { [weak self] in
            guard let self else { return false }
            return timelinePanel.showCaptionSearch(window: shell.size)
        }
        shell.menuBar.drawsBackground = false
        shell.menuBar.showsTitles = false
        shell.menuBar.height = CGFloat(DrawTheme.Metrics.topBar)
        projectModel.onCoalescingEdit = { [weak session] p, name, key in session?.perform(name, coalescing: key) { $0 = p } }
        shell.projectModel = projectModel
        screen.projectWidth = 280
        projectList.onOpenSequence = { [weak session] in session?.openSequenceTab($0) }
        projectList.showsTitle = false   // the dock's tab strip names it
        projectList.dock(in: shell.dock)   // and carries the count, New Folder and "..."
        projectList.onCollect = { [weak self] in self?.collectFiles() }
        projectModel.projectFolder = { [weak session] in MediaManagement.projectFolder(forProjectAt: session?.fileURL) }
        shell.revealFile = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        shell.revealFiles = { NSWorkspace.shared.activateFileViewerSelecting($0) }
        shell.openURL = { NSWorkspace.shared.open($0) }
        shell.aboutSupporters = { AppController.bundledSupporters() }
        shell.copyText = { s in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
        // Cmd-C / X / V inside an open drawn field use the system pasteboard (the field editor of the AppKit app).
        TextClipboard.shared.writeSystem = shell.copyText
        TextClipboard.shared.readSystem = { NSPasteboard.general.string(forType: .string) }
        shell.mediaClipboard = { PasteMedia.read() }
        shell.fillMenuState = { $0.toolStripVisible = ToolStripPrefs.visible }
        shell.onQuit = { [weak self] in self?.quitAllowed = true; NSApp.terminate(nil) }
        wireFloating()
        shell.onAction = { [weak self] a in
            switch a {
            case .minimize: self?.window?.miniaturize(nil); return true
            case .zoom: self?.window?.zoom(nil); return true
            case .toggleToolStrip: ToolStripPrefs.visible.toggle(); return true
            case .newColorMatte: self?.editorDialogs.presentNewColorMatte(); return true
            case .hide: NSApp.hide(nil); return true
            case .hideOthers: NSApp.hideOtherApplications(nil); return true
            case .showAll: NSApp.unhideAllApplications(nil); return true
            default: return false
            }
        }
        shell.onKeymapChanged = { CommandMap.current = $0 }
        CommandMap.current = shell.map
        let d = shell.dock
        d.ownsHeader = { $0 == .programMonitor || $0 == .sourceMonitor }
        d.save = { s in
            do { try s.save() } catch { SQLog.error("workspaces save failed: \(error.localizedDescription)") }
        }
        d.presentMenu = { [weak self] items, p in self?.shell.menuBar.controller.present(items: items, at: p, pointer: p) }
        d.load(WorkspaceStore.load())
        d.focused = .timeline
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            guard let self, change.contains(.project) else { return }
            if session.isDirty { lastEdit = Date() }
            if projectModel.project != session.project { projectModel.setProject(session.project) }
            mediaStore.set(session.project)
        }
        timelinePanel.connectHostDefaults(session: session)
        timelinePanel.loadHeightPrefs()     // the AppKit `EditorPanels` default: Medium rows (V 40, A 32), not stretched
        timelinePanel.keyLanes = inspector.keyLanes   // key lanes of the section selected in Effect Controls
        // Preferences (Interface Size, Meter Response) apply when the shell's settings change, as on Windows.
        let settingsNext = shell.onSettingsChanged
        shell.onSettingsChanged = { [weak self] s in settingsNext?(s); self?.applySettings() }
        let next = shell.onCommand
        shell.onCommand = { [weak self] c in
            // Speed band, then the panel's view commands (Snapping, Linked Selection, Fast Cut, zoom when the timeline is the
            // zoom target, track heights, edge trims), as on Windows; the rest goes on to the shell.
            guard let self else { return next?(c) ?? false }
            let zooms = CommandRouting.zoomTarget(focus: shell.focus, effectControlsFocused: false) == .timeline
            guard let line = timelinePanel.runSpeedCommand(c, session: session)
                    ?? timelinePanel.runViewCommand(c, session: session, zooms: zooms, host: timelineHost,
                                                 ownsDelete: shell.focus == nil || shell.focus == .timeline) else { return next?(c) ?? false }
            if !line.isEmpty { shell.onStatus?(line) }
            return true
        }
    }

    /// Thumbnails, waveforms and posters (MacTimelineMedia), Project list drags onto the timeline.
    private func wireMedia() {
        timelinePanel.media = mediaStore
        mediaStore.set(session.project)
        // Apply Transition acts on the selected edit points; Audio Gain, Auto Duck, Remove Silences and Sync Audio read the
        // waveforms (Audio Gain's clip peak comes from them).
        shell.edgeSelection = { [weak self] in self?.timelinePanel.interaction.edgeSelection }
        shell.waveform = { [mediaStore] in mediaStore.waveform(media: $0) }
        // Posters: the item's poster frame (Set Poster Frame, `MediaRef.posterTime`), else the first frame.
        projectList.poster = { [mediaStore, weak session] id in
            mediaStore.picture(media: id, at: session?.project.media(id)?.posterTime).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        // Start screen cards: the poster media's frame at the poster time, from the same atlas.
        shell.startPoster = { [mediaStore] path, seconds in
            mediaStore.picture(media: mediaStore.id(forPath: path), at: Time(Int64(max(seconds, 0) * 1000), 1000)).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        projectList.onDrag = { [weak self] refs, phase, x, y in
            guard let self, let item = TimelineDropRoute.source(refs) else { return }
            let p: TimelineDropRoute.Phase = switch phase { case .moved: .moved; case .ended: .ended; case .canceled: .canceled }
            // Over the Program or Source monitor the items insert, overwrite or open there, not on the timeline.
            if monitors.projectDragged(refs, phase: p, x: x, y: y) { return }
            let core = monitors.source.core
            TimelineDropRoute.drag(item, phase: p, x: x, y: y, modifiers: MacKeys.modifiers(flags: NSEvent.modifierFlags.rawValue),
                                   panel: &timelinePanel, session: session,
                                   sourceTime: { core.mediaID == $0 ? core.currentTime : nil }, status: { [weak self] in self?.status = $0 })
        }
    }

    /// File > Export on the shared dialog: the AVFoundation encoder and the Mac export sources (ExportCoordinator's
    /// provider: track audio presets, proxies and render-cache segments as `ExportCoordinator.makeModel` reads them).
    /// shortcut: no dialogue-silence ducking pass in the export (the live duck holds whole clips); upgrade by moving
    /// ExportCoordinator.makeModel's provider into a shared builder both paths call.
    private func wireExport() {
        shell.exportQueue = ExportQueue()
        shell.untrackedMagicFrames = { tl, sequences in MagicMatteStore.shared.untrackedFrames(in: tl, sequences: sequences) }
        shell.audioOutputs = { AudioOutputDevices.available().map { AudioOutputChoices.Device(uid: $0.uid, name: $0.name) } }
        applyAudioOutputDevice()
        // The AVFoundation encoder writes every Mac codec and the audio, GIF and image-sequence files (the AppKit sheet's list).
        shell.exportCodecs = [.h264, .hevc, .prores422Proxy, .prores422LT, .prores422, .prores422HQ, .prores4444]
        shell.exportFileOutputs = true
        if let last = UserDefaults.standard.string(forKey: "sq.export.lastDirectory"), FileManager.default.fileExists(atPath: last) {
            shell.exportDirectory = URL(fileURLWithPath: last, isDirectory: true)
        } else if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first { shell.exportDirectory = movies }
        let session = session
        // Stems as `ExportCoordinator.makeModel`: one plan per sequence, the audio is the sequence with the other roles muted.
        shell.configureExport = { [weak self] model in
            let project = session.project
            let presets = self?.inspector.audioPresets ?? [:]
            let timelines = Dictionary(project.timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            model.stemPlans = timelines.mapValues { StemPlan.stems(for: $0) }.filter { !$0.value.isEmpty }
            model.stemPresetStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
                StemPresetStore(url: $0.appendingPathComponent("Sequence Studio/stem-presets.json"))
            }
            let resolver = session.media, ducking = project.liveDucking
            model.stemAudio = { _, stem, range in
                TimelineAudioSource(timeline: stem.timeline, sequences: timelines, range: range, presets: presets,
                                    liveDucking: ducking, resolver: resolver)
            }
            // `ExportCoordinator.makeModel`: the picture in the sheet, the export's compositor, small and silent.
            let ids = project.media.map(\.id), styleKit = project.styleKit, legacy = project.usesLegacyBuiltInFont
            model.previewSource = { id, settings in
                guard timelines[id] != nil, let view = project.variantView(of: id, variant: settings.variant) else { throw ExportSequenceMissing() }
                var all = timelines
                for (k, v) in view.sequences { all[k] = v }
                await resolver.prepare(ids)
                await CaptionLookLibrary.shared.reload()
                return try ExportSourceBuilder.make(timeline: view.timeline, sequences: all, settings: settings, resolver: resolver,
                                                    pixelFormat: .bgra8,
                                                    captionLibrary: CaptionLookRegistry.shared.library(for: styleKit, legacyFont: legacy)).video
            }
        }
        shell.exportFrameImage = { buffer in Self.rgbaImage(bgra: buffer) }
        shell.exportSources = { [weak self] id, settings in
            let (view, all, resolver, ids, styleKit, legacy, ducking, presets, spans) = try await MainActor.run {
                let project = session.project
                guard let view = project.variantView(of: id, variant: settings.variant) else { throw ExportSequenceMissing() }
                var all = Dictionary(project.timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for (k, v) in view.sequences { all[k] = v }
                // The preview render cache: the export reads the segments playback reads (only without a format variant).
                let spans = settings.variant == nil ? (session.renderCache?.exportSpans(for: view.timeline, sequences: all) ?? []) : []
                return (view, all, session.media, project.media.map(\.id), project.styleKit, project.usesLegacyBuiltInFont, project.liveDucking,
                        self?.inspector.audioPresets ?? [:], spans)
            }
            let useProxies = AppSettings.load().useProxiesForExport
            await resolver.prepare(ids)
            await CaptionLookLibrary.shared.reload()
            return try ExportSourceBuilder.make(timeline: view.timeline, sequences: all, settings: settings, resolver: resolver,
                                                presets: presets, liveDucking: ducking,
                                                captionLibrary: CaptionLookRegistry.shared.library(for: styleKit, legacyFont: legacy),
                                                useProxies: useProxies, renderCache: spans)
        }
    }

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireEditAPI()
        if let dir = ProcessInfo.processInfo.environment["SQ_SHARED_UI_SHOT"] { SharedUIShot.run(self, into: URL(fileURLWithPath: dir)); return }
        editAPI.sync()   // shot mode must not bind the port or write the discovery file
        let menu = SharedUIMainMenu(shell: shell, quitTarget: self)
        systemMenu = menu
        NSApp.mainMenu = menu.main
        SQLog.info("shared UI: system menu bar: \(menu.main.items.map(\.title).joined(separator: ", ")), \(menu.main.items.reduce(0) { $0 + ($1.submenu?.items.count ?? 0) }) rows")
        // Same window class, appearance and background as AppController.buildWindow so the system draws the same corners.
        let w = SQEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.appearance = Theme.windowAppearance
        w.backgroundColor = Theme.Colors.titlebar
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentMinSize = NSSize(width: 640, height: 400)
        let v = SharedUIView(controller: self)
        // The engine's layer under the (transparent where the picture is) UI view.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        for (clip, v, e) in [(viewerClip, viewer, engine), (sourceClip, backend.sourceViewer, monitors.source.engine.player)] {
            v.drivesLayer = false
            v.onResize = { [weak e] in e?.redraw() }
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.isHidden = true
            clip.addSubview(v)
            root.addSubview(clip)
        }
        v.frame = root.bounds
        v.autoresizingMask = [.width, .height]
        root.addSubview(v)
        w.contentView = root
        // The Mac editor window (AppController `SequenceStudioMain`): first launch nearly the whole screen.
        w.setFrameAutosaveName("SequenceStudioMain")
        if !w.setFrameUsingName("SequenceStudioMain"), let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            w.setFrame(vf.insetBy(dx: 16, dy: 12), display: false)
        }
        window = w
        view = v
        let start = SharedUIStartWindow(controller: self)
        startWindow = start
        shell.startWindowSize = start.view.bounds.size
        engine.attach(viewer.metalLayer)
        NSApp.activate()
        session.startAutosaveTimer(); session.startRecoveryTimer()
        let path = CommandLine.arguments.dropFirst().first { $0.hasSuffix(".sqproj") }
        if let path {
            shell.spawn { await self.shell.openProject(at: URL(fileURLWithPath: path)) }
        } else {
            shell.presentStartAtLaunch()
            shell.spawn { await self.shell.offerRecovery() }
        }
        // The start window or the editor comes up (never both empty, never an empty editor behind the start window).
        windowsFollowShell()
        if !w.isVisible, !start.isVisible { showEditorWindow() }
        offerCardsAtLaunch()
        SQLog.info("shared UI: window up, \(path.map { "opening \($0)" } ?? "start screen")")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitAllowed { return .terminateNow }
        shell.perform(.quit)
        return .terminateCancel
    }

    /// A clean quit ends the session's crash marker (without it every next launch reported "quit unexpectedly").
    func applicationWillTerminate(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["SQ_SHARED_UI_SHOT"] == nil else { return }
        editAPI.stop()
        shell.dock.floating.flush(force: true)
        session.close()
        SQLog.info("shared UI: clean quit")
        SQLog.shared.flush()
    }

    /// Preferences > Advanced: the switch and status line of the Edit API (the caller syncs it outside shot mode).
    private func wireEditAPI() {
        let api = editAPI
        shell.editAPI = ShellEditAPI(
            isEnabled: { EditAPIController.isEnabled },
            setEnabled: { EditAPIController.isEnabled = $0; api.sync() },
            state: {
                let s = api.state
                let tone: ShellForm.Status.Tone = switch s.tone { case .idle: .idle; case .ok: .ok; case .warning: .warning }
                return ShellEditAPI.State(text: s.text, tone: tone, copyablePort: s.copyablePort)
            })
        api.onState = { [weak self] _ in self?.shell.editAPI?.stateChanged?() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === startWindow?.window { shell.startWindowClosedByUser() } else { shell.perform(.quit) }
        return false
    }

    /// Clicking into the editor while the start window is up over a project closes the start window.
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { shell.editorWindowActivated() }
    }

    func windowDidResize(_ notification: Notification) {
        guard let s = startWindow, (notification.object as? NSWindow) === s.window else { return }
        s.positionLights()
    }

    /// The editor window up and key (AppController `showEditorWindow`).
    func showEditorWindow() {
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        if let view { w.makeFirstResponder(view) }
    }

    /// The start and editor windows follow the shell's start screen (after each frame of either window).
    func windowsFollowShell() {
        startWindow?.sync(shell: shell, editor: window) { showEditorWindow() }
        placeAboutIcon()
        placeDialogMascot()
    }

    /// The About card's app icon (88 pt, `AboutDialog.makeBody`) over the card in whichever window draws the dialog.
    private lazy var aboutIcon: NSImageView = {
        let v = NSImageView(image: NSApp.applicationIconImage)
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setAccessibilityLabel("Sequence Studio app icon")
        return v
    }()

    /// Pip in a dialog's footer (`ShellDialog.mascotFrame`, the Reconnect Media sheet's `SQMascotPlace.mediaOffline`).
    private lazy var dialogMascot: NSView? = SQMascotPlace.mediaOffline.makeView()

    private func placeDialogMascot() {
        let host = overlaysInStartWindow ? startWindow?.view : view
        guard let r = shell.dialog?.mascotFrame, r.width > 0, let pip = dialogMascot, let host, let root = host.superview else {
            if dialogMascot?.superview != nil { dialogMascot?.removeFromSuperview() }
            return
        }
        if pip.superview !== root { pip.removeFromSuperview(); root.addSubview(pip) }
        let f = host.convert(CGRect(x: r.minX, y: r.midY - pip.frame.height / 2, width: pip.frame.width, height: pip.frame.height), to: root)
        if pip.frame != f { pip.frame = f }
    }

    private func placeAboutIcon() {
        let host = overlaysInStartWindow ? startWindow?.view : view
        guard let r = (shell.dialog?.content as? ShellAboutContent)?.iconFrame, !shell.dialog!.menu.isOpen,
              let host, let root = host.superview else {
            if aboutIcon.superview != nil { aboutIcon.removeFromSuperview() }
            return
        }
        if aboutIcon.superview !== root { aboutIcon.removeFromSuperview(); root.addSubview(aboutIcon) }
        let f = host.convert(r, to: root)
        if aboutIcon.frame != f { aboutIcon.frame = f }
    }

    /// The start screen draws over the editor (no start window: the offscreen shot) instead of in its own window.
    private var startOverEditor: Bool { shell.isStartShown && startWindow == nil }
    /// The start window carries the shell's overlays (start screen, its dialogs and menus) while it is up.
    private var overlaysInStartWindow: Bool { shell.isStartShown && startWindow != nil }

    @objc func quitFromMenu(_ sender: Any?) { shell.perform(.quit) }

    // MARK: Frame

    var timeline: Timeline { session.activeTimeline ?? Timeline(name: "", frameDuration: Time(1, 25)) }

    func snapshot() -> EditorSnapshot {
        EditorSnapshot(projectName: session.displayName, timeline: timeline, labels: session.project.labelResolver,
                       selection: session.selection, playhead: session.playhead, isPlaying: !engine.rate.isPaused,
                       status: session.lastError ?? statusMessage)
    }

    /// The theme for `pixelsPerPoint` (the window's backing scale) times Preferences > Interface Size (as on Windows,
    /// AppController+Settings `applySettings`), in the saved Appearance (mode, Background, Contrast: the AppKit
    /// `ThemeAppearance` keys, `sq.appearance.*`).
    private var backingScale: Float = 2
    func setScale(_ scale: Float) {
        backingScale = scale
        atlas.pointScale = scale          // the system font's tracking follows the point size
        let t = DrawTheme(settings: AppearanceSettings(defaults: .standard), scale: scale * Float(InterfaceScale.load()))
        if screen.theme != t { screen.theme = t }
    }

    /// Settings closed or the Interface Size changed: re-read the scale and the meter look.
    func applySettings() {
        applySessionSettings()
        setScale(backingScale)
        meters.meter.meter.style = MeterStyle.current()
        applyAudioOutputDevice()
    }

    /// The remembered editing settings the session itself reads (the Mac `restoreAudioScrubbing` and the end of
    /// `SettingsWindow.changed`): audio scrubbing, selection follows playhead, the edit mode of new sequences. Run at
    /// launch and whenever Preferences closes, so a saved value reaches the engine in this window too.
    func applySessionSettings() {
        let s = AppSettings.load()
        session.engine.audioScrubbing = s.audioScrubbing
        session.setSelectionFollowsPlayhead(s.selectionFollowsPlayhead)
        session.newSequenceEditMode = s.newSequenceEditMode
    }

    /// Settings > Audio Output: both monitors' audio engines play on the chosen device (a missing one falls back to the
    /// system default), as `AppController.applyAudioOutputDevice`.
    func applyAudioOutputDevice() {
        let uid = AppSettings.load().audioOutputUID
        let program = (engine as? PlaybackEngine)?.audio as? AudioEngine
        for e in ([program].compactMap { $0 } + backend.audioEngines) { e.setOutputDevice(uid: uid) }
    }

    /// Moves the shown monitor's layer onto the picture quad and its container onto the quad's clip (view points); hides
    /// both viewers without a quad. The other monitor's viewer stays hidden (one picture quad per frame).
    /// `p` is in canvas points; a floating monitor's quad lies in its window's rectangle, whose root view then holds the viewer.
    func placePicture(_ p: (quad: CGRect, clip: CGRect)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let showsSource = monitors.source.isShown
        for (clip, v, isShown) in [(viewerClip, viewer, !showsSource), (sourceClip, backend.sourceViewer, showsSource)] {
            guard isShown, let p, let main = view else { if !clip.isHidden { clip.isHidden = true }; continue }
            let host = floatingWindow(containing: p.clip)
            let view = host?.0.uiView ?? main
            let o = host?.1 ?? .zero
            guard let root = view.superview else { if !clip.isHidden { clip.isHidden = true }; continue }
            if clip.superview !== root { clip.removeFromSuperview(); root.addSubview(clip, positioned: .below, relativeTo: view) }
            // The UI view is flipped, the root is not: convert both rects, then place the quad inside its clip.
            let c = view.convert(p.clip.offsetBy(dx: -o.x, dy: -o.y), to: root), q = view.convert(p.quad.offsetBy(dx: -o.x, dy: -o.y), to: root)
            if clip.frame != c { clip.frame = c }
            let r = q.offsetBy(dx: -c.minX, dy: -c.minY)
            if v.frame != r { v.frame = r }
            if clip.isHidden { clip.isHidden = false }
        }
        CATransaction.commit()
    }

    /// The pointer shape this frame (SQAppShell `AppPointer` rules) at `x, y` window pixels.
    func pointerShape(x: Float, y: Float) -> AppPointerShape {
        let s = screen.theme.scale, p = CGPoint(x: CGFloat(x / s), y: CGFloat(y / s))
        var f = AppPointer.Facts(divider: shell.dock.divider(at: p)?.axis,
                                 keystoneEdge: timelinePanel.keystoneEdgeHovered(at: x, y: y),
                                 sampling: inspector.isSampling || colorPage.isPicking,
                                 textEditing: monitors.monitor.text.isEditing)
        let tool = timelinePanel.toolState
        f.typeToolOverPicture = !monitors.source.isShown && tool.tool == .type && tool.createMode == .text
            && monitors.monitor.panel.frame.contains(p)
        f.handOverTimeline = tool.tool == .hand && timelinePanel.contains(x: x, y: y)
        f.panel = HostHover.shared.cursor
        return AppPointer.shape(f)
    }

    /// The hosts' pictures for the renderer's image slots: (slot, image, generation).
    func imageSources() -> [(Int, RGBAImage, Int)] {
        let template = captions.templateImage.map { [($0.0, $0.1, $0.2)] } ?? []
        let stills = effects.tileImage.map { [($0.0, $0.1, $0.2)] } ?? []
        let export = shell.exportPreviewImage.map { [$0] } ?? []
        let base = meters.images + [mediaStore.thumbnailImage] + template + stills + export
        let live = libraryFrames.current(library, slotTaken: base.contains { $0.0 == LibraryPreviewFrames.slot }).map { [$0] } ?? []
        return base + live
    }

    /// The hosts' pictures for the renderer's image slots (Scopes), as CGImages remade only when their generation moved.
    func imageSlots() -> [Int: CGImage] {
        var out: [Int: CGImage] = [:]
        // The Text panel's template tiles (slot 4) hold straight alpha around the tile pictures, and so does
        for (slot, img, gen) in imageSources() {
            if let c = imageCache[slot], c.generation == gen { out[slot] = c.image; continue }
            // Mask Tint's coverage (slot 1, also the opaque Slip two-up) too.
            guard let cg = Self.cgImage(img, straightAlpha: slot == TextTemplateTileAtlas.slot || slot == MonitorHost.maskTintSlot)
            else { continue }
            imageCache[slot] = (gen, cg)
            out[slot] = cg
        }
        return out
    }

    /// A BGRA preview frame (`pixelFormat: .bgra8`) as RGBA pixels for an image slot.
    nonisolated static func rgbaImage(bgra buffer: CVPixelBuffer) -> RGBAImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let s = src + y * row
            for x in 0..<w {
                let o = (y * w + x) * 4, i = x * 4
                px[o] = s[i + 2]; px[o + 1] = s[i + 1]; px[o + 2] = s[i]; px[o + 3] = s[i + 3]
            }
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }

    static func cgImage(_ img: RGBAImage, straightAlpha: Bool = false) -> CGImage? {
        guard img.width > 0, img.height > 0, let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: (straightAlpha ? CGImageAlphaInfo.last : .premultipliedLast).rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Lays out and draws the window at `width x height` pixels (the Windows `AppController.frame` for the shared panels).
    func frame(width: Int, height: Int, role: SharedUIView.Role = .editor) -> DrawList {
        switch role {
        case .start: return startFrame(width: width, height: height)
        case .floating(let panel): return floatingFrame(panel, width: width, height: height)
        case .editor: return mainFrame(width: width, height: height)
        }
    }

    /// The whole editor canvas: the window, then the rectangles of the floating panels to its right.
    func editorFrame(width: Int, height: Int) -> DrawList {
        let s = snapshot()
        let scale = screen.theme.scale, k = CGFloat(max(scale, 0.01))
        HostRequests.shared.caret = nil
        screen.slots = layoutDock(width: width, height: height, scale: scale)
        screen.layout(width: Float(width), height: Float(height), s)
        // The monitor card's host draws the picture; the dock's cards and tab strips go under the panels.
        var list = screen.draw(s, atlas: atlas, hasPicture: false) { [shell, atlas, screen] l in
            // The floating rectangles lie right of the window: widen the canvas before anything draws there, so no quad
            // keeps a clip of the window size (the floating picture would be cut away).
            let e = shell.dock.floating.canvasExtent
            if e.width > 0 { l.extendCanvas(width: Float(e.width) * scale, height: Float(e.height) * scale) }
            var c = Canvas(list: l, atlas: atlas, scale: scale)
            shell.dock.draw(&c, theme: screen.theme)
            l = c.list
        }
        timelinePanel.theme = screen.theme
        timelinePanel.isPlaying = s.isPlaying
        timelinePanel.sync(timeline: timeline, selection: session.selection, captions: session.captionSelection,
                           playhead: session.playhead, selectedTransition: session.selectedTransition,
                           labels: session.project.labelResolver, lineKeys: Set(session.selectedLineKeys.map(\.key)))
        toolStrip.theme = screen.theme
        // Render-cache strip above the ruler: follows the frame cache (twice a second, only on change).
        if let spans = cacheStrip.spans(now: ProcessInfo.processInfo.systemUptime, generation: session.engine.cacheGeneration,
                                        duration: session.activeTimeline?.duration, undoName: session.undoName,
                                        fetch: { session.engine.cachedSpans }) { timelinePanel.cachedRanges = spans }
        timelinePanel.syncToggles(session: session)              // the sequence's saved Snapping / Linked Selection
        let content = timelineHeader.layout(screen.timelineView.frame, scale: scale, theme: screen.theme, atlas: atlas,
                                            panel: timelinePanel, toolStrip: &toolStrip)
        for a in toolStrip.tick() { applyToolStrip(a) }
        shell.panels.edgeSelected = timelinePanel.interaction.edgeSelection != nil   // Trim Backward / Forward, Ctrl+T
        shell.panels.hasDeleteTarget = timelinePanel.interaction.hasDeleteTarget          // a selected gap closes on Delete
        timelinePanel.layout(trimHost.layout(content, theme: screen.theme), scale: scale)
        for a in timelinePanel.tick() { applyTimeline(a) }
        timelinePanel.gradeOutline = colorPage.gradeOutline
        timelinePanel.draw(into: &list, atlas: atlas)
        let owns = !overlaysInStartWindow
        if owns {
            shell.measure = TextMeasure(atlas: atlas, scale: scale)
            shell.size = CGSize(width: CGFloat(width) / k, height: CGFloat(height) / k)
        }
        let size = CGSize(width: CGFloat(width) / k, height: CGFloat(height) / k)
        var c = Canvas(list: list, atlas: atlas, scale: scale)
        // The title row replaces EditorScreen's plain top bar ("Sequence Studio", the centered name).
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: shell.menuBar.height - 1), screen.theme.titlebar)
        toolStrip.draw(&c, state: timelinePanel.toolState)
        timelineHeader.draw(&c)
        trimHost.draw(&c)
        colorPage.layout()
        colorPage.refreshStepWindow(panel: monitors.monitor.panel, isEditingText: monitors.monitor.text.isEditing)
        monitors.draw(&c, card: screen.monitor, scale: scale, isPlaying: s.isPlaying, theme: screen.theme)
        let d = shell.dock
        meters.showsScopes = d.shows(.scopes)
        meters.layout(meter: px(d.contentFrame(.audioMeter), k), scopes: px(d.contentFrame(.scopes), k), scale: scale)
        meters.draw(&c, theme: screen.theme)
        inspector.layout(screen.inspector, scale: scale)
        inspector.draw(&c, theme: screen.theme)
        graphics.layout(d.contentFrame(.graphics))
        graphics.draw(&c, theme: screen.theme)
        captions.layout(d.contentFrame(.text))
        captions.draw(&c, theme: screen.theme)
        markerList.layout(d.contentFrame(.markerList))
        markerList.draw(&c, theme: screen.theme)
        keystones.layout(docked: d.contentFrame(.keystones), scale: scale, theme: screen.theme)
        drawLibraryPanels(&c, scale: scale, theme: screen.theme)
        colorPage.draw(&c, theme: screen.theme)
        let pr = screen.project
        projectList.frame = CGRect(x: CGFloat(pr.x) / k, y: CGFloat(pr.y) / k, width: CGFloat(pr.w) / k, height: CGFloat(pr.h) / k)
        projectList.draw(&c, theme: screen.theme)
        drawDockPlaceholders(&c)
        tabOptions.draw(&c, theme: screen.theme)
        keystones.draw(&c, theme: screen.theme)                    // after the cards: its drag ghost crosses the timeline
        monitors.drawDragTile(&c, scale: scale, theme: screen.theme)
        drawLibraryDragLabels(&c, scale: scale, theme: screen.theme)
        timelinePanel.drawCaptionSearch(&c)
        inspector.drawPopover(&c, theme: screen.theme)
        shell.drawBar(&c, theme: screen.theme)
        titleRow.draw(&c, theme: screen.theme)
        StatusBarDraw.draw(&c, statusContent(), in: points(screen.statusBar, k), theme: screen.theme)
        HostHover.shared.drawTooltip(&c, theme: screen.theme, now: ProcessInfo.processInfo.systemUptime)
        HostRequests.shared.drawComposition(&c, theme: screen.theme)
        if owns { shell.drawOverlays(&c, theme: screen.theme) }
        monitors.drawFullScreen(&c, size: size, theme: screen.theme)        // Program Full Screen covers everything
        presentWelcomeOnce()
        var out = c.list
        extendForFloating(&out, scale: scale)
        return out
    }

    /// The start window's frame: the start screen and the dialogs and menus over it, laid out in the start window.
    private func startFrame(width: Int, height: Int) -> DrawList {
        let scale = screen.theme.scale, k = CGFloat(max(scale, 0.01))
        let size = CGSize(width: CGFloat(width) / k, height: CGFloat(height) / k)
        var c = Canvas(width: Float(width), height: Float(height), atlas: atlas, scale: scale)
        c.fill(CGRect(origin: .zero, size: size), screen.theme.canvas)
        guard overlaysInStartWindow else { shell.syncStart(); return c.list }
        shell.measure = TextMeasure(atlas: atlas, scale: scale)
        if shell.startWindowSize != size { shell.startWindowSize = size }
        if shell.size != size { shell.size = size }
        HostHover.shared.drawTooltip(&c, theme: screen.theme, now: ProcessInfo.processInfo.systemUptime)
        HostRequests.shared.drawComposition(&c, theme: screen.theme)
        shell.drawOverlays(&c, theme: screen.theme)
        return c.list
    }

    private func px(_ r: CGRect?, _ k: CGFloat) -> DrawRect {
        guard let r else { return .zero }
        return DrawRect(x: Float(r.minX * k), y: Float(r.minY * k), w: Float(r.width * k), h: Float(r.height * k))
    }

    private func layoutDock(width: Int, height: Int, scale: Float) -> EditorScreen.Slots {
        let d = shell.dock, k = CGFloat(max(scale, 0.01))
        let top = shell.menuBar.height, bottom = CGFloat(DrawTheme.Metrics.statusBar)
        d.measure = TextMeasure(atlas: atlas, scale: scale)
        d.frame = CGRect(x: 0, y: top, width: CGFloat(width) / k, height: max(CGFloat(height) / k - top - bottom, 0))
        d.layout()
        let m = d.workspace.minimumContentSize   // the Mac window floor follows the visible layout (AppController.contentMinSize)
        let floor = NSSize(width: max(m.width, 640), height: max(m.height + bottom + top, 400))
        if window?.contentMinSize != floor { window?.contentMinSize = floor }
        monitors.syncTab(dock: d)
        layoutTitleRow(width: CGFloat(width) / k, barHeight: top)
        colorPage.layoutSwitch(centeredIn: CGFloat(width) / k, barHeight: top, shown: !startOverEditor)
        func px(_ r: CGRect?) -> DrawRect {
            guard let r else { return .zero }
            return DrawRect(x: Float(r.minX * k), y: Float(r.minY * k), w: Float(r.width * k), h: Float(r.height * k))
        }
        return EditorScreen.Slots(monitor: px(colorPage.monitorCard(monitorCard)), inspector: px(d.contentFrame(.effectControls)), project: px(d.contentFrame(.project)),
                                  timeline: px(d.contentFrame(.timeline)))
    }

    // shortcut: one monitor card (one picture quad); when Program and Source sit in separate groups the Source group shows a
    // placeholder, as on Windows. Upgrade when the window renders two pictures.
    private var monitorCard: CGRect? { shell.dock.monitorCard }

    private func drawDockPlaceholders(_ c: inout Canvas) {
        for g in shell.dock.groups {
            let hosted = Self.hostedPanels.contains(g.selected)
                && !((g.selected == .sourceMonitor || g.selected == .programMonitor) && !shell.dock.isMonitorCard(g))
            if !hosted { ShellDock.drawPlaceholder(&c, panel: g.selected, in: g.content, theme: screen.theme) }
        }
    }

    private func presentWelcomeOnce() {
        guard !welcomeChecked, !shell.isStartShown, shell.dialog == nil else { return }
        welcomeChecked = true
        if ProcessInfo.processInfo.environment["SQ_SHARED_UI_SHOT"] != nil { return }
        shell.presentWelcomeIfNeeded()
    }

    // MARK: Input

    /// One window event in pixels: the shell while a menu, dialog or the start screen is up, then the panels, then the
    /// shell's key route (the Windows `AppController.handle` order).
    func handle(_ e: InputEvent, role: SharedUIView.Role = .editor) {
        if role == .start {
            if overlaysInStartWindow { _ = shell.handle(e, scale: screen.theme.scale) }
            return
        }
        if overlaysInStartWindow {
            // A click into the editor over a real project closes the start window; until then the editor stays still.
            if case .mouseDown = e { shell.editorWindowActivated() }
            if shell.isStartShown { return }
        }
        // Panels put their cursor and tip into HostHover while they see the event (the top-most offer wins).
        HostHover.shared.beginEvent(e)
        defer { HostHover.shared.endEvent(e, now: ProcessInfo.processInfo.systemUptime) }
        let scale = screen.theme.scale
        // Program Full Screen: Esc leaves it; keys otherwise route as usual, the mouse has nothing to hit.
        if shell.fullScreenKey(e) { return }
        if shell.isProgramFullScreen { if case .keyDown = e {} else { return } }
        if shell.dialog != nil || shell.menuBar.controller.isOpen || shell.isStartShown { _ = shell.handle(e, scale: scale); return }
        // The caption find and replace card floats over the cards: its presses and, while a field is open, its keys.
        if let actions = timelinePanel.handleCaptionSearch(e) { for a in actions { applyTimeline(a) }; return }
        if case .keyDown = e {} else if shell.handle(e, scale: scale) { return }
        if monitors.routeTextEditing(e, scale: scale) { return }
        if case .mouseDown(let x, let y, _) = e, let p = shell.dock.panel(at: CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale))) {
            shell.dock.focused = p
        }
        monitors.dropFocus(e)
        if inspector.handlePopover(e, scale: scale) { return }
        if colorPage.handle(e, scale: scale) { return }
        if titleRow.handle(e, scale: scale) { return }
        if handleStatusBar(e, scale: scale) { return }
        if projectList.handle(e, scale: scale) { return }
        if tabOptions.handle(e, scale: scale) { return }
        if graphics.handle(e, scale: scale) { return }
        if captions.handle(e, scale: scale) { return }
        if keystones.handle(e, scale: scale) { return }
        if markerList.handle(e, scale: scale) { return }
        if handleLibraryPanels(e, scale: scale) { return }
        if inspector.handle(e, scale: scale) { return }
        if monitors.handle(e, scale: scale) { return }
        if meters.handle(e) { return }
        if trimHost.handle(e) { if case .mouseMoved = e {} else { return } }
        if let took = timelineHeader.handle(e), took { return }
        if let actions = toolStrip.handle(e, state: timelinePanel.toolState) {
            for a in actions { applyToolStrip(a) }
            if case .mouseMoved = e {} else { return }
        }
        let own: Bool
        switch e {
        case .mouseDown(let x, let y, _), .scroll(let x, let y, _, _, _): own = timelinePanel.contains(x: x, y: y)
        case .mouseDragged, .mouseUp: own = timelinePanel.isDragging
        case .mouseMoved: own = true
        case .keyDown(let k, let m):
            // Esc closes Trim mode first (the Mac key monitor, TL-08); not while a drag runs, that Esc cancels the drag.
            if k == .escape, m.isEmpty, shell.trim.isActive, !timelinePanel.isDragging { shell.trim.exit(); return }
            // Delete, Return and the zoom keys belong to the focused panel (a monitor zooms its picture, a list deletes its
            // rows); only the timeline, or nothing focused, takes them here. Tool letters stay global (the Mac key monitor).
            if Self.timelineOwnsKey(k, focus: shell.focus), let actions = timelinePanel.key(k, modifiers: m) {
                for a in actions { applyTimeline(a) }; return
            }
            if shell.handle(e, scale: scale) { return }
            own = false
        }
        if own {
            for a in timelinePanel.handle(e) { applyTimeline(a) }
            if case .mouseMoved = e {} else { return }
        }
        for intent in screen.handle(e, snapshot()) { apply(intent) }
    }

    /// False for the keys that act on the focused panel's selection or zoom when another panel than the timeline has focus.
    nonisolated static func timelineOwnsKey(_ k: InputKey, focus: PanelID?) -> Bool {
        switch k {
        case .delete, .backspace, .enter, .plus, .minus, .character("="), .character("\\"):
            return focus == nil || focus == .timeline
        default: return true
        }
    }

    func keyUp(_ k: InputKey) {
        shell.keyUp(k)                                     // J/K/L hold state (the Mac key router)
        for a in timelinePanel.keyUp(k) { applyTimeline(a) }
    }

    /// The window lost key focus (Cmd-Tab, a click into another window): the key-ups of held J/K/L, tool keys, S and ` go
    /// elsewhere (the Mac `AppController.releaseHeldKeys`).
    func releaseHeldKeys() {
        shell.releaseHeldKeys()
        for a in timelinePanel.releaseHeldKeys() { applyTimeline(a) }
    }

    /// Finder files over the window (`NSDraggingDestination`, view points -> pixels done by the caller): over the timeline
    /// they show the Project drop ghost and land where it showed after the import (the Mac `TimelineView` drop), Cmd
    /// inserts. True when the release was taken by the timeline; false: the caller falls back to `drop(_:)`.
    @discardableResult
    func fileDrag(_ urls: [URL], phase: TimelineDropRoute.Phase, x: Float, y: Float) -> Bool {
        if phase == .canceled { timelinePanel.dropExit(); monitors.filesDragged([], phase: .canceled, x: x, y: y); return false }
        guard !urls.isEmpty, urls.allSatisfy({ !ProjectFile.isProjectURL($0) && ShellImportKind.of($0) == .media }) else { return false }
        if monitors.filesDragged(urls, phase: phase, x: x, y: y) { timelinePanel.dropExit(); return true }   // the Source monitor takes the files
        let context = LibraryDropRoute.Context(presets: [], importAndPlace: { [weak self] urls, a in self?.importAndPlace(urls, at: a) },
                                               status: { [weak self] in self?.status = $0 })
        return LibraryDropRoute.drag(.library(.files(urls)), phase: phase, x: x, y: y,
                                     modifiers: MacKeys.modifiers(flags: NSEvent.modifierFlags.rawValue),
                                     panel: &timelinePanel, session: session, context: context)
    }

    private func importAndPlace(_ urls: [URL], at a: TimelineAction) {
        guard let model = shell.projectModel else { return }
        shell.spawn { [weak self] in
            await model.importFiles(urls)
            guard let self else { return }
            shell.onProjectChanged?()
            let ids = urls.compactMap { model.mediaID(forImported: $0) }
            guard !ids.isEmpty else { status = SQL10n.string("Could not import the dropped files."); return }
            if !TimelineDrop.place(.media(ids), at: a, in: session), let e = session.lastError { status = e }
        }
    }

    func drop(_ urls: [URL]) {
        if let project = urls.first(where: { ProjectOpenRouting.route(for: $0) == .sequenceStudioProject }) {
            shell.spawn { await self.shell.openProject(at: project) }   // a project is opened, never imported as media
            return
        }
        shell.importMixed(urls)
    }

    /// Finder double-click, drop on the Dock icon, "Open With": opens the first project (or Premiere project).
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ProjectOpenRouting.route(for: $0) != .unsupported }) else {
            shell.importMixed(urls); return
        }
        shell.spawn { await self.shell.openProject(at: url) }
    }

    private func applyTimeline(_ a: TimelineAction) {
        if case .contextMenu(let p) = a { showTimelineMenu(at: p); return }
        if let m = TimelineSessionBridge.apply(a, to: session, host: timelineHost) { status = m }
    }

    private func applyToolStrip(_ a: ToolStripAction) {
        switch a {
        case .setTool(let s): timelinePanel.toolState = s
        case .menu(let m, let p):
            let items = toolStrip.items(m, state: timelinePanel.toolState) { [weak self] s in self?.timelinePanel.toolState = s }
            shell.menuBar.controller.present(items: items, at: p, pointer: p)
        }
    }

    private func showTimelineMenu(at p: CGPoint) {
        guard let items = TimelineMenus.items(at: p, panel: &timelinePanel, session: session, host: timelineHost),
              !items.isEmpty else { return }
        let f = timelinePanel.frame, s = timelinePanel.scale
        let w = CGPoint(x: CGFloat(f.x / s) + p.x, y: CGFloat(f.y / s) + p.y)
        shell.menuBar.controller.present(items: items, at: w, pointer: w)
    }

    /// The status bar's relink chip (one click reconnects) and export ring (opens the queue), with their tips.
    private func handleStatusBar(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        let measure = TextMeasure(atlas: atlas, scale: scale)
        switch e {
        case .mouseDown(let x, let y, _):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            switch StatusBarDraw.part(at: p, statusContent(), in: points(screen.statusBar, k), measure: measure) {
            case .relink?: shell.acceptRelinkOffer()
            case .ring?: shell.showExportQueue(at: p)
            case nil: return false
            }
            return true
        case .mouseMoved(let x, let y):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            switch StatusBarDraw.part(at: p, statusContent(), in: points(screen.statusBar, k), measure: measure) {
            case .relink?: HostHover.current.offerTip(SQL10n.string("Files for offline media were found nearby: click to reconnect them (one undo step)"))
            case .ring?: HostHover.current.offerTip(SQL10n.string("Export queue"))
            case nil: break
            }
            return false
        default: return false
        }
    }

    /// The status bar's texts each frame (the AppKit `updateChrome`, `setGrade`, `setPlaybackQuality` and the
    /// Linked Selection chip).
    func statusContent() -> StatusBarContent {
        var s = StatusBarContent()
        if let t = session.activeTimeline {
            let f = t.format
            let vfr = t.tracks.lazy.filter { $0.kind == .video }.flatMap(\.clips)
                .contains { session.project.media($0.media)?.info?.video?.isVariableFrameRate == true }
            s.format = StatusBarContent.format(width: f.width, height: f.height,
                                               fps: Double(f.frameDuration.timescale) / Double(f.frameDuration.value), variableFrameRate: vfr)
        }
        s.save = .make(isDirty: session.isDirty, hasFile: session.fileURL != nil, lastEdit: lastEdit, lastBackup: session.lastAutosave)
        s.message = session.lastError ?? statusMessage
        s.playback = StatusBarContent.playback(monitors.monitor.model.quality)
        s.grade = colorPage.gradeStatus
        s.linkedSelectionOff = !timelinePanel.toolState.linkedSelection
        s.relinkOffer = shell.relinkOffer?.text ?? ""
        // The ring opens the Jobs popover: it shows for exports and for background work (proxies, conform, transcription...).
        s.exportProgress = shell.exportProgress ?? jobCenter.overallProgress
        exportNotifier.update(progress: shell.exportProgress)
        return s
    }

    /// The traffic lights' share of the title row (points).
    static let windowButtonsWidth: CGFloat = 78

    private func layoutTitleRow(width: CGFloat, barHeight: CGFloat) {
        let saved = session.fileURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        titleRow.projectName = session.displayName
        titleRow.edited = session.isDirty ? (lastEdit ?? Date()) : saved
        titleRow.workspaceName = shell.dock.store.current.name
        titleRow.isChooser = startOverEditor
        // Without in-window menu titles (Mac: system menu bar) the row starts after the window buttons.
        titleRow.layout(after: shell.menuBar.titleFrames.last?.maxX ?? Self.windowButtonsWidth, width: width, barHeight: barHeight,
                        measure: TextMeasure(atlas: atlas, scale: screen.theme.scale))
    }

    private func makeTitleRow() -> TitleRowHost {
        let r = TitleRowHost()
        r.menus = shell.menuBar.controller
        r.onExport = { [weak self] in self?.shell.perform(.command(.export)) }
        // Window > Workspaces, freshly built (checked item and enabled state as the menu shows them).
        r.workspaceItems = { [weak self] in
            guard let self else { return [] }
            let menus = shell.menuBar.refresh?() ?? shell.menuBar.menus
            return menus.lazy.flatMap(\.items).first { $0.title == "Workspaces" }?.submenu ?? []
        }
        return r
    }

    private func points(_ r: DrawRect, _ k: CGFloat) -> CGRect {
        CGRect(x: CGFloat(r.x) / k, y: CGFloat(r.y) / k, width: CGFloat(r.w) / k, height: CGFloat(r.h) / k)
    }

    /// The Color page reads the Program composite through the engine's frame capture (the AppKit `FrameSampler`, on the
    /// render loop's command buffer; the pick's loupe magnifies the same read-back), the Sources tiles draw from the
    /// timeline thumbnails.
    private func makeColorPage() -> ColorPageHost {
        let h = ColorPageHost(session: session, menus: shell.menuBar.controller, shell: shell)
        h.controller.beep = { NSSound.beep() }
        // The AppKit Color page has no Before | After | Split strip (the layout is in the tab's "..." menu).
        h.showsViewerHeader = false
        let engine = engine
        h.requestProgramFrame = { width, done in
            guard engine.lastRenderedTexture != nil else { return done(nil) }
            FrameSampler.sampleScaled(engine: engine, width: width ?? Int.max, key: "sharedUI.colorPage") { r in
                done(r.map { ProgramLinearFrame(width: $0.width, height: $0.height, pixels: $0.linear) })
            }
            if engine.rate.isPaused { engine.redraw() }   // paused, nothing renders by itself
        }
        h.media = { [mediaStore] in mediaStore }
        return h
    }

    private func makeTimelineHost() -> TimelineHost {
        let h = TimelineHost()
        h.command = { [weak self] c in _ = self?.shell.execute(c) }
        h.status = { [weak self] m in self?.shell.onStatus?(m) }
        h.panel = { [weak self] change in if let self { change(&timelinePanel) } }
        h.prompt = { [weak self] p in await self?.askPrompt(p) }
        h.open = { [weak self] r in self?.openTimelineEditor(r) ?? false }
        return h
    }

    /// The timeline's editor requests the shared hosts answer (the Windows `openTimelineEditor` for these cases).
    private func openTimelineEditor(_ r: TimelineEditorRequest) -> Bool {
        switch r {
        case .keyLaneKey(let clip, let time, let extend):
            inspector.model.selectKeyLaneKey(clip: clip, at: time, extend: extend)
        case .textClip(let id), .graphicLayers(let id):
            // Controls shows the Text and Graphic sections of the selected clip.
            session.select(clips: [id], captions: [])
        case .speedCurve(let clip, let segment, let p):
            let f = timelinePanel.frame, k = CGFloat(timelinePanel.scale)
            let w = CGPoint(x: CGFloat(f.x) / k + p.x, y: CGFloat(f.y) / k + p.y)
            inspector.openEase(SpeedRampEaseSource(session: session, clip: clip, segment: segment),
                               anchor: CGRect(x: w.x, y: w.y, width: 1, height: 1))
        case .revealInProject(let id):
            guard session.project.media(id) != nil else { return false }
            projectList.reveal(media: id)
        case .captionWord(let ref):
            guard let a = timelinePanel.beginWordEditing(ref) else { return false }
            for x in a { applyTimeline(x) }
        case .trimMode(let p, let before):
            _ = trimHost
            shell.enterTrimMode(p, pointerBefore: before)
        case .marker(let id): return shell.editMarker(id)
        case .clipMarker(let clip, let id): return shell.editMarker(id, clip: clip)
        case .toneClip(let id):
            // The Mac double-click on a tone clip: select it, then Tone Settings.
            session.select(clips: [id], captions: [])
            return shell.execute(.toneSettings)
        default: return editorDialogs.open(r) ?? false
        }
        return true
    }

    private func askPrompt(_ p: TimelinePrompt) async -> String? {
        let d = ShellDialog(p.title, informative: p.message)
        // The Mac prompts (Rename Track, Set Transition Duration, Combine): one unlabeled field over the card's width.
        d.form = ShellForm([.field(id: "text", label: "", value: p.text)])
        d.form?.beginEditing("text")
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        guard await shell.ask(d) == .first, let t = d.form?.text("text") else { return nil }
        let s = t.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (p.placeholder.isEmpty ? nil : p.placeholder) : s
    }

    private func apply(_ intent: EditorIntent) {
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
        case .razor(let at, let track):
            session.commit(TimelineCommit(timeline: timeline, edits: [.addEdit(at: at, tracks: [track])], undoName: "Cut",
                                          selection: session.selection))
        case .delete(let ripple): session.deleteSelection(ripple: ripple)
        case .undo: _ = session.undo()
        case .redo: _ = session.redo()
        case .playPause: session.playPause()
        case .shuttle(let a): session.apply(shuttle: a)
        case .step(let n): session.stepFrames(n)
        case .goToStart: session.goToStart()
        case .goToEnd: session.goToEnd()
        case .monitor(let a): applyMonitor(a)
        case .setMark(let end, let t):
            if end == .markIn { session.setInPoint(at: t) }
            if end == .markOut { session.setOutPoint(at: t - timeline.frameDuration) }
        case .setInOut(let r, let part): session.moveInOut(to: r, part: part)
        }
    }

    private func applyMonitor(_ a: MonitorAction) { monitors.applyMonitor(a) }
}
