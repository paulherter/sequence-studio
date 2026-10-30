import AppKit
import Metal
import Observation
import SQAnalysis
import SQCore
import SQEditorSession
import SQEditorUI
import SQMedia
import SQPlayback
import SQText

/// Application delegate and owner of everything: the `EditorSession`, the window shell, the panels, the menus and the
/// keyboard routing. Commands from the menus, the toolbar, the monitor transport and `KeyRouter` all end up in
/// `execute(_:)` (AppController+Commands.swift) and from there in session calls.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let session: EditorSession
    /// nil when no Metal device: the stub engine runs and nothing is shown in the Program monitor.
    let engineNote: String?
    /// The active key map: the chosen preset plus the user's `sq.keymap` diff. Replaced by `applyKeymap`.
    var commandMap: CommandMap
    var keymapConfig: KeymapConfig
    let keymapStore = KeymapStore()
    /// Command-key bindings that menu items own (see `MenuKeys`).
    lazy var menuOwnedKeys = MenuKeys.owned(commandMap, isVisible: CommandRouting.isSupported)
    var store = WorkspaceStore.load()
    /// Re-applies the remembered monitor resolution (app preference, not stored in the project) after a project opened or was created.
    func applyRememberedQuality() {
        // Programmatic: the engine follows, but this is no user pick (nothing is saved, Auto stays Auto).
        applyingRememberedQuality = true
        defer { applyingRememberedQuality = false }
        panels.monitorModel.setQuality(settings.startQuality(auto: MonitorQuality(memoryBudget.autoPreviewQuality)))
    }
    private var applyingRememberedQuality = false
    /// Program monitor Full Screen (Esc exits); nil while not presenting.
    var presentation: ProgramPresentation?
    /// When the project last changed while unsaved: the top bar's "Edited 2 min ago".
    private var lastDirtyChange: Date?

    var settings: AppSettings { didSet { panels?.applySettings(settings); applyRenderCacheSettings() } }

    /// Settings > Playback > Render Cache: on/off, size cap and folder (the cache folder) reach the controller.
    private func applyRenderCacheSettings() {
        session.renderCache?.configure(enabled: settings.renderCache, directory: settings.locations.renderCacheDirectory,
                                        byteCap: settings.renderCacheCapBytes)
    }
    private(set) lazy var settingsWindow = SettingsWindowController(controller: self)
    var maximizedPanel: PanelID?
    /// Color page: the tab that was selected beside Steps before a Simple to Pro switch brought Steps to the front.
    var tabBeforeSteps: PanelID?
    /// A Simple | Pro switch by the user is being applied (selects the Steps tab; a clip selection does not).
    var userChoseProGrade = false
    /// The workspace picked by hand per project (`WorkspaceChoices`): a project without a pick opens in "Editing – PC".
    var workspaceChoices = WorkspaceChoices(stored: UserDefaults.standard.dictionary(forKey: WorkspaceChoices.defaultsKey))
    /// Path of the saved project a recovered (untitled) session came from: it keeps that project's workspace pick.
    var recoveredProjectPath: String?
    var focusedPanel: PanelID? = .timeline { didSet { router.focus = focusedPanel; shell.host.focusedPanel = focusedPanel } }
    var router: KeyRouter
    var menuShuttle = Shuttle()
    /// Keys whose key down the monitor consumed; their key ups are consumed too.
    private var consumedKeyDowns: Set<Key> = []
    /// Active editor tool (for hold-to-temp reverts) and the hold in progress.
    var currentTool: EditorTool = .selection
    /// `currentTool`, corrected when the tool was changed by a toolbar click instead of a key.
    var activeEditorTool: EditorTool {
        let tl = panels.timelineView.toolState.tool
        switch (currentTool, tl) {
        case (.selection, .selection), (.trackForward, .trackSelectForward), (.trackBackward, .trackSelectForward),
             (.ripple, .rippleEdit), (.rolling, .rollEdit), (.slip, .slip), (.slide, .slide), (.razor, .razor),
             (.hand, .hand), (.rateStretch, .rateStretch), (.zoom, .zoom), (.mask, .mask), (.position, .position): return currentTool
        default: break
        }
        switch tl {
        case .selection: return .selection
        case .trackSelectForward: return .trackForward
        case .rippleEdit: return .ripple
        case .rollEdit: return .rolling
        case .slip: return .slip
        case .slide: return .slide
        case .razor: return .razor
        case .hand: return .hand
        case .type: return panels.timelineView.toolState.createMode.editorTool
        case .rateStretch: return .rateStretch
        case .zoom: return .zoom
        case .mask: return .mask
        case .position: return .position
        @unknown default: return currentTool
        }
    }
    private var toolHold = ToolHold()

    var window: NSWindow!
    var shell = ShellContentView()
    var panels: EditorPanels!
    var toolbar: EditorToolbar!
    let mainWorkspaceSubmenu = NSMenu(title: SQL10n.string("Workspace"))
    let recentMenu = NSMenu(title: SQL10n.string("Open Recent"))
    /// Start window: recents (persisted in `sq.recentProjects`), project templates, the window itself.
    var recentProjects = RecentProjects.load()
    /// Recents whose file is gone (checked off the main thread): shown grayed with "Locate…".
    var missingRecents: Set<String> = []
    /// Frame size, rate and length of each recent (read off the main thread from its project file) for the start cards.
    var recentInfos: [String: StartProjectInfo] = [:]
    var recentPosters: [String: CGImage] = [:]
    let templateStore = TemplateStore()
    var startWindow: StartWindowController?
    /// A Finder open request arrived (maybe before launch finished): the start window stays away.
    var pendingOpenRequest = false
    /// Premiere import in progress (reset by `defer`, so a failed import never blocks the next one).
    var importGate = BusyGate()
    /// The last project import's checklist (File > Import Checklist…), with the Show cursor per row.
    var importChecklistState: ImportChecklistState?
    let autosaveMenu = NSMenu(title: SQL10n.string("Autosave Versions"))
    /// Fast Cut ` hold: true once a click or another key happened while ` was down (then its release does not maximize).
    var keepAttachedUsed = false
    /// Find Scene Changes, Auto Reframe (and the Stabilize messages): SQEditorSession `AnalysisFlows` on the status bar.
    private(set) lazy var analysisFlows = AnalysisFlows(session: session, backend: MacAnalysisBackend(), ui: AnalysisFlowUI(
        setJob: { [weak self] in self?.shell.statusBar.setJob($0) },
        flash: { [weak self] text, seconds in self?.shell.statusBar.flash(text, seconds: seconds) }))
    private(set) lazy var quickApply: QuickApplyPanel = {
        let p = QuickApplyPanel(model: QuickApplyModel(items: []))
        p.onChoose = { [weak self] item, end in self?.applyQuickApply(item, end: end) }
        p.canChooseTransitionEnd = { [weak self] in self?.quickApplySelectedClipsForTransition().isEmpty == false }
        return p
    }()
    private(set) lazy var shortcutsWindow = KeyboardShortcutsWindowController(config: keymapConfig, onChange: { [weak self] in self?.applyKeymap($0) })
    var keyMonitor: Any?
    /// Main window lost key focus: held keys' key ups go elsewhere (`releaseHeldKeys`).
    private var resignKeyObserver: Any?
    /// Set once quitting started (Save alert, then teardown): the key monitor must not touch views any more.
    var isTerminating = false
    var saveWorkspaceWork: DispatchWorkItem?
    /// Panels popped out into their own windows, per workspace (`AppController+FloatingPanels.swift`).
    var floatingState = FloatingPanelState.load()
    var floatingWindows: [PanelID: FloatingPanelWindow] = [:]
    var saveFloatingWork: DispatchWorkItem?
    var deadlineWork: DispatchWorkItem?
    let exports = ExportCoordinator()
    let jobCenter = JobCenter()
    /// Growing-file refresh timer task (`startGrowingFilePoll`).
    var growingFilePoll: Task<Void, Never>?
    let audioEngine: AudioEngine
    private(set) var sourceAudioEngine: AudioEngine?
    var audioWarned = false
    /// The Source monitor's own engine (nil members: stub when there is no Metal device).
    let sourceEngine: any ProgramEngine
    /// Trim mode's two parked engines (TL-08), made on first use; no audio.
    private let mediaResolver: ProjectMediaResolver
    private var trimEngines: (any ProgramEngine, any ProgramEngine)?
    /// One small frame cache shared by the two Trim engines (they show two frames each); emptied when Trim mode closes.
    private var trimCache: FrameCache<DecodedFrame>?
    /// The two engines of the Slip two-up viewer, made on the first Slip drag, and their small frame cache.
    private var slipEngines: (any ProgramEngine, any ProgramEngine)?
    private var slipCache: FrameCache<DecodedFrame>?
    /// Q-PERF2 rec 3: thermal state / Low Power Mode -> monitors and AutoProxy (export ignores it). `SQ_THERMAL` forces a level.
    let power = PowerMonitor()
    /// PERF STREAM (4): caps scaled to this Mac's RAM (`SQ_RAM_GB` simulates a smaller Mac), and the system memory pressure.
    let memoryBudget = MemoryBudget.current()
    let memory = MemoryPressureMonitor()
    /// Frame caches of the two monitors (one Settings budget, split 3:1); kept to resize them from Settings.
    private var monitorCaches: [FrameCache<DecodedFrame>] = []

    override init() {
        LaunchTiming.mark("init start")
        let media = ProjectMediaResolver()
        var engine: any ProgramEngine = StubProgramEngine()
        var srcEngine: any ProgramEngine = StubProgramEngine()
        var note: String?
        var srcAudio: AudioEngine?
        StartupReporter.shared.step("Audio engine")
        let audio = AudioEngine(media: media)
        audioEngine = audio
        StartupReporter.shared.step("Metal device")
        let prefs = AppSettings.load()
        // Before any engine: the matte stores read their folder once, at first use.
        prefs.locations.applyAnalysisAndPreviewRoots()
        let split = MemoryBudget.split(MemoryBudget.current().frameCacheBytes(userGB: prefs.frameCacheGB))
        let caches = [FrameCache<DecodedFrame>(budgetBytes: split.program, pressure: SystemMemoryPressureSource()),
                      FrameCache<DecodedFrame>(budgetBytes: split.source, pressure: SystemMemoryPressureSource())]
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                StartupReporter.shared.step("Shaders and color pipeline")
                let program = try PlaybackEngine(device: device, media: media, cache: caches[0], audio: audio)
                program.prewarmsAudio = true       // first play must not wait for the hardware start (~150 ms on main)
                engine = program
                LaunchTiming.mark("program engine")
                let sourceAudio = AudioEngine(media: media)
                srcAudio = sourceAudio
                srcEngine = try PlaybackEngine(device: device, media: media, cache: caches[1], audio: sourceAudio)
            } catch { note = "Playback engine unavailable: \(error)" }
        } else {
            note = "No Metal device: the Program monitor stays blank."
        }
        StartupReporter.shared.step("Preferences")
        settings = prefs
        // Render mode gets a throwaway autosave root so the session's crash marker never lands in the user's Autosave folder.
        let autosaveBase = RenderPanels.isRequested
            ? FileManager.default.temporaryDirectory.appendingPathComponent("SequenceStudio-render-autosave-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : AutosaveStore.defaultBase
        session = EditorSession(engine: engine, media: media,
                                autosaveStore: AutosaveStore(base: autosaveBase, policy: AutosavePolicy(interval: prefs.autosaveInterval)))
        // Orphaned Magic mattes: files written this session for picks the released (saved) project no longer has go.
        // An unsaved project may be reopened from its file, which still refers to them: keep them.
        // The removals are written down first (`MatteRemovalJournal`): the store deletes the files later on its own
        // queue, and what a session that ended in between left behind goes when the next project opens.
        let removals = MatteRemovalJournal.shared
        session.onReleaseProject = { project, dirty in
            // Frames a stopped run left in memory for a mask the project still has (queued; quit waits for them).
            MagicMatteStore.shared.saveUnsaved(among: project.magicMatteCacheKeys)
            if dirty { MagicMatteStore.shared.forgetWritten() } else { removals.sweep(MagicMatteStore.shared, keeping: project.magicMatteCacheKeys) }
        }
        engineNote = note
        sourceEngine = srcEngine
        mediaResolver = media
        monitorCaches = caches
        StartupReporter.shared.step("Keyboard shortcuts")
        let keymap = KeymapStore().load()
        keymapConfig = keymap
        commandMap = keymap.map
        CommandMap.current = keymap.map
        router = KeyRouter(map: keymap.map, focus: .timeline, clock: { ProcessInfo.processInfo.systemUptime })
        super.init()
        // W9.9: background proxies of heavy long-GOP sources for both monitors (export always reads the originals).
        // Proxy jobs wait while a monitor plays or an export runs (perf: weak Macs).
        sourceAudioEngine = srcAudio
        applyAudioOutputDevice()
        // Settings > Media > Cache: the proxy cache sits in the chosen folder and honors the size cap from launch on.
        session.autoProxy = AutoProxyService.make(resolver: media, engines: [engine, srcEngine],
                                                  directory: prefs.proxyCacheDirectory, isBusy: { [weak self] in
            guard let self else { return false }
            let monitors = [self.session.engine, self.sourceEngine] + [self.trimEngines?.0, self.trimEngines?.1].compactMap { $0 }
            return monitors.contains { $0.rate != .zero } || self.exports.queueModel.hasActiveJobs
        })
        session.autoProxy?.applyCacheCap(bytes: prefs.cacheCapBytes)
        prefs.locations.applyWaveformDirectory()
        // Preview render cache: renders heavy segments in the background when idle, never while a monitor plays, an export
        // runs or the Mac is hot; playback reads them back. Log lines start with "render cache:" (Console / `log stream`).
        let cache = RenderCacheController(
            directory: prefs.locations.renderCacheDirectory, byteCap: prefs.renderCacheCapBytes, media: media,
            inputs: .init(playhead: { [weak self] in self?.session.playhead ?? .zero },
                          isPlaying: { [weak self] in self?.session.isPlaying ?? false },
                          droppedFrames: { [weak self] in self?.session.engine.droppedFrames ?? 0 },
                          isBusy: { [weak self] in self?.exports.queueModel.hasActiveJobs ?? false }))
        session.renderCache = cache
        applyRenderCacheSettings()
        applyPowerPolicy(power.policy, announce: false)
        power.onChange = { [weak self] p in self?.applyPowerPolicy(p, announce: true) }
        memory.onChange = { [weak self] l in self?.memoryPressureChanged(l) }
        session.onChange = { [weak self] c in self?.sessionChanged(c) }
        if !ProcessInfo.processInfo.environment.keys.contains(where: { ($0.hasPrefix("SS_") || $0.hasPrefix("SQ_")) && $0 != "SQ_KEYLOG" }) {
            session.confirmFormatChange = { [weak self] current, proposed in self?.askChangeSequenceFormat(current, proposed) ?? true }
        }
    }

    /// The two engines of the Trim monitor; nil without a Metal device (the view then stays blank).
    private func trimEngineMake() -> (any ProgramEngine, any ProgramEngine)? {
        if let e = trimEngines { return e }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let cache = FrameCache<DecodedFrame>(budgetBytes: 256 << 20)
        guard let a = try? PlaybackEngine(device: device, media: mediaResolver, cache: cache, audio: nil),
              let b = try? PlaybackEngine(device: device, media: mediaResolver, cache: cache, audio: nil) else { return nil }
        let policy = effectivePolicy(power.policy)
        a.powerPolicy = policy; b.powerPolicy = policy
        trimCache = cache
        trimEngines = (a, b)
        session.addAuxiliaryEngine(a); session.addAuxiliaryEngine(b)
        return trimEngines
    }

    /// The two engines of the Slip two-up viewer; nil without a Metal device (no two-up then).
    private func slipEngineMake() -> (any ProgramEngine, any ProgramEngine)? {
        if let e = slipEngines { return e }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let cache = FrameCache<DecodedFrame>(budgetBytes: 256 << 20)
        guard let a = try? PlaybackEngine(device: device, media: mediaResolver, cache: cache, audio: nil),
              let b = try? PlaybackEngine(device: device, media: mediaResolver, cache: cache, audio: nil) else { return nil }
        let policy = effectivePolicy(power.policy)
        a.powerPolicy = policy; b.powerPolicy = policy
        slipCache = cache
        slipEngines = (a, b)
        session.addAuxiliaryEngine(a); session.addAuxiliaryEngine(b)
        return slipEngines
    }

    /// Both monitors and the background proxy queue follow the policy; a change to or from the hot state is noted once in
    /// the status bar (no dialog).
    /// Thermal / Low Power policy combined with memory pressure and the Playback settings (every engine uses this).
    func effectivePolicy(_ thermal: PowerPolicy) -> PowerPolicy {
        PowerPolicy.combined(power: thermal, memory: memory.level, autoQuality: settings.previewQualityAuto,
                             backgroundWork: settings.backgroundWork)
    }

    func applyPowerPolicy(_ thermal: PowerPolicy, announce: Bool) {
        let p = effectivePolicy(thermal)
        let wasHot = session.engine.powerPolicy.decodeScaleCap != .full
        session.engine.powerPolicy = p
        sourceEngine.powerPolicy = p
        trimEngines?.0.powerPolicy = p; trimEngines?.1.powerPolicy = p
        slipEngines?.0.powerPolicy = p; slipEngines?.1.powerPolicy = p
        session.autoProxy?.setHeld(p.pausesBackgroundJobs)
        session.renderCache?.held = p.pausesBackgroundJobs
        let hot = p.decodeScaleCap != .full
        guard announce, hot != wasHot, memory.level == .normal else { return }
        shell.statusBar.flash(hot ? "Mac is running hot: the monitors play at half resolution until it cools down."
                                   : "Mac cooled down: full monitor resolution again.", seconds: 6)
    }

    /// Memory pressure: the frame caches and the compositor pool trim themselves; here the monitors drop to a lower
    /// preview size (Auto quality) and background work pauses, until the system reports normal again. Noted once in the
    /// status bar, no dialog.
    func memoryPressureChanged(_ level: MemoryPressure) {
        SQLog.info("memory pressure: \(level)")
        applyPowerPolicy(power.policy, announce: false)
        let text: String = switch level {
        case .normal: "Memory is free again: playback quality is back to normal."
        case .warning, .critical: settings.previewQualityAuto
            ? "Memory is low: the monitors play at lower resolution and caches were cleared."
            : "Memory is low: caches were cleared."
        }
        shell.statusBar.flash(text, seconds: 6)
    }

    /// The audio engines of both monitors use the Settings output device (a missing one falls back to the system default).
    func applyAudioOutputDevice() {
        for e in [audioEngine, sourceAudioEngine].compactMap({ $0 }) { e.setOutputDevice(uid: settings.audioOutputUID) }
    }

    /// Settings > Media > Cache Size: applied at once (evicts proxies above the cap).
    func applyCacheCap() { session.autoProxy?.applyCacheCap(bytes: settings.cacheCapBytes) }

    /// Settings > Playback changed the cache size, Auto quality or Background Work: applied at once.
    func applyPlaybackMemorySettings() {
        applyCacheSplit()
        applyPowerPolicy(power.policy, announce: false)
    }

    /// Sets the program/source cache budgets. The cache that shrinks goes first, so the two never sum above the budget
    /// (a switch from 3/4 + 1/4 to 1/4 + 3/4 would otherwise pass through 3/4 + 3/4).
    private func applyCacheSplit() {
        guard monitorCaches.count == 2 else { return }
        let split = memoryBudget.split(memoryBudget.frameCacheBytes(userGB: settings.frameCacheGB), playing: playingMonitor)
        let program = monitorCaches[0], source = monitorCaches[1]
        if split.program < program.budgetBytes {
            program.setBudgetBytes(split.program); source.setBudgetBytes(split.source)
        } else {
            source.setBudgetBytes(split.source); program.setBudgetBytes(split.program)
        }
    }

    /// The monitor that played last; on 8 GB Macs its cache gets the 3/4 of the budget (`MemoryBudget.split(_:playing:)`).
    private var playingMonitor: MemoryBudget.Monitor = .program

    /// A monitor started playing: on 8 GB Macs the caches swap shares (the other one is paused).
    func monitorStartedPlaying(_ m: MemoryBudget.Monitor) {
        guard m != playingMonitor else { return }
        playingMonitor = m
        guard memoryBudget.followsPlayingMonitor else { return }
        applyCacheSplit()              // power policy and proxy hold are unchanged by a monitor switch
    }

    // MARK: Launch

    let cardImport = CardImportCoordinator()
    let mediaPlacement = MediaPlacementController()
    let mediaMenu = MediaMenuTarget()
    let pixelAspectMenu = PixelAspectMenuTarget()
    /// Local edit API (Settings > Advanced); off unless `sq.api.enabled`.
    private(set) lazy var editAPI = EditAPIController(session: session) { [weak self] in self?.panels?.timelineView.isDragging == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTiming.mark("didFinishLaunching")
        UIScaleRelayout.install()
        ThemeAppearance.shared.applyAtLaunch()   // Dark / Light from the Appearance setting before the first window
        let startup = StartupReporter.shared
        defer { startup.finish() }   // also on every early return, so the splash can never block
        startup.step("Editor panels")
        SQLog.info("launch Sequence Studio \(AppVersion.display) (\(AppVersion.build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let line = WorkPools.debugLine(for: WorkLimits.current.pools) { SQLog.info(line) }   // defaults write sq.debug.workPools -bool YES
        DefaultsMigration.migrateLegacyKeys()   // `ss.*` keys of older builds -> `sq.*`
        SQContextMenu.installGlobalRouting()
        SQTextFieldMenu.installGlobalRouting()
        InterFont.register()
        NSApp.setActivationPolicy(RenderPanels.isRequested ? .prohibited : .regular)
        NSApp.appearance = Theme.windowAppearance
        panels = EditorPanels(session: session, sourceEngine: sourceEngine)
        panels.makeTrimEngines = { [weak self] in self?.trimEngineMake() }
        panels.releaseTrimCache = { [weak self] in self?.trimCache?.removeAll() }
        panels.makeSlipEngines = { [weak self] in self?.slipEngineMake() }
        panels.releaseSlipCache = { [weak self] in self?.slipCache?.removeAll() }
        LaunchTiming.mark("panels")
        panels.libraryModel.onImportMotionGraphicsTemplates = { [weak self] urls in    // .mogrt dropped on the Library
            guard let self else { return }
            Task { await self.importMotionGraphicsTemplates(at: urls) }
        }
        panels.libraryModel.onImportWorkspaces = { [weak self] list in     // layouts from a .sqpack
            guard let self else { return }
            for w in list { self.store.library.saveAs(self.store.library.suggestedNewName(base: w.name), from: w) }
            self.scheduleWorkspaceSave()
            self.fillWorkspaceMenu(self.mainWorkspaceSubmenu)
            self.fillToolbarWorkspaceMenu()
        }
        panels.onShowSource = { [weak self] in self?.showPanel(.sourceMonitor) }
        panels.onSourceStartedPlaying = { [weak self] in self?.monitorStartedPlaying(.source) }
        panels.onShowGraphics = { [weak self] in self?.showPanel(.graphics) }
        // Color page: the Steps tab is available with a Pro grade; only the Simple | Pro control brings it to the front.
        panels.colorView.onUserChoseProGrade = { [weak self] in
            self?.userChoseProGrade = true
            DispatchQueue.main.async { self?.userChoseProGrade = false }
        }
        panels.colorView.onProShownChange = { [weak self] pro in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.page == .color {
                    if pro {
                        let user = self.userChoseProGrade
                        self.mutateWorkspace { w in
                            let before = w.selectedTab(inGroupOf: .steps)
                            if user {
                                if before != .steps { self.tabBeforeSteps = before }
                                w.show(.steps)
                            } else { w.reveal(.steps) }
                        }
                    } else if self.store.current.selectedTab(inGroupOf: .steps) == .steps, let back = self.tabBeforeSteps {
                        self.mutateWorkspace { $0.selectTab(back) }
                    } else { self.applyWorkspace() }
                } else { self.updateGradeStatus() }
            }
        }
        // Controls > Color Graph > Adjust: the Color page, where the graph is the Pro page.
        panels.effectModel.onOpenColorPro = { [weak self] in
            guard let self else { return }
            if self.store.page != .color { self.store.setPage(.color); self.scheduleWorkspaceSave() }
            self.focusedPanel = .colorInspector
        }
        panels.onFocus = { [weak self] p in self?.focusedPanel = p }
        startup.step("Effect presets")
        panels.clipSections.onAudioPresetChange = { [audioEngine] id, p in audioEngine.feeder.setPreset(track: id, preset: p) }
        exports.audioPresets = { [weak self] in self?.panels?.clipSections.audioPresets ?? [:] }   // export mixes like playback
        exports.prepareDialogueSilences = { [weak self] t, p in await self?.panels?.waveforms.prepareDialogue(of: t, project: p) }
        exports.otherFormats = [EditorCommand.exportFrame, .exportMarkersCSV, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO].map { c in
            (SQL10n.string(c.title), { [weak self] in self?.execute(c) })
        }
        panels.onStatus = { [weak self] m in self?.shell.statusBar.flash(m) }
        panels.onLinkedSelectionChange = { [weak self] linked in self?.shell.statusBar.setLinkedSelectionOff(!linked) }
        shell.statusBar.setLinkedSelectionOff(!panels.timelineView.toolState.linkedSelection)   // remembered per Mac
        panels.onCommand = { [weak self] c in self?.execute(c) }
        panels.onNest = { [weak self] in self?.requestNest() }
        panels.onCreateAnglesClip = { [weak self] in self?.requestAnglesClip(media: nil) }
        panels.onCreateAnglesClipFromMedia = { [weak self] ids in self?.requestAnglesClip(media: ids) }
        wireFillReel()
        wireCaptions()
        wireStabilizeEffect()
        restoreAudioScrubbing()
        panels.onFrameSize = { [weak self] in self?.session.setToFrameSize() }
        exports.notice = { [weak self] in self?.shell.statusBar.flash($0, seconds: 4) }
        panels.onFillFrame = { [weak self] in self?.session.setToFillFrame() }
        panels.monitorModel.setAutoBase(MonitorQuality(memoryBudget.autoPreviewQuality))
        panels.source.model.setAutoBase(MonitorQuality(memoryBudget.autoPreviewQuality))
        panels.monitorModel.setQuality(settings.startQuality(auto: MonitorQuality(memoryBudget.autoPreviewQuality)))
        let engineQuality = panels.monitorModel.onQualityChange
        panels.monitorModel.onQualityChange = { [weak self] q in   // the choice is an app preference, remembered across projects
            engineQuality?(q)
            self?.shell.statusBar.setPlaybackQuality(q.title)
            // A hand pick in the monitor fixes the quality (Settings shows it); a programmatic apply saves nothing.
            guard let self, !applyingRememberedQuality else { return }
            if panels.monitorModel.quality == .auto {    // Auto in the monitor is the app's Auto (also its governor steps)
                guard !settings.previewQualityAuto else { return }
                settings.previewQualityAuto = true
                settings.save()
                applyPowerPolicy(power.policy, announce: false)
                return
            }
            let s = settings.choosingFixedQuality(q)
            guard s != settings else { return }
            settings = s
            settings.save()
            applyPowerPolicy(power.policy, announce: false)   // memory pressure no longer lowers a fixed quality
        }
        panels.applySequenceQuality = { [weak self] q in
            guard let self else { return }
            if let q { applyingRememberedQuality = true; defer { applyingRememberedQuality = false }; panels.monitorModel.setQuality(q) }
            else { applyRememberedQuality() }
        }
        panels.monitorModel.onPreviewRateChange = { [weak self] r in self?.session.setPreviewRate(r) }
        panels.monitorModel.onFullScreen = { [weak self] in self?.enterProgramPresentation() }
        panels.monitorModel.onShowScopes = { [weak self] in self?.showPanel(.scopes) }
        panels.applySettings(settings)
        shell.statusBar.setPlaybackQuality(panels.monitorModel.quality.title)

        shell.statusBar.onTasksClicked = { [weak self] v in self?.toggleTasks(v) }
        exports.queueModel.start()
        watchExports()
        watchKeyLaneSection()
        toolbar = EditorToolbar(controller: self)
        fillWorkspaceMenu(mainWorkspaceSubmenu)
        NSApp.mainMenu = MenuBuilder.build(target: self, map: commandMap)
        startup.step("Main window")
        buildWindow()
        LaunchTiming.mark("window built")
        exports.attach(session: session, window: window)   // Quick Export (menu + shortcut) needs the context before any dialog opened
        startup.step("Workspace")
        applyWorkspace()
        if !RenderPanels.isRequested { editAPI.sync() }   // render mode must not bind the port or write the discovery file
        installKeyMonitor()
        sessionChanged([.project, .selection, .playhead, .transport])
        if let engineNote { shell.statusBar.flash(engineNote, seconds: 12) }

        // The render harness never shows a window. A plain launch shows the start window (its own window) instead; the
        // editor comes up with the first project.
        if !RenderPanels.isRequested, Self.launchNeedsSequence(ProcessInfo.processInfo.environment) { SplashHandoff.present(window) }
        if !RenderPanels.isRequested { NSApp.activate(ignoringOtherApps: true) }
        startup.finish()   // startup done: the splash fades out, then the main window fades in (SplashHandoff)
        LaunchTiming.mark("orderFront")
        if !RenderPanels.isRequested { session.startAutosaveTimer(); session.startRecoveryTimer() }   // render mode never autosaves
        installMediaManagement()
        installPremierePresetImport()
        cardImport.importFiles = { [weak self] urls in await self?.panels.projectModel.importFiles(urls) }
        cardImport.watchPause = { [weak self] on in self?.mediaPlacement.setPaused(on) }
        cardImport.projectFolder = { [weak self] in
            guard let self else { return nil }
            if self.session.fileURL == nil { guard await self.saveDocumentAs() else { return nil } }
            return self.session.fileURL?.deletingLastPathComponent()
        }
        cardImport.start()
        launchDocument()
        SnapshotDriver.runIfRequested(self)
        RenderPanels.runIfRequested(self)
        PlayTestDriver.runIfRequested(self)
        PlayTestDriver.runKeyTestIfRequested(self)
        MaskTestDriver.runIfRequested(self)
        // The subject model loads once in the background a moment after launch (~1 s, ~55 MB), so the first Magic
        // pick finds it ready instead of waiting in "Preparing". Not in render mode; memory pressure still releases it.
        if !RenderPanels.isRequested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { SubjectMaskEngine.shared.prewarm() }
        }
        DevAidDrivers.runIfRequested(self)
        PlayProbeDriver.installQuitReport()
        PlayProbeDriver.runIfRequested(self)
        LaunchTiming.mark("didFinishLaunching end")
        LaunchTiming.finishOnFirstWindowUpdate()
    }

    private func buildWindow() {
        let w = SQEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 960),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 640, height: 400)   // refined per workspace in `applyWorkspace`
        w.appearance = Theme.windowAppearance
        w.backgroundColor = Theme.Colors.titlebar
        // V1 Quiet: no NSToolbar; our own top bar sits under the transparent, hidden title bar (traffic lights stay).
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        shell.topBar = toolbar.bar
        w.delegate = self
        w.contentView = shell
        shell.host.panelView = { [weak self] p in self?.panels.view(for: p) ?? NSView() }
        shell.host.tabMenu = { [weak self] p in self?.tabContextItems(for: p) ?? [] }
        shell.host.headerItems = { [weak self] p in self?.panels.headerItems(for: p) ?? PanelHeaderItems() }
        shell.host.headerView = { [weak self] p, group in self?.panels.headerView(for: p, panels: group) }
        panels.onHeaderDetailChange = { [weak self] p, text in self?.shell.host.setHeaderDetail(text, for: p) }
        shell.host.focusedPanel = focusedPanel
        shell.host.onSelectTab = { [weak self] p in
            self?.mutateWorkspace { $0.selectTab(p) }
            self?.focusedPanel = p
        }
        shell.host.onDock = { [weak self] panel, anchor, zone in
            self?.maximizedPanel = nil
            self?.mutateWorkspace { $0.dock(panel, onto: anchor, zone: zone) }
            self?.focusedPanel = panel
        }
        shell.host.onTearOff = { [weak self] panel, point in self?.floatPanel(panel, at: point) }
        shell.host.onMoveTab = { [weak self] panel, index in
            self?.mutateWorkspace { $0.moveTab(panel, toIndex: index) }
        }
        shell.host.onFractions = { [weak self] path, fractions in
            guard let self else { return }
            var ws = store.current
            if ws.setFractions(at: path, fractions) { store.updateCurrent(ws); scheduleWorkspaceSave() }
        }
        w.setFrameAutosaveName("SequenceStudioMain")
        // First launch: nearly the whole screen (the editor is the big window; the start screen has its own).
        if !w.setFrameUsingName("SequenceStudioMain"), let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            w.setFrame(vf.insetBy(dx: 16, dy: 12), display: false)
        }
        window = w
    }

    /// Dev launches that need the placeholder sequence (project, demo, import, bench); other `SQ_*` aids (SQ_LOG, ...) keep the chooser.
    private static func launchNeedsSequence(_ env: [String: String]) -> Bool {
        let devAids: Set<String> = ["SQ_OPEN", "SQ_DEMO", "SQ_IMPORT", "SQ_PLAYTEST", "SQ_MASKTEST", "SQ_KEYTEST", "SQ_TEXTTEST",
                                    "SQ_TRANSCRIBE_TEST", "SQ_SNAPSHOT", "SQ_DUMPMENU", "SQ_PLAY_PROBE_SCRIPT"]
        return env.keys.contains { devAids.contains($0) || $0.hasPrefix("SQ_BENCH") }
    }

    /// `SQ_OPEN=<path.sqproj>` opens a project; `SQ_NO_RECOVERY=1` skips the recovery prompt; `SQ_DEMO=1` fills the untitled project with sample clips (screenshots).
    private func launchDocument() {
        if RenderPanels.isRequested { return }   // render mode never scans Autosave or shows recovery/start window
        autoPickWorkspace()                      // a workspace name left by an earlier session never shows at launch
        let env = ProcessInfo.processInfo.environment
        // Plain launch: no sequence exists until the chooser's project is created or opened (dev aids keep the placeholder).
        if !Self.launchNeedsSequence(env), session.isEmptyUntitled { session.newProject(EditorSession.makeEmpty()) }
        if let path = env["SQ_OPEN"] {
            Task { await openProject(at: URL(fileURLWithPath: path)) }
        } else if env["SQ_DEMO"] == "1" {
            session.newProject(DemoProject.make())
            sweepLeftoverMattes()
            session.seek(to: DemoProject.playhead)
            session.select(clips: DemoProject.selection(in: session))
        } else if env["SQ_NO_RECOVERY"] != "1", env["SQ_IMPORT"] == nil, settings.offerRecovery {
            // The crash scan reads the Autosave folder: off the main thread, so the window shows at once. The start
            // window waits for its result (a recovery sheet replaces it).
            Task {
                await offerRecovery()
                LaunchTiming.note("recovery scan done (background)")
                showStartWindowIfPlainLaunch()
            }
            return
        }
        showStartWindowIfPlainLaunch()
        if let list = env["SQ_IMPORT"] { importAtLaunch(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
    }

    /// Plain launch (no SQ_* dev aid, no recovery sheet, no Finder open, nothing opened meanwhile): the start window.
    private func showStartWindowIfPlainLaunch() {
        let env = ProcessInfo.processInfo.environment
        if !Self.launchNeedsSequence(env), window.sqAttachedSheet == nil, startWindow?.window.sqAttachedSheet == nil, !pendingOpenRequest, session.isEmptyUntitled {
            if let last = recentProjects.launchReopenTarget(enabled: Self.reopenLastOnLaunch, exists: { FileManager.default.fileExists(atPath: $0) }) {
                Task { await openProject(at: last.url) }
            } else { showStartWindow() }
        }
    }

    /// `SQ_IMPORT=<path>[:<path>…]`: imports like Cmd+I, then places the first file at 0 like a Project-panel drop. Stays open.
    private func importAtLaunch(_ urls: [URL]) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            await panels.projectModel.importFiles(urls)
            guard let first = urls.first, let m = panels.projectModel.mediaID(forImported: first).flatMap({ session.project.media($0) }) else {
                NSLog("SQ_IMPORT: nothing imported, failures=\(panels.projectModel.importFailures)"); return
            }
            session.placeMedia([m.id], at: .zero, mode: .overwrite)
            session.select(clips: [])
            if let v = m.info?.video, let f = session.activeTimeline?.format {
                NSLog("SQ_IMPORT: \(m.name) native \(v.width)x\(v.height) rotation \(v.rotation) still \(m.info?.isStill == true) "
                      + "-> display \(v.displayWidth)x\(v.displayHeight), sequence \(f.width)x\(f.height), scale \(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.media == m.id }?.animation.scale.value.x ?? -1)")
            }
        }
    }

    /// Never on its own: closing the last editor window returns to the start window, and the start window's red
    /// button quits explicitly. AppKit's automatic check also fired at launch while no window was visible yet.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click with no window up: the editor when a project is open, else the start window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, !RenderPanels.isRequested else { return true }
        if hasRealProject { showEditorWindow() } else { showStartWindow() }
        return false
    }

    /// Preview Speed goes back to 1x in both monitors when a project closes.
    func resetPreviewSpeed() {
        panels.monitorModel.setPreviewRate(.normal)
        panels.source.model.setPreviewRate(.normal)
    }

    /// Closing the editor window closes the project (asks to save first) and returns to the start window; it never quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, !RenderPanels.isRequested else { return true }
        guard window.sqAttachedSheet == nil else { return false }
        Task {
            guard await confirmDiscardChanges() else { return }
            if hasRealProject {
                MaskTrackActivity.shared.stop(owner: session, reason: "its project closes")
                session.closeProject()
                resetPreviewSpeed()
            }
            showStartWindow()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.isDirty else { removeKeyMonitor(); return .terminateNow }
        // The Save alert runs a modal loop: the monitor stays installed but `handle` bails out while it is up.
        isTerminating = true
        let choice = SaveChangesPrompt.choice(SaveChangesPrompt.makeDialog(documentName: session.displayName, hasFile: session.fileURL != nil).runModal())
        switch choice {
        case .save:
            Task {
                // A failed save (error dialog shown) or a canceled place picker keeps the app open and the project dirty.
                let go = SaveChangesPrompt.outcome(.save, saveSucceeded: await saveDocument()) == .proceed
                if go { removeKeyMonitor() } else { isTerminating = false }
                NSApp.reply(toApplicationShouldTerminate: go)
            }
            return .terminateLater
        case .dontSave: removeKeyMonitor(); return .terminateNow
        case .cancel: isTerminating = false; return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeKeyMonitor()
        mediaPlacement.cancelCopies()
        if RenderPanels.isRequested { return }   // render mode must not touch the user's data (discovery file, autosave, settings)
        editAPI.stop()   // render mode must not touch the user's data
        session.close()
        try? store.save()
        // Matte saves queued off the main thread (a stopped Magic track, a mask that came back) reach their files.
        MagicMatteStore.shared.waitForSaves()
        // ... and the removals among them are struck out of the journal, so a clean quit leaves no list behind.
        MatteRemovalJournal.shared.waitForSettle()
    }

    // MARK: Session to UI

    /// Status bar, Color page only: "Simple grade active", "No Simple grade", "Pro grade active, 4 steps", "No Pro grade".
    func updateGradeStatus() {
        guard let panels, shell != nil else { return }
        shell.statusBar.setGrade(store.page == .color ? panels.colorView.gradeStatus : "")
    }

    func sessionChanged(_ change: EditorSession.Change) {
        panels?.sync(change)
        guard window != nil else { return }
        // After the Color panel has followed the change (a new pick, a graph started or removed).
        if store.page == .color { DispatchQueue.main.async { [weak self] in self?.updateGradeStatus() } }
        if change.contains(.project) { mediaPlacement.sessionChanged() }
        if change.contains(.transport) {
            if session.isPlaying {
                monitorStartedPlaying(.program)
                if session.engine.audioUnavailable, !audioWarned {
                    audioWarned = true
                    shell.statusBar.flash("Audio output unavailable: playing without sound.", seconds: 6)
                }
            } else {
                audioWarned = false
                router.transportStopped()      // stopped by a click or the button: the next L starts at 1x
            }
        }
        if change.contains(.project), session.isDirty { lastDirtyChange = Date() }
        if change.contains(.project) || change.contains(.status) { updateChrome() }
        if change.contains(.project) { rerunStaleStabilizers(); mediaPlacement.projectChanged() }
    }

    private func updateChrome() {
        window.title = session.displayName
        window.representedURL = session.fileURL
        window.isDocumentEdited = session.isDirty
        let saved = session.fileURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        toolbar?.bar.setEdited(session.isDirty ? (lastDirtyChange ?? Date()) : saved)
        shell.statusBar.setSaveStatus(.make(isDirty: session.isDirty, hasFile: session.fileURL != nil,
                                            lastEdit: lastDirtyChange, lastBackup: session.lastAutosave))
        if let t = session.activeTimeline {
            let f = t.format
            let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
            // The sequence rate is fixed; say so when its source clip is variable frame rate.
            let vfr = t.tracks.lazy.filter { $0.kind == .video }.flatMap(\.clips)
                .contains { session.project.media($0.media)?.info?.video?.isVariableFrameRate == true }
            shell.statusBar.setSequence(width: f.width, height: f.height, fps: fps, variableFrameRate: vfr, edited: session.isDirty)
        }
        if let e = session.lastError { shell.statusBar.flash(e); session.clearError() }
    }

    // MARK: Workspaces

    func applyWorkspace() {
        var w = store.current
        w.maximized = maximizedPanel
        // Floating panels are shown, not stored, as hidden: docking one back restores its exact dock position.
        for p in floatingPanels { w.hide(p) }
        panels.setColorPage(store.page == .color)
        let onColor = store.page == .color
        if onColor, !panels.colorView.proShown { w.hide(.steps) }      // shown, not stored: Steps is the Pro grade's graph
        panels.colorView.stepsShown = onColor && w.showsTab(.steps)
        panels.colorView.sourcesShown = onColor && w.showsTab(.colorClips)
        panels.colorView.stripVisible = onColor && w.isVisible(.timeline)      // no Timeline, no color solo
        shell.host.apply(w)
        syncFloatingWindows()
        updateGradeStatus()
        toolbar.sync(store: store)
        fillWorkspaceMenu(mainWorkspaceSubmenu)
        fillToolbarWorkspaceMenu()
        // The window never gets smaller than the layout's panels need.
        let m = w.minimumContentSize
        window?.contentMinSize = NSSize(width: max(CGFloat(m.width), 640),
                                        height: max(CGFloat(m.height) + ShellMetrics.statusBar + TopBarView.height, 400))
        if focusedPanel == .timeline { window?.makeFirstResponder(panels.timelineView) }
    }

    func mutateWorkspace(_ body: (inout Workspace) -> Void) {
        var w = store.current
        body(&w)
        store.updateCurrent(w)
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    func scheduleWorkspaceSave() {
        if RenderPanels.isRequested { return }   // the demo store must never overwrite the user's workspaces
        saveWorkspaceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { try? self?.store.save() } }
        saveWorkspaceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Pull-down of the toolbar: the popup only carries the button title (the current workspace); its rows are SQ rows built on open.
    func fillToolbarWorkspaceMenu() {
        let popup = toolbar.bar.workspacePopup
        popup.removeAllItems()
        popup.addItem(withTitle: store.editName)
        popup.sqItems = { [weak self] in self?.workspaceItems() ?? [] }
    }

    /// Same list as the Window > Workspace menu (`fillWorkspaceMenu`), as SQ rows.
    func workspaceItems() -> [SQMenuItem] {
        var items = store.library.all.map { w in
            SQMenuItem(title: w.name, isChecked: w.name == store.editName) { [weak self] in self?.chooseWorkspace(named: w.name) }
        }
        items.append(.separator)
        items.append(SQMenuItem(title: "Save as New Workspace\u{2026}") { [weak self] in self?.saveLayoutAs(nil) })
        items.append(SQMenuItem(title: "Rename Workspace\u{2026}", isEnabled: store.canRenameOrDeleteCurrent) { [weak self] in self?.renameWorkspace(nil) })
        items.append(SQMenuItem(title: "Delete Workspace", isEnabled: store.canRenameOrDeleteCurrent) { [weak self] in self?.deleteWorkspace(nil) })
        items.append(SQMenuItem(title: "Reset to Saved Layout", shortcut: "\u{2325}\u{21E7}0", isEnabled: store.canResetCurrent) { [weak self] in self?.resetLayout(nil) })
        items.append(SQMenuItem(title: "Reset All Workspaces") { [weak self] in self?.resetAllWorkspaces(nil) })
        return items
    }

    func fillWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for w in store.library.all {
            let i = NSMenuItem(title: w.name, action: #selector(selectWorkspace(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = w.name
            i.state = w.name == store.editName ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        for (title, sel) in [("Save as New Workspace…", #selector(saveLayoutAs(_:))),
                             ("Rename Workspace…", #selector(renameWorkspace(_:))),
                             ("Delete Workspace", #selector(deleteWorkspace(_:))),
                             ("Reset to Saved Layout", #selector(resetLayout(_:))),
                             ("Reset All Workspaces", #selector(resetAllWorkspaces(_:)))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            if sel == #selector(resetLayout(_:)) { i.keyEquivalent = "0"; i.keyEquivalentModifierMask = [.option, .shift] }
            i.target = self
            menu.addItem(i)
        }
    }

    @objc func selectWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        chooseWorkspace(named: name)
    }

    func chooseWorkspace(named name: String) {
        guard store.selectEdit(name) else { return }
        noteWorkspaceChoice()
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    @objc func saveLayoutAs(_ sender: Any?) {
        let alert = SQDialog()
        alert.messageText = "Save as New Workspace"
        alert.informativeText = "Saves the Edit and the Color layout together under one name."
        let field = SQDialog.makeField(store.library.suggestedNewName(base: "My Layout"))
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .first else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { self.shell.statusBar.flash("That workspace name is not available."); return }
                // An existing name gets a numbered copy instead of being overwritten silently.
                self.store.saveCurrentAsNew(base: name)
                self.noteWorkspaceChoice()
                self.scheduleWorkspaceSave()
                self.applyWorkspace()
            }
        }
    }

    @objc func renameWorkspace(_ sender: Any?) {
        guard store.canRenameOrDeleteCurrent else { return }
        let alert = SQDialog()
        alert.messageText = "Rename Workspace"
        let field = SQDialog.makeField(store.editName)
        alert.accessoryView = field
        alert.addButton("Rename")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .first else { return }
                if self.store.renameCurrent(to: field.stringValue) {
                    self.scheduleWorkspaceSave()
                    self.applyWorkspace()
                } else {
                    self.shell.statusBar.flash("That workspace name is not available.")
                }
            }
        }
    }

    @objc func deleteWorkspace(_ sender: Any?) {
        guard store.canRenameOrDeleteCurrent else { return }
        let alert = SQDialog()
        alert.messageText = SQL10n.format("Delete workspace “%@”?", store.editName)
        alert.informativeText = "The Editing layout is shown afterwards."
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel", role: .cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .first, self.store.deleteCurrent() else { return }
                self.maximizedPanel = nil
                self.scheduleWorkspaceSave()
                self.applyWorkspace()
            }
        }
    }

    /// Every built-in (and the Color page) back at its shipped layout; user workspaces stay.
    @objc func resetAllWorkspaces(_ sender: Any?) {
        store.library.resetAllBuiltIns()
        store.resetAllColor()
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    @objc func resetLayout(_ sender: Any?) {
        // Each page resets its own half of the pair (the Color page to the automatic layout of this workspace).
        guard store.page == .edit else {
            store.resetCurrentColor(); maximizedPanel = nil; scheduleWorkspaceSave(); applyWorkspace()
            return
        }
        guard store.library.resetBuiltIn(store.editName) else { return }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    // MARK: Toolbar actions

    @objc func toolbarImport(_ sender: Any?) { execute(.importMedia) }
    @objc func toolbarExport(_ sender: Any?) { execute(.export) }

    @objc func toolbarPage(_ sender: SQSegmented) {
        store.setPage(sender.selectedSegment == 1 ? .color : .edit)
        if store.page == .color {
            var c = store.colorPage
            c.selectTab(.colorInspector)
            if c != store.colorPage { store.colorPage = c }      // no override stored for a page switch alone
        }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    /// Keeps the status-bar ring in step with the export queue.
    func watchExports() {
        let m = exports.queueModel
        if exports.jobCenter == nil { setUpJobCenter() }
        let center = jobCenter
        // Exports drive the ring as before; other background jobs (proxies, transcription) show when no export runs.
        let progress: Double? = m.hasActiveJobs ? m.overallProgress : center.otherJobs.isEmpty ? nil : center.overallProgress
        shell.statusBar.setTasks(progress: progress)
        withObservationTracking {
            _ = m.jobs
            _ = center.jobs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchExports() }
        }
    }

    /// Background tasks (proxies, transcription; exports are listed by their own queue) for the tasks popover.
    private func setUpJobCenter() {
        exports.jobCenter = jobCenter
        exports.revealJobIndicator = { [weak self] in self?.shell.statusBar.revealedRing() }
        if let q = session.autoProxy?.queue { jobCenter.register(ProxyJobSource(queue: q)) }
        jobCenter.register(TranscriptionJobSource(model: { [weak self] in self?.panels.textView.captionsModel }))
        jobCenter.register(ExportJobSource(model: exports.queueModel))
        jobCenter.register(MaskTrackJobSource { MaskTrackActivity.shared.stop(reason: "canceled in Background Jobs", keeps: true) })
        jobCenter.register(StabilizeJobSource(model: panels.effectModel))
        jobCenter.register(AnonymizeRun.source)
        jobCenter.register(ConformJobSource(runner: panels.conformRunner))
        jobCenter.register(GyroflowJobSource(engine: GyroflowEngine.shared) { r in
            GyroflowEngine.shared.cancel(path: r.path, options: r.options)
        })
        jobCenter.startPolling()
    }

    /// The timeline shows a key lane on selected clips for the effect section selected in Effect Controls.
    func watchKeyLaneSection() {
        let m = panels.effectModel
        panels.timelineView.setKeyLaneSection(m.selectedSection)
        panels.updateCropHandles()   // the Crop edge handles show while the Crop section is selected
        panels.timelineView.selectedKeyLaneTimes = m.keyLaneSelectedTimes   // picked lane keys draw filled
        withObservationTracking {
            _ = m.selectedSection
            _ = m.selection
            _ = m.clip
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchKeyLaneSection() }
        }
    }

    /// Status-bar ring: show or hide the export queue.
    @objc func toggleTasks(_ sender: NSView) {
        exports.showQueue(relativeTo: sender.bounds, of: sender)
    }

    @objc func showSettings(_ sender: Any?) { settingsWindow.show() }

    /// Window menu panel item: a click toggles the panel (checkmark = visible); its keyboard shortcut shows and focuses it.
    @objc func windowPanelItem(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? PanelID else { return }
        if NSApp.currentEvent?.type == .keyDown {
            showPanel(p)
        } else {
            if maximizedPanel != nil { maximizedPanel = nil }
            // Color-only panels (not dockable on the Edit page) live on the Color page: a click goes there first.
            if !PanelID.dockable.contains(p), store.page != .color { showPanel(p); return }
            if isFloating(p) { closeFloatingPanel(p); return }
            let wasVisible = store.current.isVisible(p)
            mutateWorkspace { $0.toggle(p) }
            if !wasVisible { focusedPanel = p }
        }
    }

    // MARK: Menu

    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EditorCommand else { return }
        if Self.keyLog { NSLog("SQKEY menuCommand \(c) event=\(String(describing: NSApp.currentEvent?.type.rawValue))") }
        // A plain-key item (Space, J, X ...) is fired by the key monitor / KeyRouter. The same key down also reaches the
        // menu's key equivalent: running it again toggled Play twice (play, then pause at once). Clicks still run.
        if NSApp.currentEvent?.type == .keyDown, !sender.keyEquivalent.isEmpty,
           !sender.keyEquivalentModifierMask.contains(.command) { return }
        execute(c)
    }

    private static let chooserSafeActions: Set<Selector> = [
        #selector(AppController.openRecent(_:)), #selector(AppController.clearRecents(_:)), #selector(AppController.showAbout(_:)),
        #selector(AppController.showSettings(_:)), #selector(AppController.showStartWindowItem(_:)),
        #selector(AppController.openSupportPage(_:)), #selector(AppController.openDiscord(_:)), #selector(AppController.openGitHub(_:)),
        #selector(AppController.sendFeedback(_:)), #selector(AppController.revealLogs(_:)), #selector(AppController.openProject(_:)),
        #selector(AppController.newProject(_:)), #selector(AppController.showShortcutsItem(_:)),
        #selector(NSApplication.terminate(_:)), #selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
        #selector(NSApplication.unhideAllApplications(_:)), #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:)),
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // A dialog or sheet is waiting for an answer: no command may reach the project behind it (the dialog's own text
        // fields still get Cmd+C/V/A from their field editor before the main menu is asked).
        if SQModalGate.blocksCommands(attachedSheet: window?.sqAttachedSheet != nil, appModal: NSApp.modalWindow != nil) { return false }
        // The project chooser is up: only commands that start or open a project (and app-level items) work.
        if chooserShown {
            let c = item.representedObject as? EditorCommand
            let ok = c == .newProject || c == .openProject || (item.action.map { Self.chooserSafeActions.contains($0) } ?? false)
            return StartOverlayPolicy.menuEnabled(chooserShown: true, startsOrOpensProject: ok)
        }
        switch item.action {
        case #selector(renameWorkspace(_:)), #selector(deleteWorkspace(_:)): return store.canRenameOrDeleteCurrent
        case #selector(resetLayout(_:)): return store.canResetCurrent
        case #selector(relinkMediaItem(_:)): return session.canRelink
        case #selector(showImportChecklist(_:)): return importChecklistState != nil && window?.sqAttachedSheet == nil
        case #selector(closeProjectItem(_:)): return !session.isEmptyUntitled && window?.sqAttachedSheet == nil
        case #selector(changeFormatItem(_:)), #selector(duplicateAsFormatItem(_:)): return session.activeTimeline != nil
        case #selector(setProjectInputColorItem(_:)):
            item.state = (item.representedObject as? ColorSpaceID) == session.project.inputColorSpace ? .on : .off
            return true
        case #selector(windowPanelItem(_:)):
            if let p = item.representedObject as? PanelID {
                item.state = (p == .colorClips ? colorClipsShowing : store.current.isVisible(p)) ? .on : .off
                // Steps is the Pro grade's graph: no Simple grade, no Steps panel.
                if p == .steps, !(store.page == .color && panels.colorView.proShown) { item.state = .off; return false }
            }
            // Shift+digit shortcuts must not fire while typing in a field (menus see key equivalents first).
            if NSApp.currentEvent?.type == .keyDown, textResponder != nil || window?.firstResponder is NSTableView { return false }
            return true
        default: break
        }
        guard let c = item.representedObject as? EditorCommand else { return true }
        validateTimelineOpItem(c, item)
        // Plain-key items (no Command) belong to the KeyRouter; their key equivalent only fires when the router let the event pass.
        if !item.keyEquivalent.isEmpty, !item.keyEquivalentModifierMask.contains(.command) {
            if let tv = window?.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor { return false }
            if window?.firstResponder is NSTableView { return false }
        }
        if textResponder != nil, [.find, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub].contains(c) { return false }
        // Typing in a text field: the standard editing commands belong to it; panel-only Command shortcuts do not fire.
        if textResponder != nil, [.cut, .copy, .paste, .delete, .deleteProjectItems, .selectAll].contains(c) { return true }
        if textResponder != nil, MenuKeys.blockedWhileTyping(c, commandMap) { return false }
        if [.colorInspector, .colorClips, .steps].contains(focusedPanel), c == .copy { return panels.colorView.canCopyGrade }
        if [.colorInspector, .colorClips, .steps].contains(focusedPanel), c == .paste { return panels.colorView.canPasteGrade }
        if let enabled = focusedEditEnabled(c) { return enabled }
        if ([.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus), let enabled = validateInEffectControls(c) { return enabled }
        switch c {
        case .undo:
            item.title = session.undoName.map { SQL10n.format("Undo %@", SQL10n.undoName($0)) } ?? SQL10n.string("Undo")
            return session.canUndo || textResponder != nil
        case .redo:
            item.title = session.redoName.map { SQL10n.format("Redo %@", SQL10n.undoName($0)) } ?? SQL10n.string("Redo")
            return session.canRedo || textResponder != nil
        case .save: return true
        case _ where (c == .delete || c == .rippleDelete) && effectControlsHasFocus:
            return !panels.effectModel.selection.isEmpty || panels.effectModel.selectedSection.map(panels.effectModel.canDeleteSection) == true
        default: return effectsLookEnabled(c) ?? commandEnabled(c)
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseHeldKeys() }
        }
    }

    /// Cmd-Tab or a click into another window while J/K/L or a tool key is held: their key ups never reach us. Without
    /// this a lost K made every later L a one-frame step, a lost L ignored the next L press, and a lost tool hold
    /// reverted the tool on the next tap of that key.
    private func releaseHeldKeys() {
        guard !isTerminating else { return }
        // A temporary tool held past the threshold goes back, as its key-up would have done.
        let back = toolHold.releaseAll(at: ProcessInfo.processInfo.systemUptime)
        consumedKeyDowns.removeAll()
        let actions = router.releaseAllKeys()
        deadlineWork?.cancel(); deadlineWork = nil
        guard panels != nil else { return }
        releaseKeepAttached()                     // a lost backtick key-up must not leave Fast Cut in keep-attached
        if let back { execute(.tool(back)) }
        if !actions.isEmpty { run(actions) }
    }

    /// Also ends the router deadline timer; safe to call twice.
    func removeKeyMonitor() {
        isTerminating = true
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let o = resignKeyObserver { NotificationCenter.default.removeObserver(o) }
        resignKeyObserver = nil
        deadlineWork?.cancel(); deadlineWork = nil
    }

    /// Returns nil when the event was consumed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Nothing while quitting or while any modal (Save alert, open/save panel) runs: its window is not ours and
        // the panels may be mid-teardown (crash: objc_retain on a freed first responder during applicationShouldTerminate).
        guard !isTerminating, NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
              let window, event.window === window || (presentation != nil && event.window === presentation?.window),
              window.sqAttachedSheet == nil, panels != nil else { return event }
        // Full Screen presentation: Esc leaves it; every other key goes through the normal routing below.
        if presentation != nil {
            if event.type == .keyDown, event.keyCode == 53 { exitProgramPresentation(); return nil }
            if event.type == .leftMouseDown { return event }
        }
        // The start screen is its own window: its keys never reach this monitor (`event.window === window` above).
        if event.type == .leftMouseDown {
            if session.keepAttachedHeld { keepAttachedUsed = true }
            if let p = panels.panel(containing: window.contentView?.hitTest(event.locationInWindow)) { focusedPanel = p }
            return event
        }
        // Typing: only a text view that can really be edited keeps its keys. A selectable label's field editor
        // (isFieldEditor but not editable) must not swallow Space/J/K/L: that was the "Space does nothing" regression.
        if let tv = window.firstResponder as? NSTextView, tv.isEditable {
            // A shuttle key held while the click into the field happened: its key up still ends the shuttle, or J/K/L stay "down".
            if event.type == .keyUp, let up = KeyMapping.keyEvent(from: event), handleKeepAttachedHold(up) { return event }
            if event.type == .keyUp, let up = KeyMapping.keyEvent(from: event), router.consumes(up) {
                run(router.handle(up))
                scheduleRouterDeadline()
                return nil
            }
            return event
        }
        // Esc closes Trim mode first (TL-08).
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           panels.trimModel.isActive, !panels.timelineView.isDragging {
            panels.exitTrimMode()
            return nil
        }
        // Esc goes back to the Selection tool (not while a drag or an Esc-cancellable gesture runs: that Esc cancels it).
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           activeEditorTool != .selection, !panels.timelineView.isDragging {
            toolHold.clear()
            execute(.tool(.selection))
            return nil
        }
        // Esc with a clip selected (Selection tool, no drag, no text being edited) clears the selection.
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           !panels.timelineView.isDragging, !(window.firstResponder is NSTextView),
           !session.selection.isEmpty || !session.captionSelection.isEmpty {
            execute(.deselectAll)
            return nil
        }
        guard let ke = KeyMapping.keyEvent(from: event) else { return event }
        if handleSnapHold(ke) { return nil }
        if handleKeepAttachedHold(ke) { return nil }
        if session.keepAttachedHeld, ke.phase == .down { keepAttachedUsed = true }
        if ke.phase == .up, let back = toolHold.release(ke.key, at: ProcessInfo.processInfo.systemUptime) { execute(.tool(back)) }
        // Command shortcuts that a menu item carries belong to the menus (key equivalents). The others (nudge, Cmd+B in
        // the Project panel) have no item and go through the router like plain keys.
        if ke.modifiers.contains(.command), menuOwnedKeys.contains(ke.binding) { return event }
        // Lists keep their arrow and delete keys; focused number fields, sliders and icon grids keep the arrows (not the playhead).
        if window.firstResponder is NSTableView, [Key.delete, .forwardDelete, .returnKey].contains(ke.key) { return event }
        if [Key.up, .down, .left, .right].contains(ke.key), KeyClaims.claimsArrowKeys(responder: window.firstResponder) { return event }
        // Consume every key the router knows, also auto-repeats and key ups it turns into no action: an unconsumed
        // key down travels to NSWindow and plays the error beep.
        let consumed = router.consumes(ke)
        let actions = router.handle(ke)
        scheduleRouterDeadline()
        // A key up always follows its consumed key down (Delete removed the clip, its key up must not travel on).
        if ke.phase == .up, consumedKeyDowns.remove(ke.key) != nil { return nil }
        if ke.phase == .down, consumed || !actions.isEmpty { consumedKeyDowns.insert(ke.key) }
        // Delete with the timeline as first responder but another panel's key scope focused: the menu's Delete item does
        // the work; the key down must not also reach NSResponder.keyDown, which plays the error beep.
        // Any first responder, not only the timeline (Effect Controls, Graphics, Captions, Keystones have no router binding).
        // Done = silent; refused (item disabled, nothing to delete) = the event goes on and the system beep says so.
        if ke.phase == .down, ke.key == .delete, !consumed, actions.isEmpty,
           DeleteKeyPolicy.route(responder: .other, routerConsumed: consumed, routerHasActions: !actions.isEmpty) == .menuThenBeepIfRefused {
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            if DeleteKeyPolicy.swallow(menuHandled: handled) { consumedKeyDowns.insert(ke.key); return nil }
            return window.firstResponder is TimelineView ? nil : event   // the timeline has no other handler: keep it silent as before
        }
        guard !actions.isEmpty else { return consumed ? nil : event }
        if Self.keyLog { NSLog("SQKEY \(ke.key) -> \(actions)") }
        if ke.phase == .down, !ke.isRepeat, let tool = actions.lazy.compactMap({ a -> EditorTool? in
            if case .command(.tool(let t), _) = a { return t } else { return nil } }).first {
            toolHold.press(ke.key, tool: tool, previous: activeEditorTool, at: ProcessInfo.processInfo.systemUptime)
        }
        run(actions)
        return nil
    }

    private static let keyLog = ProcessInfo.processInfo.environment["SQ_KEYLOG"] == "1"

    private func run(_ actions: [RouterAction]) {
        for a in actions {
            switch a {
            case .command(let c, _): execute(c)
            case .shuttle(let s):
                if CommandRouting.sourceMonitorOffered(focus: focusedPanel) { panels.source.apply(shuttle: s) } else { session.apply(shuttle: s) }
            }
        }
    }

    /// K held + J/L: slow mode starts after the hold threshold without another key event.
    private func scheduleRouterDeadline() {
        deadlineWork?.cancel()
        guard let deadline = router.nextDeadline else { return }
        let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0) + 0.01
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.run(self.router.tick())
                self.scheduleRouterDeadline()
            }
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Focused text editor, if the user is typing somewhere.
    var textResponder: NSTextView? {
        guard let tv = window?.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv
    }
}
