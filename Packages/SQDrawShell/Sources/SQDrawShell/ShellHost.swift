import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
import SQExport
import SQLibrary
import SQMedia

/// The platform's file choosers (the Mac `NSOpenPanel` / `NSSavePanel`; Windows `IFileOpenDialog` / `IFileSaveDialog` in
/// SQWinApp). nil from a chooser = the user canceled.
@MainActor
public protocol ShellFilePicker: AnyObject {
    func chooseProject() async -> URL?
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL?
    func chooseMedia() async -> [URL]
    /// Keyboard Shortcuts > Import Shortcuts (default in `ShellShortcuts.swift`: not offered).
    func chooseShortcutFile() async -> URL?
    /// Keyboard Shortcuts > Export Current Set.
    func chooseShortcutExportLocation(suggestedName: String) async -> URL?
    /// File > Project > Style Kit import (save false) and export (`.sqstyle`; default in `ShellMenuActions.swift`: nil).
    func chooseStyleKit(save: Bool, suggestedName: String) async -> URL?
    /// Reconnect Media's folder to search (default in `ShellRelink.swift`: not offered, nil).
    func chooseFolder(prompt: String) async -> URL?
    /// Project panel Locate… and Replace Media…: one file, opening in `directory` (default in `ShellLocate.swift`: nil).
    func chooseFile(prompt: String, directory: URL?) async -> URL?
    /// File > Export EDL / XML / FCPXML / OpenTimelineIO (default in `ShellInterchange.swift`: nil).
    func chooseExportLocation(suggestedName: String, fileExtension: String, prompt: String) async -> URL?
}

/// The app shell around the panels: menu bar, dialogs, the key route, the project file flows and the window title.
/// `AppController`'s shell part translated (AppController+Files `openProject`, `saveDocument`, `saveDocumentAs`,
/// `saveDocumentCopy`, `confirmDiscardChanges`, `closeProjectItem`, `presentMessage`; AppController+Shell
/// `executeShellCommand`, `revertProject`, `commandEnabled`). The host window feeds events and draws the bar and overlays.
@MainActor
public final class ShellHost {
    public let session: EditorSession
    public var map: CommandMap
    public var recents: RecentProjects
    /// What the host's panels know (the enabled rules read it).
    public var panels = ShellPanelFacts()
    /// The panel with keyboard focus (the key map's scope).
    public var focus: PanelID?
    /// J/K/L down and up state (K held + L = slow play or a frame step), the Mac `AppController.router` for the shuttle keys.
    /// Trim mode's model (the two-up monitor and the bar under the timeline show it; `ShellTrim.swift`).
    public lazy var trim = TrimModeModel(session: session)
    /// Program monitor Full Screen is on (`ShellFullScreen.swift`); the host draws only the picture and swallows the mouse.
    public var isProgramFullScreen = false
    public internal(set) var fullScreenStarted: TimeInterval = 0
    /// The platform hides or restores its window chrome with Full Screen.
    public var onFullScreenChange: (@MainActor (Bool) -> Void)?
    /// The Mac window: Command and Control are separate shortcut modifiers (`ShellKeys.command`). On by default on macOS.
    public var macKeys: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()
    var shuttleRouter = KeyRouter(map: .premiereDefault, focus: nil, clock: { ProcessInfo.processInfo.systemUptime })
    var shuttleDeadline: Task<Void, Never>?
    public weak var files: (any ShellFilePicker)?
    public let menuBar = MenuBar()
    /// The dockable panel layout and its workspaces (`ShellDock`, Window menu in `ShellDock+Shell.swift`).
    public let dock = ShellDock()
    public private(set) var dialog: ShellDialog?
    public var size = CGSize(width: 1280, height: 800) { didSet { layout() } }
    public var measure: TextMeasure { get { menuBar.measure } set { menuBar.measure = newValue; layout() } }

    /// A status line to flash (the Mac `statusBar.flash`).
    public var onStatus: (@MainActor (String) -> Void)?
    /// The host's panels run a command the shell does not own (zoom, panels, import...); true when handled.
    public var onCommand: (@MainActor (EditorCommand) -> Bool)?
    /// What a focused panel does for an edit verb that only it owns (Delete layers, keystones, captions; Select All layers).
    public var editActions: [CommandRouting.EditAction: @MainActor () -> Void] = [:]
    /// Menu rows that are not commands (About, Support, workspaces...); true when handled.
    public var onAction: (@MainActor (ShellAction) -> Bool)?
    /// The project in the window changed (opened, new, closed, saved under a new name): the host refreshes its panels.
    public var onProjectChanged: (@MainActor () -> Void)?
    /// Quit after the Save Changes question.
    public var onQuit: (@MainActor () -> Void)?
    /// Edit > Find with the timeline focused: the host opens the timeline's caption find and replace; false when the
    /// timeline has no captions (the Project Find dialog opens instead, the Mac `CommandRouting.findTarget`).
    public var showCaptionSearch: (@MainActor () -> Bool)?
    /// Persists the recents (`RecentProjects.save`, key `sq.recentProjects`).
    public var saveRecents: (@MainActor (RecentProjects) -> Void)?
    /// The Project panel's model: File > Import and Explorer drops land in it (the Mac `panels.projectModel`).
    public var projectModel: ProjectPanelModel?
    /// The platform's media probe (Premiere import); nil = media stays offline in an imported project.
    public var probe: ProjectPanelModel.Probe?
    /// Shows a file in the platform's file browser (Explorer /select, Finder); the crash report's Reveal.
    public var revealFile: (@MainActor (URL) -> Void)?
    /// Shows several files selected in one file-browser window (Finder); nil = reveal them one by one with `revealFile`.
    public var revealFiles: (@MainActor ([URL]) -> Void)?

    /// Reveal in Finder / Explorer for a whole selection (the Mac `menuReveal` selects them all in one window).
    public func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let revealFiles { revealFiles(urls) } else { for u in urls { revealFile?(u) } }
    }
    /// Where New Project creates the project folder (the Mac remembers the last choice; first default: the projects root).
    public var newProjectLocation: URL = StorageLocations.load().projectsRoot
    /// Preferences changed and were saved (the host applies them to its panels and engine).
    public var onSettingsChanged: (@MainActor (AppSettings) -> Void)?
    /// Opens a web page, a mail draft or a folder with the platform's handler (About, Help, Reveal Logs).
    public var openURL: (@MainActor (URL) -> Void)?
    /// Panel facts the menus show that the shell does not own (the Window > Tools check mark).
    public var fillMenuState: (@MainActor (inout ShellMenuState) -> Void)?
    /// Puts text on the clipboard; the crash report's Copy.
    public var copyText: (@MainActor (String) -> Void)?
    /// The audio output devices Preferences > Playback > Audio Output offers; nil = the host cannot pick one (row left out).
    public var audioOutputs: (@MainActor () -> [AudioOutputChoices.Device])?
    /// The user's effect and transition defaults (Preferences > Editing lists them with Restore Factory); nil = row left out.
    public var effectDefaultsLibrary: EffectDefaultsLibrary?
    /// The host opens an import window when a card mounts (Preferences > Media > Card Import).
    public var hasCardImport = false
    /// The Library's watched folders (Preferences > Media > Library Folders) and the calls that change them; nil = no Library.
    public var libraryFolders: (@MainActor () -> [ShellLibraryFolder])?
    public var addLibraryFolder: (@MainActor (URL) async -> Void)?
    public var removeLibraryFolder: (@MainActor (UUID) async -> Void)?
    /// Delete Cache (Preferences > Media); nil = the row is left out.
    public var clearCache: (@MainActor () -> Void)?
    /// The local Edit API Preferences > Advanced switches (nil: no Advanced page).
    public var editAPI: ShellEditAPI?
    var importRunning = false
    /// The user preset library Premiere presets and Motion Graphics Templates are imported into (the app's one store).
    public var presetStore: PresetStore = LibraryStores.presetStore
    /// The Library panel reloads after presets or templates were added.
    public var presetsChanged: (@MainActor () async -> Void)?
    /// What the last Premiere import left to check (File > Project > Import Checklist), nil before one.
    public var importChecklist: ShellImportChecklist?
    /// Where saved templates live (New Project, New Sequence from Template, Save Sequence as Template).
    public var templateFolder = TemplateFolder.standard
    /// The items selected in the Project list (Clip > Pixel Aspect acts on them); `ProjectListView` sets it.
    public var projectSelection: (@MainActor () -> [BinItemRef])?
    /// The start screen's card picture: the frame of the media file at `seconds` (nil until it is decoded).
    public var startPoster: (@MainActor (_ mediaPath: String, _ seconds: Double) -> ProjectPoster?)?
    /// The timeline's selected edit points (Apply Transition acts on them); nil = the selected clips' edges.
    public var edgeSelection: (@MainActor () -> EdgeSelection?)?
    /// Linear sample peak of a clip's source range from the host's waveform cache (Audio Gain); nil = unknown.
    public var clipPeak: (@MainActor (Clip) -> Double?)?
    /// The host's waveform of a media item (nil = not read yet; the call may start the read). Audio Gain, Auto Duck, Remove
    /// Silences and Sync Audio use it (ShellAudioTools.swift).
    public var waveform: (@MainActor (UUID) -> WaveformData?)?
    /// The start timecode a media file carries (Sync Audio's first try); nil = the platform reads none.
    public var startTimecode: (@MainActor (MediaRef) async -> Time?)?
    /// Clip > Video Options > Anonymize: the host's people finder and tracker (the Mac: SQAnalysis); it asks through
    /// `askAnonymize` and writes through `EditorSession.applyAnonymize`. nil: the command says it is not available.
    public var runAnonymize: (@MainActor () -> Void)?
    /// An Anonymize run is going: the command cancels it, and stays enabled.
    public var isAnonymizing: (@MainActor () -> Bool)?
    /// Sequence > Transcribe and Create Captions: the Text panel's host (SQAppShell `CaptionsHost.autoCaptions`) sets this when
    /// it exists; true when it answered (started or said why not).
    /// Magic mask frames of a sequence without a matte, for the export preflight note (the Mac passes `MagicMatteStore`);
    /// nil counts none.
    public var untrackedMagicFrames: ((Timeline, [Timeline.ID: Timeline]) -> Int)?
    public var runAutoCaptions: (@MainActor () -> Bool)?
    /// Double-click on a caption, Edit in Text: the Text panel's host shows the List tab and types into that caption's row
    /// (the Mac `TextPanelView.editCaption`); true when it did. Without a host the timeline falls back to a dialog.
    public var editCaptionInPanel: (@MainActor (CaptionItem.ID) -> Bool)?
    /// Text to speech for Voiceover from Text (the Mac passes `SpeechRenderer`); nil: the command says it is not available.
    public var voiceover: ShellVoiceoverBackend?
    /// Commands a panel host runs itself (the Text panel's Remove Filler Words and Disguise Voice read its transcript):
    /// true when the handler answered. Asked before `onCommand`.
    public var commandHandlers: [EditorCommand: @MainActor () -> Bool] = [:]
    /// Clip > Cut Tools > Whoosh at Selected Cuts: the Library host's SFX bin flow (`LibraryHost.whooshFromSFXBin`).
    public var runWhooshAtCuts: (@MainActor () -> Void)?
    /// A running analysis job's status line (Find Scene Changes, Stabilize, Auto Reframe); nil clears it. The Mac
    /// `StatusBar.setJob`.
    public var onJob: (@MainActor (String?) -> Void)?
    /// What the platform can analyze; nil = nothing, the commands say so.
    public var analysisBackend: (any AnalysisBackend)? { get { analysis.backend } set { analysis.backend = newValue } }
    /// Find Scene Changes, Auto Reframe and Stabilize on this window's session (SQEditorSession `AnalysisFlows`).
    public lazy var analysis = AnalysisFlows(session: session, backend: nil, ui: AnalysisFlowUI(
        setJob: { [weak self] in self?.onJob?($0.map { SQL10n.string($0) }) },
        flash: { [weak self] text, _ in self?.onStatus?(SQL10n.string(text)) }))
    /// Reads the Program picture back for Match Color to Clip (the Mac `FrameSampler`, Windows the compositor download).
    public var frameSampler: (any ProgramFrameSampling)? { get { analysis.frameSampler } set { analysis.frameSampler = newValue } }
    /// The weak stretches of tracked Magic masks (Go to Next Weak Tracking, the timeline's confidence strip); nil = none.
    public var magicHealth: MagicTrackHealthCache?
    /// The Library's saved presets and the palette's rows (`QuickApplyCatalog.items(presets:)` in SQDrawLibrary), set by the
    /// host that owns the Library.
    public var libraryPresets: (@MainActor () -> [PresetItem])?
    public var quickApplyItems: (@MainActor () -> [QuickApplyItem])?
    /// "Save Effect Stack as Preset…" (the palette's row): the host's preset sheet for the selected clip.
    public var saveStackAsPreset: (@MainActor () -> Void)?
    /// The Quick Apply palette while open (Option+Space), a modal layer like the export queue popover.
    public internal(set) var quickApply: QuickApplyPopup?
    lazy var quickApplyModel = QuickApplyModel(items: [])
    /// The ranges the open Remove Silences dialog would cut, for the timeline's red preview ([] = none; ShellAudioTools.swift).
    public var silencePreview: (@MainActor ([TimeRange]) -> Void)?
    /// Sequence > New Shape through the Create tool (SQAppShell `MonitorHost.createShapeAtCenter`); nil adds a new Graphic.
    public var onNewShape: (@MainActor (ShapeKind) -> Void)?
    /// Go to Timecode: opens the shown monitor's timecode field (SQAppShell `MonitorCardHost.focusTimecodeField`);
    /// false or nil falls back to the Go to Timecode dialog.
    public var focusTimecode: (@MainActor () -> Bool)?
    /// Menu check marks of host-owned toggles (Safe Margins, Show Overlays...); each host piece appends one.
    public var menuChecks: [@MainActor () -> Set<EditorCommand>] = []
    /// Host pieces that know a panel fact the menu rules read (Controls clip, Graphics selection, grade copy and paste): each
    /// one fills what it owns into the copy `currentFacts()` hands to the rules.
    public var factProviders: [@MainActor (inout ShellPanelFacts) -> Void] = []
    /// What the system clipboard holds of media (files from Finder / Explorer, a PNG image); the host reads it on demand. nil =
    /// the host cannot read the clipboard, Paste then only knows our own clip clipboard (`ShellFacts.swift`, `ShellPasteMedia.swift`).
    public var mediaClipboard: (@MainActor () -> PasteMedia.Content)?
    /// The Project list (View > List View, Icon View, thumbnail size); `ProjectListView` sets it.
    public weak var projectList: ProjectListView?
    /// Card volumes whose import dialog is up or being prepared (ShellCardImport.swift): one per card.
    var cardImportVolumes: Set<String> = []
    /// Keyboard Shortcuts while it is up (`ShellShortcuts.swift`).
    public internal(set) var shortcutsEditor: ShellShortcutsEditor?
    /// The key map changed in Keyboard Shortcuts (saved to `sq.keymap`): the host's panels take it.
    public var onKeymapChanged: (@MainActor (CommandMap) -> Void)?
    /// The start screen while it is up (`ShellStart.swift`) and what it was shown for.
    public internal(set) var startScreen: ShellStartScreen?
    /// The start screen's search sits in the window bar, not in a row of its own (the Mac; see `ShellStartScreen.barFrame`).
    public var startSearchInBar = false { didSet { startLayout() } }
    /// The start screen has a window of its own of this size (the Mac `StartWindowController`): it fills it with its own top
    /// bar, the title after the window buttons. The host shows that window while `isStartShown`, sets `size` to it so
    /// menus and dialogs opened from the start screen lay out there, and draws `drawOverlays` into it (ShellStartWindows.swift).
    /// nil: the screen covers the editor window under the menu bar (Windows).
    public var startWindowSize: CGSize? { didSet { startLayout() } }
    /// The supporters the About card lists (the bundled supporters file; none: no Supporters block).
    public var aboutSupporters: (@MainActor () -> [String])?
    var startShownFor: UUID?
    var startShownEmpty = false
    var startProjectID: UUID?
    var startDefaults: UserDefaults = .standard
    /// File > Export: the frame and audio sources of a sequence (the Mac `ExportSourceBuilder`; Windows: the D3D12
    /// compositor). nil = Export is not offered.
    public var exportSources: ExportDialogModel.SourceProvider?
    /// The queue that writes the files with the platform's encoder (`AVExportEncoder`, `FFmpegExportEncoder`).
    public var exportQueue: ExportQueue?
    /// Background jobs (proxies, transcription) the queue popover lists above the exports; nil when the host has none.
    public var backgroundJobs: (@MainActor () async -> [ExportQueuePopover.Background])?
    public var cancelBackgroundJob: ((String) -> Void)?
    /// The export queue popover while open (`showExportQueue`), the modal layer under dialogs and menus.
    public internal(set) var queuePopover: ExportQueuePopover?
    /// The status bar's ring while exports run (0...1); nil hides it (ShellBackgroundOffers.swift).
    public internal(set) var exportProgress: Double?
    /// The exports this window followed have ended (the Mac's notification when the app is in the background): the files
    /// that finished and the failure lines.
    public var onExportsFinished: (@MainActor (_ done: [URL], _ failed: [String]) -> Void)?
    /// The status bar's background relink offer ("Found 4 offline files · Reconnect"); nil hides the chip.
    public internal(set) var relinkOffer: ShellRelinkOffer?
    /// The codecs the platform's encoder writes (the presets are filtered to them).
    public var exportCodecs: [VideoCodec] = [.h264, .hevc]
    /// The encoder also writes audio-only files, GIFs and image sequences (their presets are offered).
    public var exportFileOutputs = false
    /// Sets up the Export model before the form opens (stem plans, stem audio and encoder).
    public var configureExport: (@MainActor (ExportDialogModel) -> Void)?
    /// Turns a preview frame of the Export sheet into pixels (`ShellExportPreview.frameImage`); nil = no picture.
    public var exportFrameImage: (@Sendable (ExportFrame) -> RGBAImage?)?
    /// The Export sheet's picture for the renderer: (slot, image, generation) while the sheet shows one.
    public var exportPreviewImage: (Int, RGBAImage, Int)? {
        guard let p = (dialog?.content as? ShellExportSheet)?.preview, let img = p.image else { return nil }
        return (ShellExportPreview.slot, img, p.generation)
    }
    /// True while the Export sheet's preview plays (the host redraws every frame).
    public var exportPreviewPlaying: Bool { (dialog?.content as? ShellExportSheet)?.preview.isPlaying == true }
    /// Where the last export went (the form's Folder).
    public var exportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Videos", isDirectory: true)
    /// Starts a flow (tests run it inline).
    public var spawn: @MainActor (@escaping @MainActor () async -> Void) -> Void = { f in Task { @MainActor in await f() } }

    public init(session: EditorSession, map: CommandMap, recents: RecentProjects = RecentProjects()) {
        self.session = session
        self.map = map
        self.recents = recents
        restoreCaptionsInMonitor()
        session.askFormatChange = { [weak self] current, proposed in await self?.askChangeSequenceFormat(current, proposed) ?? true }
        menuBar.refresh = { [weak self] in self?.menus() ?? [] }
        menuBar.menus = menus()
        dock.onFocus = { [weak self] p in self?.focus = p }
        layout()
    }

    private func layout() {
        menuBar.controller.bounds = CGRect(origin: .zero, size: size)
        startLayout()
        shortcutsEditor?.frame = CGRect(origin: .zero, size: size)
        dialog?.layout(in: CGRect(origin: .zero, size: size), measure: measure)
        queuePopover?.layout(in: CGRect(origin: .zero, size: size))
        quickApply?.measure = measure
        quickApply?.layout(in: CGRect(origin: .zero, size: size))
    }

    /// Lays out `d` again after its rows changed (a Preferences page swap).
    func relayout(_ d: ShellDialog) { if dialog === d { layout() } }

    // MARK: Window title, menus

    public var windowTitle: String {
        session.isEmptyUntitled ? ShellWindowTitle.text(projectName: nil, dirty: false)
            : ShellWindowTitle.text(projectName: session.displayName, dirty: session.isDirty)
    }

    public func menuState() -> ShellMenuState {
        var s = ShellMenuState()
        s.recents = recents.entries
        s.undoName = session.undoName
        s.redoName = session.redoName
        s.modalShown = dialog != nil || shortcutsEditor != nil
        s.chooserShown = startScreen != nil
        s.autosaveVersions = autosaveRows()
        if isAnonymizing?() == true { s.titles[.anonymize] = "Cancel Anonymize" }
        analysisTitles(into: &s)
        fillWindowState(&s)
        fillProjectState(&s)
        fillMenuState?(&s)
        return s
    }

    public func menus() -> [ShellMenu] {
        ShellMenuBar.build(state: menuState(), map: map,
                           validate: { [weak self] c in self?.menuEnabled(c) ?? false },
                           perform: { [weak self] a in self?.perform(a) })
    }

    /// A menu row's enabled state: `enabled` plus the focus rules of the Mac `validateMenuItem` (Cut, Copy, Paste, Select All
    /// and Delete follow the focused panel through `CommandRouting.editRoute`; Copy and Paste in the Color panels copy and
    /// paste the grade). Keys keep using `enabled`: a key the focused panel does not take goes on to the panel under it.
    public func menuEnabled(_ c: EditorCommand) -> Bool {
        let facts = currentFacts()
        // Typing in a text field (the Mac `textResponder`): the text verbs and Undo/Redo belong to it, panel-only Command
        // shortcuts and Find / poster frame / hover scrub do not fire.
        if facts.textEditing {
            if [.find, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub].contains(c) { return false }
            if [.cut, .copy, .paste, .delete, .deleteProjectItems, .selectAll, .undo, .redo].contains(c) { return true }
            if MenuKeys.blockedWhileTyping(c, map) { return false }
        }
        if [.colorInspector, .colorClips, .steps].contains(focus), c == .copy || c == .paste {
            return (c == .copy ? facts.canCopyGrade : facts.canPasteGrade) ?? true
        }
        if let verb = EditVerb(command: c) {
            switch CommandRouting.editRoute(target: FocusedEditTarget(panel: focus), verb: verb).enabled {
            case .timelineRules: break
            case .always: return true
            case .never: return false
            case .canPasteMedia: return facts.canPasteMedia
            case .graphicsHasSelection: return facts.graphicsHasSelection ?? true
            case .graphicsHasLayers: return facts.graphicsHasLayers ?? true
            }
        }
        // Effect Controls takes Cut / Copy / Paste when the panel has focus and something to act on, and owns Delete
        // (the Mac `validateInEffectControls`).
        if focus == .effectControls {
            switch c {
            case .copy where facts.effectCanCopy == true: return true
            case .cut where facts.effectCanCut == true: return true
            case .paste where facts.effectCanPaste == true: return true
            case .delete, .rippleDelete: if let can = facts.effectCanDelete { return can }
            default: break
            }
        }
        switch c {
        case .undo: return session.canUndo
        case .redo: return session.canRedo
        default: return enabled(c)
        }
    }

    public func enabled(_ c: EditorCommand) -> Bool {
        var p = currentFacts()
        p.dialogShown = p.dialogShown || dialog != nil
        p.anonymizing = isAnonymizing?() ?? false
        if let on = analysisEnabled(c) { return on }
        if focusedDeletesProject(c) { return projectList != nil }
        return ShellCommands.enabled(c, session: session, panels: p)
    }

    // MARK: Actions and commands

    public func perform(_ a: ShellAction) {
        switch a {
        case .command(let c): execute(c)
        case .openRecent(let path): spawn { await self.openProject(at: URL(fileURLWithPath: path)) }
        case .clearRecents: recents.clear(); saveRecents?(recents)
        case .quit: spawn { if await self.confirmDiscardChanges() { self.onQuit?() } }
        case .restoreAutosave(let path): restoreAutosave(path: path)
        case .saveCheckpoint: spawn { await self.saveCheckpoint() }
        case .startWindow: showStart(defaults: startDefaults)
        default:
            if performHelp(a) || performWindow(a) || performProject(a) { return }
            if onAction?(a) != true { flash(ShellPlatformText.notAvailable) }
        }
    }

    /// Commands the old AppKit window runs through Mac-only analysis or panels; tracked in docs/FEATURE-PARITY.md.
    /// Empty: Auto Captions runs through `runAutoCaptions` (CaptionsHost) on both platforms; where no speech engine exists the
    /// Transcribe tab says so itself.
    static let notYetShared: Set<EditorCommand> = []

    /// Runs a command: the shell's own file commands, then the host's panels, then the session-only commands. False when
    /// it is disabled or nobody runs it (a key press then goes on to the panel under it).
    @discardableResult
    public func execute(_ c: EditorCommand) -> Bool {
        if let taken = runFocusedEdit(c) { return taken }
        guard enabled(c) else { return false }
        switch c {
        case .newProject: spawn { await self.newProjectForm() }
        case .openProject: spawn { await self.chooseAndOpenProject() }
        case .save: spawn { _ = await self.saveDocument() }
        case .saveAs: spawn { _ = await self.saveDocumentAs() }
        case .saveCopy: spawn { _ = await self.saveDocumentCopy() }
        case .revert: spawn { await self.revert() }
        case .closeProject: spawn { await self.closeProject() }
        case .importMedia where files != nil: spawn { await self.importAnything() }
        case .preferences: spawn { await self.showPreferences() }
        case .keyboardShortcuts: showShortcuts()
        case .export where exportSources != nil: spawn { await self.showExport() }
        default:
            if runFocusedDelete(c) { return true }
            if c == .paste, pasteMedia() { return true }
            if runTrimCommand(c) { return true }
            if let done = executePanelCommand(c) { return done }
            if let handler = commandHandlers[c], handler() { return true }
            if performAudioFlowCommand(c) { return true }
            if onCommand?(c) == true { return true }
            if runAnalysisCommand(c) { return true }
            if runLibraryImportCommand(c) { return true }
            if c == .autoCaptions, let run = runAutoCaptions { _ = run(); return true }
            if c == .whooshAtCuts, let run = runWhooshAtCuts { run(); return true }
            if performDialogCommand(c) { return true }
            if runShuttleCommand(c) { return true }
            guard let line = ShellCommands.run(c, session: session) else {
                // A menu item that nothing handles yet says so instead of doing nothing (docs/FEATURE-PARITY.md).
                guard Self.notYetShared.contains(c) else { return false }
                flash("\(c.title) is not available in this window yet.")
                return true
            }
            if !line.isEmpty { flash(line) }
        }
        return true
    }

    func flash(_ s: String) { onStatus?(SQL10n.string(s)) }

    // MARK: Events and drawing

    /// One window event (pixels, `scale` = pixels per point). True when the shell took it; otherwise it goes on to the panels.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        syncStart()
        if let d = dialog { d.handle(e, scale: scale); return true }
        if let k = shortcutsEditor { k.handle(e, scale: scale); return true }
        if let q = quickApply, menuBar.controller.isOpen == false, q.handle(e, scale: scale) { return true }
        if let q = queuePopover, menuBar.controller.isOpen == false, q.handle(e, scale: scale) { return true }
        if menuBar.handle(e, scale: scale) { return true }
        // The dock takes presses on its gaps and tab strips (and their drags); hover only records the pointer.
        if startScreen == nil, dock.handle(e, scale: scale) {
            focus = dock.focused ?? focus
            return true
        }
        if let s = startScreen {
            // The start screen is modal: its own keys first, then only the commands that start or open a project.
            if s.handle(e, scale: scale) { return true }
            if case .keyDown(let k, let m) = e, let c = ShellKeys.command(k, m, focus: focus, map: map, mac: macKeys),
               ShellStartScreen.allowedCommands.contains(c) { _ = execute(c) }
            return true
        }
        if case .keyDown(let k, let m) = e {
            if k == .escape, m.isEmpty { return escapeKey() }
            if let c = ShellKeys.command(k, m, focus: focus, map: map, mac: macKeys) { return keyCommand(c, key: k) }
        }
        return false
    }

    /// The bar at the top of the window (call before the panels, which start `MenuBar.height` lower).
    public func drawBar(_ c: inout Canvas, theme: DrawTheme) { menuBar.draw(&c, theme: theme, width: size.width) }

    /// Open menus and the dialog over everything (call last).
    public func drawOverlays(_ c: inout Canvas, theme: DrawTheme) {
        syncStart()
        if startScreen == nil { dock.drawOverlay(&c, theme: theme) }
        startScreen?.draw(&c, theme: theme)
        shortcutsEditor?.draw(&c, theme: theme)
        queuePopover?.draw(&c, theme: theme)
        quickApply?.draw(&c, theme: theme)
        menuBar.drawMenus(&c, theme: theme)
        dialog?.draw(&c, theme: theme, window: CGRect(origin: .zero, size: size))
        if let d = dialog, d.footerMascot, d.mascotFrame.width > 0 { ShellMascot.draw(.sad, in: d.mascotFrame, into: &c) }
    }

    // MARK: Dialogs

    /// Shows `d` modally over the window and waits for the answer.
    public func ask(_ d: ShellDialog) async -> ShellDialog.Response {
        menuBar.controller.dismiss()
        return await withCheckedContinuation { (k: CheckedContinuation<ShellDialog.Response, Never>) in
            d.completion = { [weak self] r in
                if self?.dialog === d { self?.dialog = nil }
                k.resume(returning: r)
            }
            dialog = d
            layout()
        }
    }

    public func presentMessage(_ title: String, _ detail: String) {
        spawn { _ = await self.ask(ShellDialog(title, informative: detail)) }
    }

    public func presentError(_ title: String, _ error: Error) {
        SQLog.error("\(title): \(error.localizedDescription)")
        presentMessage(title, SQL10n.errorText(error))
    }

    /// Asks before the project in the window is replaced. True to go on.
    public func confirmDiscardChanges() async -> Bool {
        guard session.isDirty else { return true }
        let d = ShellDialog(SQL10n.format("Save changes to “%@”?", session.displayName),
                            informative: SaveChangesPrompt.detail(hasFile: session.fileURL != nil))
        for b in SaveChangesPrompt.buttons { d.addButton(b.title, role: b.role, leading: b.isLeading) }
        let choice = SaveChangesPrompt.choice(await ask(d))
        let saved: Bool? = choice == .save ? await saveDocument() : nil
        return SaveChangesPrompt.outcome(choice, saveSucceeded: saved) == .proceed
    }

    // MARK: Project files

    private func noteRecent(_ url: URL) {
        recents.note(url)
        saveRecents?(recents)
    }

    /// An untitled project that Save places (the start window's quick path; File > New Project is `newProjectForm`).
    public func newProject() async {
        guard await confirmDiscardChanges() else { return }
        session.newProject()
        onProjectChanged?()
    }

    public func chooseAndOpenProject() async {
        guard let url = await files?.chooseProject() else { return }
        await openProject(at: url)
    }

    public func openProject(at url: URL) async {
        if ProjectOpenRouting.route(for: url) == .premiereImport {
            await importPremiereProject(at: url)
            return
        }
        guard await confirmDiscardChanges() else { return }
        SQLog.info("project open start: \(url.path)")
        do {
            let salvage = try await session.open(url: url)
            SQLog.info("project open ok: \(url.lastPathComponent)")
            noteRecent(url)
            onProjectChanged?()
            offerRelinkIfNeeded()
            if let salvage { presentMessage(ProjectSalvageNotice.title, ProjectSalvageNotice.detail(fileName: url.lastPathComponent, report: salvage)) }
        } catch {
            if let m = ProjectOpenRouting.message(for: error, fileName: url.lastPathComponent) {
                presentMessage(m.title, m.detail)
            } else {
                presentError(SQL10n.format("Could not open “%@”", url.lastPathComponent), error)
            }
        }
    }

    /// Save, or Save As for an untitled project. False when the user canceled or saving failed.
    @discardableResult
    public func saveDocument() async -> Bool {
        guard let url = session.fileURL else { return await saveDocumentAs() }
        SQLog.info("project save start: \(url.path)")
        do { try await session.save(); SQLog.info("project save ok"); noteRecent(url); return true } catch {
            if reportedSilently(error) { return false }
            presentError("Could not save", error); return false
        }
    }

    @discardableResult
    public func saveDocumentAs() async -> Bool {
        guard let url = await chooseSaveURL(suggested: session.project.name, prompt: "Save") else { return false }
        SQLog.info("project save as start: \(url.path)")
        do { try await session.saveAs(to: url); SQLog.info("project save as ok"); noteRecent(url); onProjectChanged?(); return true } catch {
            if reportedSilently(error) { return false }
            presentError("Could not save", error); return false
        }
    }

    /// Save a Copy: writes the project somewhere as a new document; this window keeps its file and unsaved changes.
    @discardableResult
    public func saveDocumentCopy() async -> Bool {
        guard let url = await chooseSaveURL(suggested: session.project.name + " copy", prompt: "Save a Copy") else { return false }
        SQLog.info("project save copy start: \(url.path)")
        do { try await session.saveCopy(to: url); SQLog.info("project save copy ok"); return true } catch {
            if reportedSilently(error) { return false }
            presentError("Could not save a copy", error); return false
        }
    }

    private func chooseSaveURL(suggested: String, prompt: String) async -> URL? {
        guard var url = await files?.chooseSaveLocation(suggestedName: suggested + "." + ProjectFile.fileExtension, prompt: prompt) else { return nil }
        if url.pathExtension != ProjectFile.fileExtension { url.appendPathExtension(ProjectFile.fileExtension) }
        return url
    }

    /// The user opened another project while saving: no dialog, one log line.
    private func reportedSilently(_ error: Error) -> Bool {
        guard error as? EditorSession.SaveError == .projectChanged else { return false }
        SQLog.info("save canceled: another project was opened meanwhile")
        return true
    }

    public func revert() async {
        guard let url = session.fileURL, session.isDirty else { return }
        let d = ShellDialog(SQL10n.format("Revert to the last saved version of “%@”?", session.displayName),
                            informative: "Your changes since the last save will be lost.")
        d.addButton("Revert", role: .destructive)
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        do {
            let salvage = try await session.open(url: url)
            onProjectChanged?()
            if let salvage { presentMessage(ProjectSalvageNotice.title, ProjectSalvageNotice.detail(fileName: url.lastPathComponent, report: salvage)) }
        } catch { presentError("Could not revert", error) }
    }

    public func closeProject() async {
        guard await confirmDiscardChanges() else { return }
        session.closeProject()
        onProjectChanged?()
    }
}

/// One watched Library folder as Preferences shows it.
public struct ShellLibraryFolder: Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Abbreviated with `~`.
    public var path: String
    public var offline: Bool
    public init(id: UUID, name: String, path: String, offline: Bool) {
        self.id = id; self.name = name; self.path = path; self.offline = offline
    }
}
