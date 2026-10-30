import Foundation
import SQUIKit
import Observation
import SQCore
import SQLibrary
import SQMedia
import SQPlayback

/// The editing document: one project with undo history, the active sequence, playhead, selection, file state and
/// the Program engine. Every edit goes through `perform` / `performTimeline` (one undo step each); after each
/// commit, undo and redo the active timeline is pushed to the engine with `setTimeline`.
///
/// Timeline edits run through `Project.edit` so a nested clip can never make a sequence contain itself.
/// File work (save, open, autosave) runs on `ProjectSaveQueue`, off the main actor and serialized.
@MainActor @Observable
public final class EditorSession {
    public enum SaveError: Error, Equatable, LocalizedError {
        case noFileURL, projectChanged
        public var errorDescription: String? {
            switch self {
            case .noFileURL: SQL10n.string("The project has no file yet.")
            case .projectChanged: SQL10n.string("Another project was opened while saving.")
            }
        }
    }

    /// What changed, for the AppKit side that cannot use observation tracking cheaply.
    public struct Change: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let project = Change(rawValue: 1)       // history, timeline, file state
        public static let selection = Change(rawValue: 2)
        public static let playhead = Change(rawValue: 4)
        public static let transport = Change(rawValue: 8)
        public static let media = Change(rawValue: 16)        // a background prepare finished
        public static let status = Change(rawValue: 32)       // lastError changed
        public static let reveal = Change(rawValue: 64)       // undo/redo: scroll `revealRange` into view
        public static let sourcePatch = Change(rawValue: 128) // the active sequence's source patch changed
        public static let monitorPicture = Change(rawValue: 256) // the Program monitor shows another picture (Color solo on/off/switched): the scopes re-measure
    }

    // MARK: State

    public private(set) var history: History<Project>
    public private(set) var fileURL: URL?
    public private(set) var activeTimelineID: Timeline.ID?
    /// W5.1: the format variant the Program monitor shows per sequence (view state: not undoable, saved with the
    /// project). Read through `activeVariantID`, which ignores variants that no longer exist.
    public internal(set) var activeVariants: [Timeline.ID: FormatVariant.ID] = [:]
    /// Open sequence tabs over the timeline and the nested path of each (see `SequenceTabs`).
    public private(set) var sequenceTabs = SequenceTabs()
    public private(set) var playhead: Time = .zero
    /// Playhead before and after the undo steps that moved it (ripple edits), keyed by the undo depth the step
    /// produced, with the sequence it belongs to (it only applies while that sequence is the active one). Not part of
    /// the project: the playhead is view state.
    private var playheadSteps: [Int: (timeline: Timeline.ID, before: Time, after: Time)] = [:]
    /// Playhead records of the redo steps the running gesture replaced (`perform`): back with them when it is canceled.
    @ObservationIgnored private var heldPlayheadSteps: [Int: (timeline: Timeline.ID, before: Time, after: Time)] = [:]
    /// Effects of an undo step outside the project (Magic mask frames deleted from the matte store), by the tag of the
    /// history step they belong to: undone, redone, trimmed and dropped exactly with that step (`pruneSideSteps`).
    private var sideSteps: [UUID: (undo: () -> Void, redo: () -> Void)] = [:]

    /// Settles what `History` took out of the stack without undoing it: the side steps of withdrawn steps (a gesture
    /// canceled back to its start, `rewindUndo`) are reverted now, newest first; the side steps of folded steps become one
    /// step of the merged undo step. Runs before `pruneSideSteps`, which would drop them unrun.
    private func settleSideSteps() {
        for tag in history.takeWithdrawnTags() {
            if let side = sideSteps.removeValue(forKey: tag) { side.undo(); forceDirty = true }
        }
        let folded = history.takeFoldedTags().compactMap { sideSteps.removeValue(forKey: $0) }
        guard !folded.isEmpty else { return }
        let tag = UUID()
        guard history.tagNewestStep(tag) else { return }
        sideSteps[tag] = (undo: { for s in folded.reversed() { s.undo() } },
                          redo: { for s in folded { s.redo() } })
    }

    private func pruneSideSteps() {
        guard !sideSteps.isEmpty else { return }
        let live = history.liveTags
        sideSteps = sideSteps.filter { live.contains($0.key) }
    }
    public private(set) var selection: Set<Clip.ID> = [] {
        didSet { if selection != oldValue, !selectedLineKeys.isEmpty { selectedLineKeys = [] } }
    }
    /// Keys selected on the opacity / volume lines (`selectLineKeys`); frame nudges move them instead of the clips.
    public internal(set) var selectedLineKeys: Set<LineKeyRef> = []
    /// Mirror of the timeline's Linked Selection toggle (the host keeps it in sync). Selections the session makes itself
    /// (D, ...) add linked partners while it is on; an edit acts on exactly the selected clips (`TimelineEdit.scoped`).
    public var linkedSelection = true
    /// Selection follows playhead (Sequence menu, `sq.selectionFollowsPlayhead`): the clips under the playhead on the
    /// targeted tracks are selected as it moves; see `EditorSession+FollowSelection`.
    public internal(set) var selectionFollowsPlayhead = true
    @ObservationIgnored var followState: PlayheadFollow?
    /// A deferred follow evaluation is due (scrub drag, run of frame steps); `followTask` applies it at `followDeadline`.
    @ObservationIgnored var followPending = false
    @ObservationIgnored var followTask: Task<Void, Never>?
    @ObservationIgnored var followDeadline = ContinuousClock.now
    @ObservationIgnored var followLastStep: ContinuousClock.Instant?
    @ObservationIgnored var followWasPlaying = false
    /// The playhead rests this long before a deferred evaluation runs.
    @ObservationIgnored var followSettle: Duration = .milliseconds(90)
    /// Frame steps closer together than this are one run (a held arrow key repeats faster).
    @ObservationIgnored var followStepRun: Duration = .milliseconds(200)
    /// Evaluations that looked up the clips under the playhead (tests, profiling).
    @ObservationIgnored var followEvaluations = 0
    /// Fast Cut "keep attached" override: true while ` is held (the app sets it). Delete, Q/W and drags then leave the
    /// attached clips of the main-track clips they move or remove on their frame.
    public var keepAttachedHeld = false
    /// Edit mode a new sequence starts in (Preferences, `AppSettings.newSequenceEditMode`).
    public var newSequenceEditMode: TimelineEditMode = .normal
    /// Sequences placed as their own clips instead of one combined clip (header toggle, `sq.placeSequencesAsClips`).
    public var placeSequencesAsClips = false

    /// `ids` plus their linked partners and bundle mates (v57) when Linked Selection is on.
    public func expandingLinks(_ ids: Set<Clip.ID>) -> Set<Clip.ID> {
        guard linkedSelection, let t = activeTimeline else { return ids }
        let all = t.expandingBundles(ids)
        return all.union(t.heldBackPartners(of: all))
    }
    /// Shows a read-only Look file in the status line (see `LookStore.writeFailed`).
    @ObservationIgnored nonisolated(unsafe) private var lookWriteObserver: NSObjectProtocol?
    public private(set) var captionSelection: Set<CaptionItem.ID> = []
    /// The caption track the Captions panel's Look tab edits when no caption is selected (see `currentCaptionTrack`).
    public internal(set) var captionTrackFocus: CaptionTrack.ID?
    /// The selected layers of the selected graphic clip (kept by `GraphicsEditor`); a single text layer can take a Look.
    public var graphicLayerSelection: GraphicLayerSelection?
    /// The transition selected on the timeline (Effect Controls shows its Duration and Alignment).
    public internal(set) var selectedTransition: Transition.ID?
    /// Clips copied with Cmd+C / Cmd+X (Paste puts them at the playhead).
    public var clipboard: TimelineClipboard?
    /// The effect copied in Effect Controls (independent of the panel); Cmd-V pastes it onto the selected clips.
    public var effectClipboard: ClipEffect? { didSet { if effectClipboard != nil { builtInClipboard = nil } } }
    /// A built-in effect (Transform, Blend, Volume) copied in Effect Controls: Paste and Paste Attributes put its values,
    /// keyframes included, onto every selected clip of the same kind. Cleared by a clip copy; a built-in copy clears `effectClipboard`.
    public var builtInClipboard: BuiltInClipboard?
    /// FB-W: the user's effect and transition defaults every new instance starts from (the app keeps it in sync with
    /// `EffectDefaultsLibrary.shared`; empty = factory, as in tests). Changes go out through `onEffectDefaultsChange`.
    @ObservationIgnored public var effectDefaults = EffectDefaults()
    @ObservationIgnored public var onEffectDefaultsChange: ((EffectDefaults) -> Void)?
    public private(set) var isPlaying = false
    /// Record Voice-Over: the recorder (tests and the app can swap in another microphone).
    #if os(macOS)
    @ObservationIgnored public var voiceRecorder = VoiceRecorder()
    #endif
    /// Loop toggle and the range of "Play In to Out" (nil = whole sequence); see `PlaybackBounds`.
    public var bounds = PlaybackBounds() {
        // The picture leads the clock while playing (display lead): it must not show frames past the range end, and
        // the engine wraps a loop itself (the frames after the wrap are picked before the clock gets there).
        didSet {
            if bounds.range != oldValue.range { engine.playRange = bounds.range }
            if bounds.loop != oldValue.loop { engine.loops = bounds.loop }
        }
    }
    public private(set) var lastAutosave: Date?
    /// Message of the last refused or failed action (locked track, disk error...); UI shows it in the status bar.
    public private(set) var lastError: String?

    @ObservationIgnored public let engine: any ProgramEngine
    @ObservationIgnored var pushedLiveDucking: ProjectLiveDucking?
    /// Fast cutting (Q-CUT1): start marked by the first Cut Out press, and the time of the last Cmd+K cut.
    @ObservationIgnored var cutOutStart: Time?
    @ObservationIgnored var lastCutPoint: (timeline: Timeline.ID, time: Time, depth: Int)?
    @ObservationIgnored public let media: SessionMediaResolver
    /// Background proxies for the monitors (W9.9); nil = none (tests, stand-ins). Synced with the project's media.
    @ObservationIgnored public var autoProxy: SessionProxyService? {
        didSet { autoProxy?.sync(project.media, projectID: project.id, activeTimeline: activeTimeline) }
    }
    /// Extra monitors (the Trim monitor's engines) that must hear about relinked media like the Program engine.
    @ObservationIgnored var auxiliaryEngines: [AuxiliaryEngine] = []
    final class AuxiliaryEngine { weak var engine: (any ProgramEngine)?; init(_ e: any ProgramEngine) { engine = e } }
    public func addAuxiliaryEngine(_ e: any ProgramEngine) {
        auxiliaryEngines.removeAll { $0.engine == nil }
        auxiliaryEngines.append(AuxiliaryEngine(e))
        autoProxy?.addEngine(e)
    }
    @ObservationIgnored public internal(set) var autosaveStore: AutosaveStore
    @ObservationIgnored private let saveQueue: ProjectSaveQueue
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored public var onChange: (@MainActor (Change) -> Void)?
    /// Asked when the first clip placed into an empty, never configured sequence differs from its format (Premiere's
    /// "change sequence settings / keep existing" prompt). true = adopt the clip's format. nil hook = adopt silently.
    @ObservationIgnored public var confirmFormatChange: (@MainActor (_ current: SequenceFormat, _ proposed: SequenceFormat) -> Bool)?
    /// The same question for hosts whose dialogs are asynchronous (`placeMediaAsking`).
    @ObservationIgnored public var askFormatChange: (@MainActor (_ current: SequenceFormat, _ proposed: SequenceFormat) async -> Bool)?

    @ObservationIgnored private var forceDirty = false
    /// Color page, lower panel on Clips: the Program monitor shows this clip's whole source file
    /// (`colorSourceView`, own time axis), or the clip alone (`Timeline.soloingVideoClip`) when it has no file to scrub.
    /// nil = the normal composite. Never saved, never exported.
    @ObservationIgnored public var colorSoloClip: Clip.ID? {
        didSet {
            guard oldValue != colorSoloClip else { return }
            let before = colorSourceView?.clipID
            pushTimeline(force: false)
            // The picture on the monitor changed even when no file view came or went (a clip without a file solos alone):
            // the Scopes panel measures what the monitor renders, so it must re-measure.
            notify(colorSourceView?.clipID != before ? [.playhead, .transport, .monitorPicture] : .monitorPicture)
        }
    }
    /// The source file the Program monitor plays instead of the sequence (Color page, Clips mode). While set, the
    /// monitor's transport and seeks run in file time (`monitorTime` / `monitorDuration`); `playhead` follows inside
    /// the clip so the Color panel reads and keys values at the matching clip frame.
    @ObservationIgnored public internal(set) var colorSourceView: ColorSourceFileView?
    /// Color page, Pro grade, "Show matte": the monitor shows this Step's matte as a white overlay (`ColorMattePreview`).
    /// Never saved, never exported, no undo step.
    @ObservationIgnored public var colorMattePreview: ColorMattePreview? {
        didSet {
            guard oldValue != colorMattePreview else { return }
            pushTimeline(force: false)
            notify(.monitorPicture)
        }
    }
    @ObservationIgnored private var pushedMatte: ColorMattePreview?
    @ObservationIgnored private var pushedSolo: Clip.ID?
    @ObservationIgnored private var pushedSoloPicture: VideoTrackInfo?
    @ObservationIgnored private var pushedSoloStillSize: [Int]?
    @ObservationIgnored private var pushedCacheSpans: [RenderCacheSpan] = []
    /// Preview render cache (set by the app; nil = off, as in tests). Fed the real sequence on every push.
    @ObservationIgnored public var renderCache: SessionRenderCache? {
        didSet {
            oldValue?.onSpansChanged = nil
            oldValue?.seedFrames = nil
            renderCache?.onSpansChanged = { [weak self] in self?.pushTimeline(force: true) }
            renderCache?.seedFrames = { [weak self] in self?.engine.seedFrames($0) }
        }
    }
    @ObservationIgnored private(set) var pushed:(timeline: Timeline, sequences: [Timeline.ID: Timeline])?
    @ObservationIgnored private var mediaSnapshot: [MediaRef] = []
    /// The media infos the resolver last got (project input default applied): a change needs a redraw, since the
    /// timeline itself may be unchanged (W9.3 `Project.inputColorSpace`, a background color detection).
    @ObservationIgnored private var renderedInfos: [UUID: MediaInfo?] = [:]
    @ObservationIgnored var requestedMedia: Set<UUID> = []
    /// Files of the project's media as last seen on disk (`refreshMediaFromDisk`).
    @ObservationIgnored var diskTracker = MediaDiskTracker()
    #if os(macOS)
    @ObservationIgnored var diskWatcher: MediaDiskWatcher?
    #endif
    @ObservationIgnored var diskRefreshRunning = false
    /// Growing-file poll (`growingFileTick`): remembered stamps of the online files, quiet-poll counter, re-entry guard.
    @ObservationIgnored var growTracker = MediaFileStampTracker()
    @ObservationIgnored var growQuietPolls = 0
    @ObservationIgnored var growPollRunning = false
    /// Called after media files changed on disk (re-exported, gone, back): UI caches of these items (thumbnails,
    /// waveforms, the project panel's offline marks) are dropped.
    @ObservationIgnored public var onMediaFilesChanged: (@MainActor (Set<UUID>) -> Void)?
    @ObservationIgnored var gestureCounter = 0
    /// Set while a Speed field gesture (drag, arrows, wheel) runs: every applySpeed of it merges into one undo step.
    @ObservationIgnored var speedGestureKey: String?
    @ObservationIgnored var stabilizerReplanTask: Task<Void, Never>?
    @ObservationIgnored var queuedStabilizerAnalysis: [Timeline.ID: Set<Clip.ID>] = [:]
    /// Clips whose Rolling Shutter was switched on and are waiting for the analysis it needs (per sequence). A Cancel
    /// switches the option back off for them (`withdrawRollingShutterRequests`).
    @ObservationIgnored var rollingShutterRequests: [Timeline.ID: Set<Clip.ID>] = [:]
    /// Stabilize dropped from the Effects panel: these clips carry an unanalyzed Standard Stabilizer; the app analyzes them.
    @ObservationIgnored public var onStabilizerNeedsAnalysis: ((Timeline.ID, Set<Clip.ID>) -> Void)?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// The session lets go of a project (close, open another, new): the project and whether it had unsaved edits. The app
    /// drops Magic matte files the saved project no longer refers to (an unsaved one may still need them after a reopen).
    @ObservationIgnored public var onReleaseProject: ((Project, Bool) -> Void)?

    public var project: Project { history.current }
    public var isDirty: Bool { history.isDirty || forceDirty }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var undoName: String? { history.undoName }
    public var redoName: String? { history.redoName }
    public var activeTimeline: Timeline? { activeTimelineID.flatMap { project.timeline($0) } }
    public var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? project.name }

    // MARK: Lifecycle

    public init(project: Project = EditorSession.makeUntitled(), fileURL: URL? = nil,
                engine: any ProgramEngine = StubProgramEngine(),
                media: SessionMediaResolver = SessionMediaResolver(),
                saveQueue: ProjectSaveQueue = ProjectSaveQueue(),
                autosaveStore: AutosaveStore = AutosaveStore(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.history = History(project)
        self.fileURL = fileURL
        media.setProjectFolder(MediaManagement.projectFolder(forProjectAt: fileURL))
        self.engine = engine
        self.media = media
        self.saveQueue = saveQueue
        self.autosaveStore = autosaveStore
        self.clock = clock
        self.activeTimelineID = project.activeTimeline ?? project.pickableTimelines.first?.id
        self.activeVariants = project.activeVariants
        if let id = activeTimelineID { sequenceTabs.open(id) }
        engine.onPositionChange = { [weak self] t in self?.enginePositionChanged(t) }
        lookWriteObserver = NotificationCenter.default.addObserver(forName: LookStore.writeFailed, object: LookStore.shared, queue: .main) { [weak self] note in
            let message = (note.object as? LookStore)?.readOnlyMessage
            MainActor.assumeIsolated { if let message { self?.setError(message) } }
        }
        Task { @MainActor in await CaptionLookLibrary.shared.reload() }       // saved caption looks resolve without the Captions tab
        beginMarker()
        syncMedia()
        syncStyleKit()                // W8.3: captions resolve this project's tokens
        pushTimeline(force: true)
    }

    /// Probe used by `detectMissingColor` (SQMedia `ColorDetection`); injectable for tests.
    /// Probes a relinked file whose clips still owe the v10 Scale step (H6). Runs off the main actor.
    /// Shooting date and camera of a file (open-time backfill for projects saved before they were stored).
    #if os(macOS)
    @ObservationIgnored var shootProbe: @Sendable (URL) async -> ShootMetadata.Result = { await ShootMetadata.read($0) }
    @ObservationIgnored var mediaInfoProbe: @Sendable (URL) async -> MediaInfo? = { try? await MediaImporter.probe($0).1 }
    @ObservationIgnored var colorDetector: @Sendable (URL) async -> (space: ColorSpaceID, embeddedLUTName: String?)? = { await ColorDetection.detect(url: $0) }
    #else
    // shortcut: no media probe off the Mac yet (nothing is probed, colors stay as stored); upgrade with the FFmpeg probe
    // (SQMediaFFmpeg) behind the same closures.
    @ObservationIgnored var mediaInfoProbe: @Sendable (URL) async -> MediaInfo? = { _ in nil }
    @ObservationIgnored var colorDetector: @Sendable (URL) async -> (space: ColorSpaceID, embeddedLUTName: String?)? = { _ in nil }
    #endif

    deinit {
        autosaveTask?.cancel()
        if let lookWriteObserver { NotificationCenter.default.removeObserver(lookWriteObserver) }
    }

    /// Empty project with one 29.97 fps HD sequence (V1-V4, A1-A4).
    public static func makeUntitled() -> Project {
        let t = Timeline(name: "Sequence 01", format: SequenceFormat(frameDuration: Time(1001, 30000)),
                         tracks: Timeline.defaultTracks(), formatLocked: false)
        return Project(name: "Untitled", timelines: [t])
    }

    /// The state before a project is chosen (launch chooser, after Close Project): a project without any sequence.
    /// Panels and monitors already show their empty state for `activeTimeline == nil`.
    public static func makeEmpty() -> Project { Project(name: "Untitled", timelines: []) }

    /// Ends the crash marker and the autosave timer. Call on a clean quit or before replacing the session.
    public func close() {
        stopAutosaveTimer()
        SessionMarker(store: autosaveStore).end(projectID: project.id)
        onProjectReplaced?()
        onReleaseProject?(project, isDirty)
    }

    private func beginMarker() {
        try? SessionMarker(store: autosaveStore).begin(projectID: project.id, projectURL: fileURL, projectName: project.name)
    }

    public func notify(_ c: Change) { followTransportChanged(); onChange?(c) }

    // MARK: Editing

    /// One undo step. `coalescing`: consecutive edits with the same key merge. Throws the edit's error and then
    /// leaves the project untouched.
    public func perform(_ name: String, coalescing key: String? = nil,
                        _ edit: (inout Project) throws -> Void) rethrows {
        let depth = history.undoDepth
        // W8.3: token-bound text that arrives by insert, paste, template drop or variant write-back is resolved in the same step.
        try history.commit(name, coalescing: key) { p in try Self.performSteps(&p, edit) }
        // A new step replaces the redo steps: their playhead records go with them.
        // A gesture keeps them aside while it can still be canceled: canceled back to its start, its step is dropped and
        // Redo is what it was before (`History.commit`), playhead records included.
        if history.undoDepth > depth {
            heldPlayheadSteps = history.holdsRedo ? playheadSteps.filter { $0.key >= history.undoDepth } : [:]
            playheadSteps = playheadSteps.filter { $0.key < history.undoDepth }
        } else if history.undoDepth < depth {
            playheadSteps = playheadSteps.filter { $0.key <= history.undoDepth }
            if history.canRedo { playheadSteps.merge(heldPlayheadSteps) { _, held in held } }
            heldPlayheadSteps = [:]
        }
        settleSideSteps()
        pruneSideSteps()
        projectDidChange()
    }

    /// A drag ended (mouse up): its undo step is final. The redo steps kept aside for a cancel are let go and the next
    /// edit starts a step of its own.
    public func endGesture() {
        history.endCoalescing()
        heldPlayheadSteps = [:]
        pruneSideSteps()
    }

    /// Current undo depth: take it before an edit, hand it to `registerSideStep` after.
    public var undoStepDepth: Int { history.undoDepth }

    /// Ties `undo` / `redo` (a change outside the project) to the undo step the edit since `depth` made, so it is ONE
    /// step; an edit that made none (the project did not change) gets a named step of its own. The project counts as
    /// changed (saved again).
    public func registerSideStep(_ name: String, since depth: Int, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        let tag = UUID()
        var undo = undo, redo = redo
        // The step may already carry one (a second frame delete of one drag): both run, as one, in order.
        // Replacing the tag alone would lose the first without ever running it.
        if history.undoDepth > depth, let held = history.undoTag, let first = sideSteps.removeValue(forKey: held) {
            let (u, r) = (undo, redo)
            undo = { u(); first.undo() }
            redo = { first.redo(); r() }
        }
        if history.undoDepth > depth, history.tagNewestStep(tag) {} else {
            history.pushMarker(name, tag: tag)
            playheadSteps = playheadSteps.filter { $0.key < history.undoDepth }   // Redo is gone, so are its playhead records
        }
        sideSteps[tag] = (undo, redo)
        forceDirty = true
        pruneSideSteps()
        projectDidChange()
    }

    /// The project `perform` would produce, without committing anything (edit API dry run): same extra steps.
    public func previewPerform(_ edit: (inout Project) throws -> Void) rethrows -> Project {
        var p = history.current
        try Self.performSteps(&p, edit)
        return p
    }

    private static func performSteps(_ p: inout Project, _ edit: (inout Project) throws -> Void) rethrows {
        let before = p
        try edit(&p)
        // COLOR-GRADE-LINKS: an edited member's grade goes to the clips linked with it, in the same undo step.
        p.propagateGradeLinks(from: before)
        // v49: Adjustment Layers with "Extend to sequence end" follow the cut, in the same undo step.
        p.extendAdjustmentLayersToSequenceEnd()
        resolveStyleTokens(&p)
        // H6: a clip that took a pending source's Motion (Paste Attributes, pasted clips) onto media with probe info
        // owes its v10 Scale step now, with its own fit; only clips of unknown size stay pending.
        p.applyPendingScaleMigration()
    }

    /// Edits the active timeline through `Project.edit`: a nesting cycle is refused with `.nestingCycle`.
    public func performTimeline(_ name: String, coalescing key: String? = nil,
                                _ body: (inout Timeline) throws -> Void) throws {
        guard let id = activeTimelineID else { throw EditError.timelineNotFound }
        try perform(name, coalescing: key) { try $0.edit(id) { try body(&$0); $0.normalizeAudioKeyMarks() } }
    }

    /// Like `performTimeline`, but a refused edit only sets `lastError`. Returns whether it was applied.
    @discardableResult
    public func attempt(_ name: String, coalescing key: String? = nil, _ body: (inout Timeline) throws -> Void) -> Bool {
        let before = history.current
        do { try performTimeline(name, coalescing: key, body) } catch {
            setError(Self.message(for: error)); return false
        }
        return history.current != before
    }

    /// `attempt` for edits that can ripple. The playhead keeps the picture it was on (`Timeline.followingRipple`): it
    /// moves left by what the edit closed before it; inside a closed span it lands on the edit point. The move is
    /// remembered with the undo step, so Undo puts the playhead back and Redo moves it again.
    @discardableResult
    func attemptRipple(_ name: String, _ body: (inout Timeline) throws -> Void) -> Bool {
        let at = playhead
        var landed = at
        guard attempt(name, { t in landed = try t.followingRipple(playhead: at, body) }) else { return false }
        let target = max(.zero, landed.snapped(to: frameDuration))
        if target < at, let id = activeTimelineID {
            seekSequence(to: target)                      // sequence time, also while the monitor shows a source file
            playheadSteps[history.undoDepth] = (timeline: id, before: at, after: target)
        }
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        let before = activeTimeline
        let step = playheadSteps[history.undoDepth]
        let side = history.undoTag.flatMap { sideSteps[$0] }
        guard history.undo() else { return false }
        if let side { side.undo(); forceDirty = true }
        lastCutPoint = nil                                 // the next cut is not "the second of two" any more
        projectDidChange()
        revealChange(since: before)
        // A ripple had moved the playhead: back where it was (only in the sequence it happened in).
        if let step, step.timeline == activeTimelineID { seekSequence(to: step.before) }
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        let before = activeTimeline
        let side = history.redoTag.flatMap { sideSteps[$0] }
        guard history.redo() else { return false }
        if let side { side.redo(); forceDirty = true }
        lastCutPoint = nil
        projectDidChange()
        revealChange(since: before)
        if let step = playheadSteps[history.undoDepth], step.timeline == activeTimelineID { seekSequence(to: step.after) }
        return true
    }

    /// Time range the last undo/redo touched; the view scrolls it into view on `.reveal`. Not part of history.
    public private(set) var revealRange: TimeRange?

    /// Makes an undo/redo visible: selects the affected clips, moves the playhead into the affected range when it
    /// is outside, and asks the view to scroll there. Zoom stays as it is.
    private func revealChange(since before: Timeline?) {
        guard let focus = UndoFocus.between(before, activeTimeline) else { return }
        if !focus.clips.isEmpty { setSelection(clips: focus.clips, captions: []) }
        if let t = focus.playhead(from: playhead) { seek(to: t) }
        revealRange = focus.range
        notify(.reveal)
    }

    /// Applies a finished timeline gesture (`TimelineInteraction`) as ONE undo step by replaying its edits.
    public func commit(_ c: TimelineCommit) {
        let ok = attemptRipple(c.undoName) { t in
            if c.edits.isEmpty { t = c.timeline } else { for e in c.edits { try e.apply(to: &t) } }
        }
        guard ok else { return }
        setSelection(clips: c.selection, captions: c.captionSelection)
    }

    /// Property edit of one clip (Effect Controls). Edits of one gesture (`continuesGesture`) merge into one step.
    public func replaceClip(_ clip: Clip, name: String, continuesGesture: Bool) {
        if !continuesGesture { gestureCounter += 1 }
        attempt(name, coalescing: "clip:\(clip.id):\(gestureCounter)") { try $0.replaceClip(clip) }
    }

    /// Premiere "Nest" of the selected clips. Returns the new sequence.
    @discardableResult
    public func nestSelection(name: String) -> Timeline.ID? {
        guard let id = activeTimelineID, !selection.isEmpty else { return nil }
        var seq: Timeline.ID?
        let ids = Array(selection)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Fast Cut: the attached clips inside the span go into the nest too (`magneticNest`); Normal: `nest`.
            try perform("Combine") { p in seq = try p.magneticNest(clips: ids, in: id, name: trimmed.isEmpty ? nil : trimmed) }
        } catch { setError(Self.message(for: error)); return nil }
        if let seq, let t = activeTimeline {
            setSelection(clips: Set(t.tracks.flatMap(\.clips).filter { $0.sequence == seq }.map(\.id)), captions: [])
        }
        return seq
    }

    /// Clip > Group (Cmd+G): the selected clips become one group clip with its own Motion, Opacity and effects (W7.6).
    @discardableResult
    public func groupSelection() -> Timeline.ID? {
        guard let id = activeTimelineID, !selection.isEmpty else { return nil }
        var seq: Timeline.ID?
        let ids = Array(selection)
        do { try perform("Group") { p in seq = try p.group(clips: ids, in: id) } }
        catch { setError(Self.message(for: error)); return nil }
        if let seq, let t = activeTimeline {
            setSelection(clips: Set(t.tracks.flatMap(\.clips).filter { $0.sequence == seq }.map(\.id)), captions: [])
        }
        return seq
    }

    /// Selected clips that play a Group (Ungroup targets).
    public var selectedGroupClips: [Clip] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && project.groupSequence(of: $0) != nil }
    }

    /// Clip > Ungroup (Shift+Cmd+G): every selected group comes apart into its clips, which become the selection.
    /// One undo step; nothing changes when one group cannot be ungrouped (the status bar says why).
    @discardableResult
    public func ungroupSelection() -> Bool {
        guard let id = activeTimelineID else { return false }
        let groups = selectedGroupClips
        guard !groups.isEmpty else { setError(Self.message(for: EditError.notAGroup)); return false }
        var restored: [Clip.ID] = []
        do {
            try perform("Ungroup") { p in
                var done = Set<Clip.ID>()
                for g in groups where !done.contains(g.id) {
                    // The linked partner of the same group comes apart with it.
                    if let t = p.timeline(id) {
                        for c in t.tracks.flatMap(\.clips) where c.id == g.id || (g.link != nil && c.link == g.link && c.sequence == g.sequence) {
                            done.insert(c.id)
                        }
                    }
                    restored += try p.ungroup(clip: g.id, in: id)
                }
            }
        } catch { setError(Self.message(for: error)); return false }
        setSelection(clips: Set(restored), captions: [])
        return true
    }

    /// Selected clips that play an ordinary nested sequence (not a Group, not an Angles clip).
    public var selectedNestedClips: [Clip] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.flatMap(\.clips).filter {
            selection.contains($0.id) && $0.angle == nil && project.timeline($0.sequence ?? UUID()).map { !$0.isGroup } == true
        }
    }

    /// Clip > Unnest: every selected nested clip is replaced by the content of its sequence (the sequence stays in the project).
    /// One undo step; nothing changes when one clip cannot be unnested (the status bar says why).
    @discardableResult
    public func unnestSelection() -> Bool {
        guard let id = activeTimelineID else { return false }
        let nested = selectedNestedClips
        guard !nested.isEmpty else { setError(Self.message(for: EditError.notNested)); return false }
        var restored: [Clip.ID] = []
        do {
            try perform("Unnest") { p in
                var done = Set<Clip.ID>()
                for n in nested where !done.contains(n.id) {
                    if let t = p.timeline(id) {
                        for c in t.tracks.flatMap(\.clips) where c.id == n.id || (n.link != nil && c.link == n.link && c.sequence == n.sequence) {
                            done.insert(c.id)
                        }
                    }
                    restored += try p.unnest(clip: n.id, in: id)
                }
            }
        } catch { setError(Self.message(for: error)); return false }
        setSelection(clips: Set(restored), captions: [])
        return true
    }

    public func setActiveTimeline(_ id: Timeline.ID) {
        guard project.timeline(id) != nil else { return }
        showInTabs(id)
        guard id != activeTimelineID else { return }
        stopForSequenceChange()
        activeTimelineID = id
        selection = []; captionSelection = []
        syncMedia()
        pushTimeline(force: true)
        clampPlayheadToActiveSequence()
        notify([.project, .selection])
    }

    /// A Group is never a tab of its own: it shows inside the active tab's path (breadcrumb); with no tab to host it, nothing opens.
    private func showInTabs(_ id: Timeline.ID) {
        guard sequenceTabs.current != id else { return }
        if project.timeline(id)?.isGroup == true {
            if sequenceTabs.activeIndex != nil { sequenceTabs.enter(id) }
        } else { sequenceTabs.open(id) }
    }

    /// Tab drag: moves the tab with this root to `index`.
    public func moveSequenceTab(root: Timeline.ID, to index: Int) { sequenceTabs.move(root, to: index); notify([.project]) }

    /// Double-click on a sequence: opens it as a tab (or switches to its tab).
    public func openSequenceTab(_ id: Timeline.ID) { setActiveTimeline(id) }

    /// Double-click on a nested sequence clip: opens it as its own tab, exactly like the project panel's double-click
    /// (the way back is its tab). The inside of a Group is no sequence of its own: it drills into the active tab (breadcrumb).
    public func enterNestedSequence(_ id: Timeline.ID) {
        guard let t = project.timeline(id) else { return }
        if t.isGroup { sequenceTabs.enter(id); setActiveTimeline(id) }
        else { openSequenceTab(id) }
    }

    /// Breadcrumb click: back out to `id` in the active tab.
    public func popSequence(to id: Timeline.ID) {
        sequenceTabs.popTo(id)
        setActiveTimeline(sequenceTabs.current ?? id)
    }

    /// Tab click: shows the tab's own (possibly nested) sequence.
    public func selectSequenceTab(root: Timeline.ID) {
        sequenceTabs.select(root)
        if let id = sequenceTabs.current { setActiveTimeline(id) }
    }

    /// Closes a tab; the last one stays. The sequence itself is untouched.
    public func closeSequenceTab(root: Timeline.ID) {
        guard sequenceTabs.tabs.count > 1 else { return }
        if let id = sequenceTabs.close(root) { setActiveTimeline(id) }
        notify(.project)
    }

    /// A different sequence becomes active: playback stops and the Play In to Out / Play Around range and return point of
    /// the old one are dropped (Loop stays as the user set it).
    private func stopForSequenceChange() {
        if isPlaying || !engine.rate.isPaused { engine.pause(); isPlaying = false; resetFollow(); notify(.transport) }
        resetFollow()
        bounds = PlaybackBounds(loop: bounds.loop)
    }

    /// Puts the playhead on a frame of the (new) active sequence.
    private func clampPlayheadToActiveSequence() {
        let end = activeTimeline?.duration ?? .zero
        let last = max(.zero, end - frameDuration)
        if playhead > last { seekSequence(to: last) } else if colorSourceView == nil { engine.seek(to: playhead) }
    }

    /// Withdraws every undo step above `depth` (Type tool: an empty text box leaves no trace). No redo entries remain.
    public func rewindUndo(toDepth depth: Int) {
        history.rewind(toDepth: depth)
        playheadSteps = playheadSteps.filter { $0.key <= depth }
        settleSideSteps()
        pruneSideSteps()
        projectDidChange()
    }

    /// Folds the undo steps above `depth` into one named step (Type tool: add + typed text = "Add Text").
    public func foldUndo(fromDepth depth: Int, name: String) {
        history.squash(fromDepth: depth, name: name)
        settleSideSteps()
        pruneSideSteps()
        // The folded steps become the one at `depth + 1`: it keeps their playhead move (first before, last after).
        let folded = playheadSteps.filter { $0.key > depth }.sorted { $0.key < $1.key }.map(\.value)
        playheadSteps = playheadSteps.filter { $0.key <= depth }
        if let last = folded.last, let first = folded.first(where: { $0.timeline == last.timeline }), history.undoDepth > depth {
            playheadSteps[depth + 1] = (timeline: last.timeline, before: first.before, after: last.after)
        }
    }

    private func projectDidChange() {
        let before = activeTimelineID
        sequenceTabs.prune(existing: Set(project.timelines.map(\.id)), rootable: Set(project.pickableTimelines.map(\.id)))
        if let id = activeTimelineID, project.timeline(id) == nil { activeTimelineID = nil }
        if activeTimelineID == nil {
            activeTimelineID = sequenceTabs.current.flatMap { project.timeline($0) }?.id
                ?? project.activeTimeline.flatMap { project.timeline($0) }?.id ?? project.pickableTimelines.first?.id
            if activeTimelineID != before { stopForSequenceChange() }
        }
        if let id = activeTimelineID, sequenceTabs.current != id { showInTabs(id) }
        pruneSelection()
        // An edit does not re-select by itself: the follow state is taken from the edited sequence at the playhead, so the
        // next seek to the same place leaves the selection alone (a new text or shape stays selected). It re-follows at the
        // next clip boundary crossing.
        if selectionFollowsPlayhead, colorSourceView == nil, let t = activeTimeline, t.tracks.contains(where: \.isTargeted) {
            followState = t.followedClips(at: playhead)
        } else {
            followState = nil
        }
        syncMedia()
        pushTimeline(force: false)
        syncStyleKit()
        if activeTimelineID != before { clampPlayheadToActiveSequence() }
        notify([.project, .selection])
    }

    /// The engine gets the active sequence as the active variant shows it (`Project.variantView`: materialised once per
    /// change, so playback never resolves overrides per frame), with every sequence reachable from it by nesting.
    /// The sequence the engine was last given (the active variant's materialised view); nil before the first push.
    var pushedTimeline: Timeline? { pushed?.timeline }

    /// View state saved with the project (active variant) changed: the project needs saving, no undo step.
    func markViewStateChanged() { forceDirty = true }
    /// For a temporary history-neutral edit that is taken back (see `saveAsWithoutWatching`).
    var needsSaveFlag: Bool { get { forceDirty } set { forceDirty = newValue } }

    func pushTimeline(force: Bool) {
        // N8b: the project's live ducking goes to the mix with the sequence (playback and scrub; export reads the project).
        if force || pushedLiveDucking != project.liveDucking {
            pushedLiveDucking = project.liveDucking
            engine.setProjectLiveDucking(project.liveDucking)
        }
        guard let id = activeTimelineID, let (t, nested) = project.variantView(of: id, variant: activeVariantID) else {
            pushed = nil; return
        }
        let solo = colorSoloClip
        // Raw file + grade only (DECISIONS "Color solo = raw source + grade"): the file's own size and rate when probed,
        // so probe info arriving later (relink, background probe) refreshes the solo too.
        let soloClip = solo.flatMap { id in t.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }
        let picture = soloClip.flatMap { project.media($0.media)?.info?.video }
        let stillSize = soloClip.flatMap { project.pictureSize(of: $0) }.map { [$0.width, $0.height] }
        let matte = colorMattePreview
        // Cached heavy segments playback reads instead of the clips; not with the solo or matte views (they show other pictures).
        let spans = (solo == nil && matte == nil) ? (renderCache?.spans(for: t, sequences: nested) ?? []) : []
        if !force, let p = pushed, p.timeline == t, p.sequences == nested, pushedSolo == solo, pushedSoloPicture == picture,
           pushedSoloStillSize == stillSize, pushedMatte == matte, pushedCacheSpans == spans { return }
        pushedCacheSpans = spans
        pushed = (t, nested)
        pushedMatte = matte
        pushedSolo = solo
        pushedSoloPicture = picture
        pushedSoloStillSize = stillSize
        let before = colorSourceView
        // The engine sees the sequence with the matte view substituted; `pushed` keeps the real one.
        let shown = matte.map { t.showingMatte($0) } ?? t
        let shownNested = matte.map { m in nested.mapValues { $0.showingMatte(m) } } ?? nested
        if let solo, var view = shown.colorSourceFileView(of: solo, at: playhead, picture: picture) {
            if let kept = before, kept.clipID == solo {        // an edit of the graded clip keeps the file frame
                let fd = view.timeline.frameDuration
                view.position = min(kept.position, max(.zero, view.timeline.duration - fd)).flooredToFrame(fd)
            } else { stopForViewerSwitch() }
            colorSourceView = view
            engine.setTimeline(view.timeline, sequences: shownNested)
            if before?.clipID != solo || before?.position != view.position { engine.seek(to: view.position) }
        } else {
            colorSourceView = nil
            if before != nil { stopForViewerSwitch() }
            var engineTimeline = solo.map { shown.soloingVideoClip($0, picture: stillSize.map { (width: $0[0], height: $0[1]) }) } ?? shown
            engineTimeline.renderCacheSpans = spans
            engine.setTimeline(engineTimeline, sequences: shownNested)
            if before != nil { engine.seek(to: playhead) }
        }
    }

    private func stopForViewerSwitch() {
        if isPlaying || !engine.rate.isPaused { engine.pause(); isPlaying = false }
        bounds.range = nil
    }

    private func pruneSelection() {
        guard let t = activeTimeline else { selection = []; captionSelection = []; return }
        selection.formIntersection(Set(t.tracks.flatMap { $0.clips.map(\.id) }))
        captionSelection.formIntersection(Set(t.captionTracks.flatMap { $0.items.map(\.id) }))
        if let id = selectedTransition, t.transition(id) == nil { selectedTransition = nil }
    }

    /// Media that is not at its path (offline): the relink dialog's input.
    public var missingMedia: [MediaRef] { project.missingMedia() }

    /// Points offline media at found files: one undo step; the media is opened again.
    public func relinkMedia(_ paths: [MediaRef.ID: String], name: String = "Relink Media") {
        guard !paths.isEmpty else { return }
        requestedMedia.subtract(paths.keys)       // so `syncMedia` prepares them again
        perform(name) { $0.relink(paths) }   // runs the owed v10 Scale step where probe info exists (H6)
        probeUnprobed(paths)
    }

    /// Called after every successful write of the project file, with exactly what was written.
    @ObservationIgnored public var onSaved: (@MainActor (Project) -> Void)?
    /// Called first whenever the session's project is replaced (open, new, close, import, revert): background work
    /// tied to the old project must stop.
    @ObservationIgnored public var onProjectReplaced: (@MainActor () -> Void)?
    /// App-wide media defaults (Settings > Media); the project's own policy overrides them. Decides whether a LUT from
    /// outside the project folder is copied into `Files/Library/`.
    @ObservationIgnored public var mediaPolicyDefaults: @MainActor () -> MediaPolicyDefaults = { MediaSettings.defaults }

    /// Applies a background change that is not an edit (a relink done by file placement, files the folder watcher
    /// added) to the current state and every undo and redo state: no undo step, redo stays, dirty is set when the
    /// current state changed. Undo and redo therefore never bring back a path that no longer exists.
    @discardableResult
    public func amendProject(_ change: (inout Project) -> Void) -> Bool {
        let before = history.current
        history.amendAll(change)
        let changed = history.current != before
        if changed { forceDirty = true; projectDidChange(); notify(.project) }
        return changed
    }

    /// Like `relinkMedia`, but history-neutral (see `amendProject`): the media is opened again from the new path.
    public func relinkMediaQuietly(_ paths: [MediaRef.ID: String]) {
        guard !paths.isEmpty else { return }
        requestedMedia.subtract(paths.keys)
        amendProject { $0.relink(paths) }
        probeUnprobed(paths)
    }

    /// Relinked media without probe info (Premiere-import placeholders, H6 pending-Scale media) is probed in the
    /// background (off the main actor) so it behaves like a fresh import: info, length, fingerprint, still clips, and the
    /// owed v10 Scale step are folded into every history state that points at the relinked file (Undo of the relink
    /// still gives the offline, unprobed state). Marks the project dirty.
    private func probeUnprobed(_ paths: [MediaRef.ID: String]) {
        // F7.10: media with chosen audio channels is probed too, so a map the new file cannot play is cleared.
        let mapped = project.media.filter { paths[$0.id] != nil && $0.info?.audio?.channelMap != nil }.map(\.id)
        // The sound info of every other relinked item with sound is refreshed when its file is not the one probed
        // before (another size or date): a file with another track layout counts other channels.
        let changed = project.media.filter { m in
            guard let path = paths[m.id], m.info?.audio != nil, !mapped.contains(m.id) else { return false }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
            return m.fingerprint.size != size || m.fingerprint.modified != (attrs[.modificationDate] as? Date)
        }.map(\.id)
        let ids = project.mediaAwaitingProbe(paths) + mapped + changed
        guard !ids.isEmpty else { return }
        let projectID = project.id
        let probe = mediaInfoProbe
        Task { [weak self] in
            var found: [MediaRef.ID: MediaInfo] = [:], prints: [MediaRef.ID: MediaFingerprint] = [:]
            for id in ids {
                guard let path = paths[id], let info = await probe(URL(fileURLWithPath: path)) else { continue }
                found[id] = info
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let size = (attrs[.size] as? NSNumber)?.int64Value {
                    prints[id] = MediaFingerprint(size: size, modified: attrs[.modificationDate] as? Date)
                }
            }
            guard !found.isEmpty, let self, self.project.id == projectID else { return }
            let before = self.history.current
            self.history.amendAll { p in
                let here = found.filter { id, _ in p.media.contains { $0.id == id && $0.path == paths[id] } }
                p.adoptProbedInfo(here, fingerprints: prints)
                p.fitAudioChannelMaps(to: here)
            }
            if self.history.current != before { self.forceDirty = true }   // amended undo/redo states alone save nothing new
            self.requestedMedia.subtract(found.keys)
            self.projectDidChange()
        }
    }

    /// Folds re-probed info of changed (growing or re-rendered) files into every history state: no undo step, marks the
    /// project dirty when something changed. Used by the growing-file poll (`growingFileTick`).
    func foldRefreshedProbes(_ found: [MediaRef.ID: (info: MediaInfo, stamp: MediaFileStamp?)]) {
        guard !found.isEmpty else { return }
        let before = history.current
        history.amendAll { p in
            for (id, hit) in found {
                guard let ref = p.media(id), ref.info != hit.info || ref.duration != hit.info.duration else { continue }
                _ = p.replaceMedia(id, with: GrowingFileProbe.refreshed(ref, info: hit.info, stamp: hit.stamp))
            }
        }
        if history.current != before { forceDirty = true }
        requestedMedia.subtract(found.keys)
        projectDidChange()
    }

    private func syncMedia() {
        // Always: the active sequence's sample rate can change without the media changing.
        // The resolver sees the project input color default applied (W9.3); the stored detection stays as it is.
        let rendering = project.mediaForRendering
        media.update(rendering, sampleRate: activeTimeline?.format.audioSampleRate)
        let infos = Dictionary(rendering.map { ($0.id, $0.info) }, uniquingKeysWith: { a, _ in a })
        if infos != renderedInfos {
            // The color resolver rebuilds a layer's pipeline when its media's color space changes; frames are cached
            // decoded (before color), so a redraw of the current frame is enough.
            renderedInfos = infos
            engine.redraw()
        }
        guard project.media != mediaSnapshot else { return }
        // Media whose file moved (relink to another path, or its undo): the engine reopens them (picture, playback audio, scrub audio).
        var oldPaths: [UUID: String] = [:]
        for m in mediaSnapshot { oldPaths[m.id] = m.path }
        var moved: Set<UUID> = []
        for m in project.media { if let old = oldPaths[m.id], old != m.path { moved.insert(m.id) } }
        // F7.3: a media item read with another pixel aspect (source settings, their undo, a probe that found the file's
        // tag): the engines hold the shape with the opened media, so they open it again and draw the frame anew.
        var oldShapes: [UUID: PixelAspect] = [:]
        for m in mediaSnapshot { oldShapes[m.id] = m.info?.video?.displayPixelAspect ?? .square }
        for m in project.media {
            if let old = oldShapes[m.id], old != (m.info?.video?.displayPixelAspect ?? .square) { moved.insert(m.id) }
        }
        // F7.10: other audio channels chosen for a media item: playback and scrub open its sound again.
        var oldMaps: [UUID: AudioChannelMap?] = [:]
        for m in mediaSnapshot { oldMaps[m.id] = .some(m.info?.audio?.channelMap) }
        for m in project.media { if let old = oldMaps[m.id], old != m.info?.audio?.channelMap { moved.insert(m.id) } }
        // Deinterlace of a media item changed (source settings, their undo, a probe that found the field order): the
        // engines decode it with another decoder, so they open it again.
        var oldFields: [UUID: FieldOrder?] = [:]
        for m in mediaSnapshot { oldFields[m.id] = .some(m.info?.video?.deinterlaceFieldOrder) }
        for m in project.media {
            if let old = oldFields[m.id], old != m.info?.video?.deinterlaceFieldOrder { moved.insert(m.id) }
        }
        if !moved.isEmpty {
            engine.mediaChanged(moved)
            renderCache?.mediaChanged()
            for a in auxiliaryEngines { a.engine?.mediaChanged(moved) }
        }
        mediaSnapshot = project.media
        autoProxy?.sync(project.media, projectID: project.id, activeTimeline: activeTimeline)
        let fresh = project.media.map(\.id).filter { requestedMedia.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        Task { [weak self, media] in
            await media.prepare(fresh)
            self?.notify(.media)
        }
    }

    func setError(_ m: String) { SQLog.error(m); lastError = SQL10n.localized(m); notify(.status) }
    public func clearError() { guard lastError != nil else { return }; lastError = nil; notify(.status) }

    /// The message of an error, in the language of the interface (the English text is the key).
    public static func message(for error: Error) -> String { SQL10n.localized(englishMessage(for: error)) }

    private static func englishMessage(for error: Error) -> String {
        switch error as? EditError {
        case .trackLocked: "The track is locked."
        case .collision: "Another clip is in the way."
        case .nestingCycle: nestingCycleMessage
        case .invalidFormat: "That sequence format is not valid."
        case .clipNotFound, .timelineNotFound: "The clip no longer exists."
        case .wrongTrackKind: "That clip does not belong on this track."
        case .emptyClip: "Nothing to edit."
        case .speedUnsupported: "Speed cannot be changed on that clip (titles and stills)."
        case .notACut: "Transitions go on a cut between two clips that touch, or on a clip edge."
        case .insufficientMedia: "Not enough media beyond the cut for a transition. Trim the clips to leave handles."
        case .notAGroup: "Select a group to ungroup."
        case .notNested: "Select a nested sequence to unnest."
        case .ungroupLosesLook: "Ungrouping would change how this group looks or sounds (its effects, speed or transitions, blend modes, dips or opacity over overlapping clips inside, track settings or markers inside)."
        case .notConvertible: "This clip cannot become a graphic without changing how it looks."
        case .noTrackToDelete: "Target the track to delete first (the lowest track of each kind stays)."
        default:
            switch error as? BakeError {
            case .notConvertible: "This effect cannot be converted to keyframes (it must be the last enabled transform effect, with Motion on, and no format variant or open shutter)."
            case .recordNotFound: "There is nothing to re-open."
            case .notNewest: "Only the most recent conversion can be re-opened."
            case nil: error.localizedDescription
            }
        }
    }

    // MARK: Selection

    public func select(clips: Set<Clip.ID>, captions: Set<CaptionItem.ID> = []) {
        settleFollowForManualSelection()
        setSelection(clips: clips, captions: captions)
    }

    public func setSelection(clips: Set<Clip.ID>, captions: Set<CaptionItem.ID>) {
        guard clips != selection || captions != captionSelection else { return }
        if !clips.isEmpty || !captions.isEmpty { selectedTransition = nil }
        selection = clips; captionSelection = captions
        pruneSelection()
        notify(.selection)
    }

    /// The clip Effect Controls shows: the one selected clip, or the video clip of a selected linked A/V pair.
    public var singleSelectedClip: Clip? {
        activeTimeline?.primaryClip(of: selection)
    }

    // MARK: Playhead and transport

    private var frameDuration: Time { activeTimeline?.frameDuration ?? Time(1, 30) }
    /// Frame grid of what the Program monitor shows: the source file's own rate in the source file view, else the sequence's.
    public var monitorFrameDuration: Time { colorSourceView?.timeline.frameDuration ?? frameDuration }

    /// Moves the playhead (frame-snapped, never before zero) and shows that frame. While the monitor shows a source
    /// file (`colorSourceView`) `t` is file time.
    public func seek(to t: Time) { seek(to: t, follow: .jump) }

    private func seek(to t: Time, follow: FollowTrigger) {
        if PlayProbe.enabled { PlayProbe.shared.note(.session) }
        if colorSourceView != nil { endSkim(); sourceViewMoved(to: t, engineSeek: true); return }
        let target = max(.zero, t.snapped(to: frameDuration))
        playhead = target
        engine.seek(to: target)
        if let s = skimTime { engine.scrub(to: s) }      // a skim goes on across a playhead move (edit keys, ripple follow)
        playheadMoved(follow)
        notify(.playhead)
    }

    /// Moves the sequence playhead (sequence time) even while the monitor shows a source file; the monitor then stays
    /// on its file frame.
    public func seekSequence(to t: Time) {
        guard colorSourceView != nil else { seek(to: t); return }
        playhead = max(.zero, t.snapped(to: frameDuration))
        playheadMoved(.jump)
        notify(.playhead)
    }

    /// Where the Program monitor is: file time while it shows a source file, else the playhead.
    public var monitorTime: Time { colorSourceView?.position ?? playhead }
    /// Length of what the Program monitor shows: the source file, else the active sequence.
    public var monitorDuration: Time { colorSourceView?.timeline.duration ?? activeTimeline?.duration ?? .zero }

    /// The source file view moved to file time `t` (clamped to its frames): the sequence playhead follows inside the
    /// clip (same source frame at the clip's speed, held at the clip's ends outside it).
    private func sourceViewMoved(to t: Time, engineSeek: Bool, scrub: Bool = false) {
        guard var v = colorSourceView else { return }
        let vfd = v.timeline.frameDuration
        let last = max(.zero, v.timeline.duration - vfd)
        let pos = min(max(.zero, t), last).flooredToFrame(vfd)
        v.position = pos
        colorSourceView = v
        if engineSeek { if scrub { engine.scrub(to: pos) } else { engine.seek(to: pos) } }
        if let c = activeTimeline?.tracks.lazy.compactMap({ $0.clips.first { $0.id == v.clipID } }).first, c.duration > .zero {
            let local = c.speedKeys != nil ? c.timelineTime(forSource: pos, frameDuration: frameDuration) - c.start
                : c.reversed ? c.speed.unscale(c.source.end - pos) - frameDuration : c.speed.unscale(pos - c.source.start)
            playhead = (c.start + min(max(.zero, local), c.duration - frameDuration)).snapped(to: frameDuration)
        }
        notify(.playhead)
    }

    /// The engine wraps a loop itself (`PlaybackEngine.loops`); stub engines leave it to the session.
    private var engineLoops: Bool { engine.loops }

    /// Playback of the source file view: stops at the file's end (or wraps with Loop), otherwise reports the position.
    private func sourceViewPlayed(to t: Time) {
        guard isPlaying, let v = colorSourceView else { return }
        let end = v.timeline.duration
        // A looping engine wraps by itself and never stops at the end.
        let atEnd = t + v.timeline.frameDuration >= end && engine.rate.isForward && !engineLoops
        if atEnd, bounds.loop { let r = engine.rate; engine.seek(to: .zero); engine.play(r); sourceViewMoved(to: .zero, engineSeek: false); return }
        if atEnd || engine.rate.isPaused {
            engine.pause(); isPlaying = false
            sourceViewMoved(to: atEnd ? end : t, engineSeek: false)
            notify(.transport)
            return
        }
        if t != v.position { sourceViewMoved(to: t, engineSeek: false) }
    }

    /// Reports the playhead without asking the engine to seek (the engine already is there).
    /// Only while playing: when paused the session's playhead is the truth and the engine's last presented frame
    /// may still lag behind a fast scrub. Playback stops at the end of the sequence.
    private func enginePositionChanged(_ t: Time) {
        if PlayProbe.enabled, isPlaying {
            let start = PlayProbe.now()
            defer { PlayProbe.shared.recordPositionCost(ms: (PlayProbe.now() - start) * 1000) }
            handleEnginePosition(t)
        } else {
            handleEnginePosition(t)
        }
    }

    private func handleEnginePosition(_ t: Time) {
        if colorSourceView != nil { sourceViewPlayed(to: t); return }
        guard isPlaying else { return }
        let end = activeTimeline?.duration ?? .zero
        // Stop at the sequence end: the last presented frame is one frame before `end`, and the engine may have stopped itself.
        let rate = engine.rate
        let looping = engineLoops                // the engine wraps by itself; its position just goes on
        switch bounds.action(at: t, rate: rate, frameDuration: frameDuration, duration: end) {
        case .wrap where looping: break
        case .wrap(let to):
            playhead = to
            engine.seek(to: to); engine.play(rate)
            notify(.playhead)
            return
        case .stop(let at) where bounds.range != nil:
            // Forward: the range end is exclusive, park on its last frame (the Out frame). Reverse stops at the In frame itself.
            let reverse = rate.isReverse
            engine.pause(); isPlaying = false; playhead = reverse ? at : max(.zero, at - frameDuration)
            notify([.playhead, .transport])
            return
        case .stopAndReturn(let back):
            engine.pause(); isPlaying = false
            bounds.range = nil
            seek(to: back)
            notify(.transport)
            return
        default: break
        }
        let atEnd = end > .zero && (t + frameDuration >= end) && engine.rate.isForward && !looping
        if atEnd || engine.rate.isPaused {
            // Paused already: the engine reports where a pause parked (the frame on the glass), and that is the playhead,
            // however close to the end it is.
            if !engine.rate.isPaused { engine.pause() }
            isPlaying = false
            playhead = atEnd ? end : t
            notify([.playhead, .transport])
            return
        }
        guard t != playhead else { return }
        playhead = t
        notify(.playhead)       // the selection does not follow while playing: `followTransportChanged` catches up at the stop
    }

    /// Play from the end of the sequence restarts at the start.
    private func restartIfAtEnd() {
        let end = monitorDuration
        if end > .zero, monitorTime + (colorSourceView == nil ? .zero : monitorFrameDuration) >= end { seek(to: .zero) }
    }

    /// A click in the timeline or ruler: playback stops (and stays stopped until Play / Space / L).
    public func stopPlayback() {
        guard isPlaying || !engine.rate.isPaused else { return }
        engine.pause()
        isPlaying = false
        notify(.transport)
    }

    public func beginScrub() { endSkim(); stopPlayback(); engine.beginScrub() }

    /// Time the Program monitor shows for the Fast Cut skimmer (the hover playhead), nil when it is not skimming. The
    /// playhead does not move; it is shown again when the skim ends.
    public private(set) var skimTime: Time?

    /// The edit point of the Q / W trim and Cmd+K cut keys: the skimmer's time while the hover playhead is visible, else
    /// the playhead. One resolver, so those commands cannot disagree.
    public var editPoint: Time { skimTime ?? playhead }

    /// The skimmer is at `t` (sequence time over the tracks) or gone (nil). Rides the scrub path of the engine (keyframe
    /// decode, grains, exact frame after a rest) without moving the playhead. Not while playing or while the monitor
    /// shows a source file: such a skim ends.
    public func skim(to t: Time?) {
        guard let t, colorSourceView == nil, !isPlaying, engine.rate.isPaused else { endSkim(); return }
        let target = max(.zero, t.snapped(to: frameDuration))
        if skimTime == nil { engine.beginScrub() }
        guard target != skimTime else { return }
        skimTime = target
        engine.scrub(to: target)
    }

    /// Ends a skim: the monitor returns to the playhead frame.
    private func endSkim() {
        guard skimTime != nil else { return }
        skimTime = nil
        engine.endScrub()
        engine.seek(to: playhead)
    }
    public func scrub(to t: Time) {
        if PlayProbe.enabled { PlayProbe.shared.note(.session) }
        if colorSourceView != nil { sourceViewMoved(to: t, engineSeek: true, scrub: true); return }
        let target = max(.zero, t.snapped(to: frameDuration))
        playhead = target
        engine.scrub(to: target)
        playheadMoved(.scrub)
        notify(.playhead)
    }
    public func endScrub() { engine.endScrub(); flushFollowSelection() }

    /// Preview speed of Space (0.5x to 10x); preview only, export never reads it. Reset to 1x when the project closes.
    public internal(set) var previewRate = PreviewRate.normal

    /// Plays at the new speed from now on; while playing forward the running playback switches at once (the shuttle path).
    public func setPreviewRate(_ r: PreviewRate) {
        guard r != previewRate else { return }
        previewRate = r
        if isPlaying, engine.rate.isForward {
            apply(shuttle: .setRate(r.rate))
        }
    }

    public func playPause() {
        endSkim()
        if ProcessInfo.processInfo.environment["SQ_KEYLOG"] == "1" { NSLog("SQKEY session.playPause isPlaying=\(isPlaying) rate=\(engine.rate)") }
        if isPlaying || !engine.rate.isPaused { engine.pause(); isPlaying = false } else {
            let t0 = PlayProbe.enabled ? PlayProbe.now() : 0
            engine.clearLookPreview(); bounds.range = nil; restartIfAtEnd()
            let t1 = PlayProbe.enabled ? PlayProbe.now() : 0
            engine.play(previewRate.rate); isPlaying = true
            if PlayProbe.enabled { PlayProbe.shared.stage("play prep %.1f engine.play %.1f", (t1 - t0) * 1000, (PlayProbe.now() - t1) * 1000) }
        }
        let t2 = PlayProbe.enabled ? PlayProbe.now() : 0
        notify(.transport)
        if PlayProbe.enabled { PlayProbe.shared.stage("notify(.transport) %.1f", (PlayProbe.now() - t2) * 1000) }
    }

    public func apply(shuttle action: ShuttleAction) {
        switch action {
        case .setRate(let r):
            if r.isPaused { engine.pause(); isPlaying = false } else { engine.clearLookPreview(); bounds.range = nil; if r.isForward { restartIfAtEnd() }; engine.play(r); isPlaying = true }
            notify(.transport)
        case .step(let n): stepFrames(n)
        case .none: break
        }
    }

    public func stepFrames(_ n: Int) {
        endSkim()
        if isPlaying { engine.pause(); isPlaying = false; notify(.transport) }
        seek(to: monitorTime + monitorFrameDuration * Int64(n), follow: .step)
    }

    public func goToStart() { seek(to: .zero) }
    /// Parks on the last frame (like Source End), not one frame past it (MON-16).
    public func goToEnd() { seek(to: max(.zero, monitorDuration - monitorFrameDuration)) }

    /// Edit points Up/Down jump between, picked by the edit target rule (`Timeline.editTargets`). In the source file
    /// view: the clip's In and Out in the file.
    private func jumpPoints() -> [Time] {
        if let r = sourceViewClipRange { return [r.start, r.end] }
        return activeTimeline?.editPoints(selection: selection) ?? []
    }

    public func goToNextEditPoint() {
        if let t = jumpPoints().first(where: { $0 > monitorTime }) { seek(to: t) }
    }

    public func goToPreviousEditPoint() {
        if let t = jumpPoints().last(where: { $0 < monitorTime }) { seek(to: t) }
    }

    /// The used part of the clip in its source file (file time) while the monitor shows the file.
    public var sourceViewClipRange: TimeRange? {
        guard let v = colorSourceView,
              let c = activeTimeline?.tracks.lazy.compactMap({ $0.clips.first { $0.id == v.clipID } }).first else { return nil }
        return c.source
    }

    /// In the source file view In / Out are the clip's In and Out in the file.
    public func goToIn() {
        if colorSourceView != nil { if let r = sourceViewClipRange { seek(to: r.start) }; return }
        if let io = activeTimeline?.inOut { seek(to: io.start) }
    }
    /// Out is stored one frame past its frame: go to the marked (last included) frame.
    public func goToOut() {
        if colorSourceView != nil { if let r = sourceViewClipRange { seek(to: max(r.start, r.end - monitorFrameDuration)) }; return }
        // In only: the Out follows the current sequence end (`exportRange`), not the end when In was marked.
        if let io = activeTimeline?.exportRange { seek(to: max(io.start, io.end - frameDuration)) }
    }

    // MARK: Timeline commands

    /// Delete (lift, leaves a gap) or ripple delete of the selected clips and captions.
    public func deleteSelection(ripple: Bool, undoName: String? = nil) {
        guard !selection.isEmpty || !captionSelection.isEmpty else { return }
        var edits: [TimelineEdit] = []
        if !selection.isEmpty {
            let ids = Array(selection)
            if let t = activeTimeline {
                edits = TimelineEdit.scoped([ripple ? .rippleDelete(ids) : .lift(ids)], to: selection, in: t)
                // Fast Cut: Delete closes the main track (attached clips go along unless ` is held); the Shift+Delete
                // spacer is `replaceSelectionWithSpacer`.
                if t.isFastCut { edits = TimelineEdit.fastCut(edits, in: t, keepAttached: keepAttachedHeld) }
            }
        }
        edits += captionSelection.sorted { $0.uuidString < $1.uuidString }.map { .deleteCaption($0) }
        let name = undoName ?? (ripple && !selection.isEmpty ? "Ripple Delete" : "Delete")
        var clamp: String?
        if attemptRipple(name, { t in
            for e in edits {
                if case .rippleDelete(let ids) = e { let o = try t.rippleDeleteOutcome(ids).outcome; clamp = t.clampMessage(o) }
                else { try e.apply(to: &t) }
            }
        }) {
            selection = []; captionSelection = []
            notify(.selection)
            if let clamp { setError("Ripple Delete \(clamp)") }
        }
    }

    /// Cmd+K: cuts at the playhead on the tracks the edit target rule picks (selection > targeted > all, locked
    /// tracks skipped); `allTracks` (Cmd+Shift+K) cuts every unlocked track.
    public func addEditAtPlayhead(allTracks: Bool = false) {
        guard activeTimeline != nil else { return }
        let at = editPoint, sel = selection
        var cut: [Clip.ID] = []
        let done = attempt(allTracks ? "Add Edit to All Tracks" : "Add Edit") {
            // Fast Cut without a selection: the main clip under the playhead and its sound (attached clips go with the
            // half that holds their point); Normal: the edit target rule.
            cut = allTracks ? try $0.magneticAddEditAll(at: at) : try $0.magneticAddEdit(at: at, selection: sel)
        }
        guard done, !cut.isEmpty else { return }
        // A second cut after a first one selects the piece between the two, so Delete / Shift+Delete finishes the job.
        // Only right after the previous cut in this sequence: an undo, another edit or a sequence switch in between ends it.
        if let previous = lastCutPoint, previous.timeline == activeTimelineID, previous.depth + 1 == history.undoDepth,
           previous.time != at, let t = activeTimeline {
            let piece = t.clips(between: previous.time, and: at)
            if !piece.isEmpty { select(clips: Set(piece)) }
        }
        lastCutPoint = activeTimelineID.map { (timeline: $0, time: at, depth: history.undoDepth) }
    }

    /// Cut Out (Shift+X): the first press marks the start at the playhead, the second removes start..playhead from the
    /// targeted (else every unlocked) tracks and closes the gap, in ONE undo step. The playhead lands on the join.
    public func cutOut() {
        guard let t = activeTimeline else { return }
        let at = playhead
        // The pending start only counts while its In mark is still there (cleared marks cancel a half-done cut).
        let pending = cutOutStart.flatMap { s in t.inOut?.start == s ? s : nil }
        switch Timeline.cutOutStep(pending: pending, playhead: at) {
        case .markStart(let s):
            guard attempt("Cut Out Start", { $0.markIn(at: s) }) else { return }
            cutOutStart = s
        case .extract(let range):
            let ids = rangeTracks(t)
            var clamp: String?
            // attemptRipple puts the playhead on the join (sequence time) and remembers it with the undo step.
            attemptRipple("Cut Out") { t in
                let o = try t.magneticExtract(range, tracks: ids).outcome
                clamp = t.clampMessage(o)
                t.setMarkedRange(nil)
            }
            cutOutStart = nil
            if let clamp { setError("Cut Out \(clamp)") }
        }
    }

    /// One key to close the gap under the playhead on every unlocked track that has one (ripple).
    @discardableResult
    public func closeGapAtPlayhead() -> Bool {
        guard let t = activeTimeline else { return false }
        let at = playhead
        // Fast Cut: only the main track has gaps that close (spacers); attached clips never ripple.
        if t.isFastCut {
            guard let main = t.mainTrackID, t.gap(on: main, at: at) != nil else { setError("No spacer at the playhead."); return false }
            let keep = keepAttachedHeld
            return attemptRipple("Delete Spacer") { _ = try $0.deleteSpacer(at: at, keepAttached: keep) }
        }
        guard t.tracks.contains(where: { !$0.isLocked && t.gap(on: $0.id, at: at) != nil }) else {
            setError("No gap at the playhead.")
            return false
        }
        return attemptRipple("Close Gap") { _ = try $0.closeGapsAtPlayhead(at: at) }
    }

    /// J Cut / L Cut on plain keys: the audio edit of the nearest cut ahead of (J) or behind (L) the playhead moves to it.
    @discardableResult
    public func jlCutToPlayhead(_ kind: JLCut) -> Bool {
        guard let t = activeTimeline else { return false }
        let at = playhead
        var probe = t
        do { _ = try probe.splitEditJL(kind, at: at) } catch EditError.clipNotFound {
            setError(kind == .jCut ? "No audio cut ahead of the playhead." : "No audio cut behind the playhead.")
            return false
        } catch { /* locked or colliding: the real attempt reports it */ }
        return attempt(kind == .jCut ? "J Cut" : "L Cut") { _ = try $0.splitEditJL(kind, at: at) }
    }

    /// Q (`.head`) / W (`.tail`): ripple-trims the clip under the playhead so that edge lands on it.
    public func rippleTrimToPlayhead(_ edge: ClipEdge) {
        let at = editPoint, keep = keepAttachedHeld
        var clamp: String?
        // Head trim: the picture under the playhead slid back by the cut, so the playhead goes with it and lands on
        // the new edit point (Premiere, `attemptRipple`). A tail trim leaves the picture where it was.
        attemptRipple(edge == .head ? "Ripple Trim Previous Edit" : "Ripple Trim Next Edit") {
            // Q/W: all unlocked tracks; Fast Cut: the main track, attached clips follow (` held: they stay).
            let r = try $0.magneticRippleTrimToPlayhead(edge, at: at, tracks: Self.playheadTrimTracks(in: $0), keepAttached: keep)
            clamp = $0.clampMessage(r.outcome)
        }
        if let clamp { setError("Trim \(clamp)") }
    }

    /// Tracks a range edit applies to: the targeted tracks, else every unlocked track.
    private func rangeTracks(_ t: Timeline) -> [Track.ID] {
        let targeted = t.tracks.filter { $0.isTargeted && !$0.isLocked }.map(\.id)
        return targeted.isEmpty ? t.tracks.filter { !$0.isLocked }.map(\.id) : targeted
    }

    /// Removes the In/Out range and leaves a gap.
    public func liftRange() {
        guard let t = activeTimeline else { return }
        guard let io = t.exportRange, !io.isEmpty else { setError("Set In and Out first."); return }
        let ids = rangeTracks(t)
        // Fast Cut with the main track targeted: a spacer on V1, attached clips stay (`magneticClearRange`).
        attemptRipple("Clear Range") { try $0.magneticClearRange(io, tracks: ids) }
    }

    /// Bleep: mutes the In/Out range (else the span of the selected clips) on the targeted audio tracks and lays the tone
    /// over it. One undo step.
    public func bleepRange() {
        guard let t = activeTimeline else { return }
        var range = t.exportRange
        if range == nil || range!.isEmpty {
            let picked = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
            if let lo = picked.map(\.start).min(), let hi = picked.map({ $0.timeline.end }).max() { range = TimeRange(start: lo, end: hi) }
        }
        guard let range, !range.isEmpty else { setError("Set In and Out, or select a clip, to bleep."); return }
        let ids = rangeTracks(t).filter { t.track($0)?.kind == .audio && t.track($0)?.name != Timeline.bleepTrackName }
        guard !ids.isEmpty else { setError("There is no audio track to bleep."); return }
        // Nothing sounds there any more (a repeated Bleep): a short status line, not the generic refusal.
        if Self.bleepFailure(t, range, ids) == .emptyClip { setError("Nothing left to bleep there."); return }
        attempt("Bleep") { try $0.bleep(range, tracks: ids) }
    }

    private static func bleepFailure(_ t: Timeline, _ range: TimeRange, _ ids: [Track.ID]) -> EditError? {
        var probe = t
        do { _ = try probe.bleep(range, tracks: ids); return nil } catch { return error as? EditError }
    }

    /// Changes frequency and level of a tone clip. One undo step.
    public func setTone(_ id: Clip.ID, _ spec: ToneSpec) {
        do { try perform("Tone Settings") { try $0.setTone(clipID: id, spec) } } catch { setError(Self.message(for: error)) }
    }

    /// The tone of a selected tone clip, if exactly that is selected.
    public var selectedTone: (id: Clip.ID, spec: ToneSpec)? {
        guard selection.count == 1, let id = selection.first,
              let spec = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.tone else { return nil }
        return (id, spec)
    }

    /// Removes the In/Out range and closes the gap.
    public func extractRange() {
        guard let t = activeTimeline else { return }
        guard let io = t.exportRange, !io.isEmpty else { setError("Set In and Out first."); return }
        let ids = rangeTracks(t)
        var clamp: String?
        attemptRipple("Delete Range") { t in let o = try t.magneticExtract(io, tracks: ids).outcome; clamp = t.clampMessage(o) }
        if let clamp { setError("Delete Range \(clamp)") }
    }

    /// Places media items one after another starting at `time` (default: the playhead): video on `track` (else the
    /// targeted or first video track), linked audio on the mirrored audio track (V2 -> A2, created when missing,
    /// see `Timeline.dropTargets`). Source marks from the Project panel are honored. Into an empty sequence that was
    /// never configured (`formatLocked == false`) the first item sets the sequence format (size and frame rate).
    /// `newTrack`: a ghost-track drop; a track of that kind is created first (same undo step) and receives the drop.
    /// `patched` (Insert / Overwrite keys from the Project panel): without a track or ghost, the items land on the
    /// source patch (`sourcePatch`) instead of the drop rule; Place on Top then honors a disconnected video patch.
    /// Returns false when nothing could be placed (unknown ID, refused edit).
    @discardableResult
    public func placeMedia(_ ids: [MediaRef.ID], at time: Time? = nil, videoTrack: Track.ID? = nil,
                           mode: ThreePointMode = .overwrite, adoptFormat: Bool = true, streams: SourceStreams = .both,
                           newTrack: TrackKind? = nil, placeOnTop: Bool = false, backtimed: Bool = false, patched: Bool = false) -> Bool {
        // No sequence yet (fresh project without one): the first media makes one, unconfigured so it adopts the media's size.
        if activeTimeline == nil, ids.contains(where: { project.media($0) != nil }) {
            var empty = Timeline(name: suggestedSequenceName, format: SequenceFormat(frameDuration: Time(1001, 30000)),
                                 tracks: Timeline.defaultTracks(), formatLocked: false)
            empty.setEditMode(newSequenceEditMode)
            perform("New Sequence") { $0.timelines.append(empty); $0.normalizeBins() }
            setActiveTimeline(empty.id)
        }
        guard let t = activeTimeline else { return false }
        if backtimed, !(placeOnTop && t.isFastCut) { setError("Attach Backtimed needs a Fast Cut sequence."); return false }
        if backtimed, t.mainTrackEnd <= .zero { setError("Attach Backtimed needs a clip on the main track."); return false }
        let refs = ids.compactMap { project.media($0) }.filter { ($0.info?.duration ?? $0.duration) != nil }
        guard !refs.isEmpty else { return false }
        var adopts = adoptFormat && !t.formatLocked && t.tracks.allSatisfy { $0.clips.isEmpty }
        if adopts, let ask = confirmFormatChange, let proposed = formatMismatch(placing: ids) {
            adopts = ask(t.format, proposed)
        }
        // A ghost drop must put something on the new track: refuse when the chosen streams or the media offer nothing for it.
        if let kind = newTrack {
            let usable = kind == .video ? streams.includesVideo : streams.includesAudio
            let offered = refs.contains { kind == .video ? ($0.info?.video != nil || $0.info == nil) : $0.info?.audio != nil }
            guard usable, offered else { return false }
        }
        let requested0 = time ?? playhead
        let marks = project.sourceMarks
        let patch: SourcePatch? = patched && videoTrack == nil && newTrack == nil ? sourcePatch : nil
        // Whole frames of the sequence, as placed (`sourceEditPlan`): the run length of Place on Top / Attach Backtimed.
        func runLengths(_ fd: Time) -> [Time] {
            refs.compactMap { ref in
                let total = ref.info?.duration ?? ref.duration ?? .zero
                if ref.info?.isStill == true { return total.snapped(to: fd) }
                let m = marks[ref.id].flatMap { $0.range == nil ? nil : $0 } ?? SourceMarks()
                return Timeline.sourceEditPlan(sourceMarks: m, total: total, sequenceIn: nil, sequenceOut: nil, playhead: .zero,
                                               frameDuration: fd, isStill: false)?.source.duration
            }
        }
        let label = backtimed ? "Attach Backtimed" : mode == .insert ? "Insert" : "Overwrite"
        let existing = Set(t.tracks.flatMap { $0.clips.map(\.id) })
        defer { selectNewClips(since: existing) }
        let done = attempt(label) { tl in
            var videoTrack = videoTrack, streams = streams
            let requested = requested0
            if placeOnTop, let patch, !patch.video.isConnected { throw EditError.clipNotFound }
            // Attach Backtimed never lands on the main track: the run ends at the playhead, at most at the main track's end.
            // Nothing before the sequence start (or no main clip) leaves nothing to attach to: no undo step.
            if backtimed, min(requested.snapped(to: tl.frameDuration), tl.mainTrackEnd) <= .zero { throw EditError.emptyClip }
            // Dropped on a ghost track: the track is created inside this same undo step. Audio ghost: audio only.
            if let kind = newTrack {
                let id = tl.addTrack(kind: kind)
                videoTrack = id
                if kind == .audio { streams = .audioOnly }
            }
            if adopts, let v = refs[0].info?.video {
                // Upright (display) size: a portrait phone clip makes a portrait sequence. A still keeps the frame rate.
                let still = refs[0].info?.isStill == true
                tl.format = SequenceFormat(width: v.displayWidth, height: v.displayHeight,
                                           frameDuration: still ? tl.format.frameDuration : v.nominalFrameDuration,
                                           audioSampleRate: tl.format.audioSampleRate).sanitized(fallback: tl.format)
            }
            var at = requested.snapped(to: tl.frameDuration)   // after a format change: the new frame grid
            // Place on Top: the track above the topmost occupied one over the whole run (video only, one undo step).
            // Picked after a format change, so the lengths are on the new frame grid.
            if placeOnTop, newTrack == nil {
                let length = runLengths(tl.frameDuration).reduce(Time.zero, +)
                let end = requested.snapped(to: tl.frameDuration)
                let range = backtimed ? TimeRange(start: max(min(end, tl.mainTrackEnd) - length, .zero), end: min(end, tl.mainTrackEnd))
                                      : TimeRange(start: end, duration: length)
                switch tl.placeOnTopTarget(in: range) {
                case .existing(let id): videoTrack = id
                case .newTrack: videoTrack = tl.addTrack(kind: .video)
                }
                streams = .videoOnly
            }
            // Attach Backtimed: the items form one run that ends on the playhead, in selection order; each ends where the
            // next one starts. Items entirely before the sequence start drop out.
            let backEnd = min(requested0.snapped(to: tl.frameDuration), tl.mainTrackEnd)
            var endsAt: [Time] = []
            if backtimed {
                var e = backEnd
                for len in runLengths(tl.frameDuration).reversed() { endsAt.insert(e, at: 0); e = e - len }
            }
            for (index, ref) in refs.enumerated() {
                // Scale is relative to source pixels: a new clip is placed at the fit value ("Set to Frame Size"), so a
                // clip of another size shows whole instead of cropped. 1 for the clip that set the sequence format.
                let fit = ref.info?.video.map { tl.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
                let total = ref.info?.duration ?? ref.duration ?? .zero
                let still = ref.info?.isStill == true
                // Whole frames of the sequence (like `sourceEdit`): a 23.976 source in a 29.97 sequence must not leave
                // off-grid ends or start the next item off the grid. Stills: default length, no source marks.
                guard let plan = Timeline.sourceEditPlan(sourceMarks: still ? SourceMarks() : (marks[ref.id].flatMap { $0.range == nil ? nil : $0 } ?? SourceMarks()), total: total,
                                                         sequenceIn: nil, sequenceOut: nil, playhead: at,
                                                         frameDuration: tl.frameDuration, isStill: still) else { throw EditError.emptyClip }
                let source = still ? TimeRange(start: .zero, duration: total.snapped(to: tl.frameDuration)) : plan.source   // stills: default length, whole frames
                let hasVideo = (ref.info?.video != nil || ref.info == nil) && streams.includesVideo
                let hasAudio = ref.info?.audio != nil && streams.includesAudio
                var targets: [Track.ID] = []
                if let patch, !placeOnTop {
                    guard let found = tl.sourcePatchTargets(patch, hasVideo: hasVideo, hasAudio: hasAudio) else { throw EditError.clipNotFound }
                    targets = found
                } else {
                    let d = tl.dropTargets(pointer: videoTrack, hasVideo: hasVideo, hasAudio: hasAudio)
                    if let v = d.video { targets.append(v) }
                    if let a = d.audio { targets.append(a) } else if let n = d.newAudioOrdinal { targets.append(tl.ensureAudioTrack(atOrdinal: n)) }
                }
                if backtimed, index >= endsAt.count || endsAt[index] <= .zero { continue }
                try tl.threePointEdit(source: source, media: ref.id, name: ref.name, mediaDuration: still ? nil : total,
                                      isStill: still, initialScale: fit, targets: targets, at: backtimed ? endsAt[index] : at, mode: mode,
                                      backtimed: backtimed)
                at = (at + source.duration).snapped(to: tl.frameDuration)
            }
        }
        return done
    }

    /// What was just added is exactly the selection (a drop, Insert, Overwrite, a Graphic): nothing else stays selected.
    func selectNewClips(since existing: Set<Clip.ID>) {
        guard let t = activeTimeline else { return }
        let added = Set(t.tracks.flatMap { $0.clips.map(\.id) }).subtracting(existing)
        if !added.isEmpty { select(clips: added) }
    }

    /// Why `ids` cannot be nested in the active sequence (it is one of them, or one of them contains it); nil = allowed.
    public func sequenceNestingRefusal(_ ids: [Timeline.ID]) -> String? {
        guard let host = activeTimelineID else { return nil }
        return ids.contains { project.wouldCreateCycle(nesting: $0, in: host) } ? Self.nestingCycleMessage : nil
    }

    public nonisolated static let nestingCycleMessage = "A sequence cannot contain itself, nor a sequence that contains it."

    /// Drops / Insert / Overwrite of whole sequences: each becomes a nested clip (video + linked audio) on the active
    /// sequence, one after another from `time` (default: the playhead), one undo step. Refusals set the status message.
    @discardableResult
    public func placeSequences(_ ids: [Timeline.ID], at time: Time? = nil, videoTrack: Track.ID? = nil,
                               mode: ThreePointMode = .overwrite, newTrack: TrackKind? = nil) -> Bool {
        guard let host = activeTimelineID, !ids.isEmpty else { return false }
        let at = time ?? playhead
        let before = history.current
        do {
            // An Angles sequence is always placed as one clip: its angles are never laid out as single clips.
            let asClips = placeSequencesAsClips && !ids.contains { project.timeline($0)?.angles != nil }
            try perform(mode == .insert ? "Insert" : "Overwrite") {
                if asClips {
                    try $0.placeSequenceClips(ids, in: host, at: at, videoTrack: videoTrack, newTrack: newTrack, mode: mode)
                } else {
                    try $0.placeSequences(ids, in: host, at: at, videoTrack: videoTrack, newTrack: newTrack, mode: mode)
                }
            }
        } catch {
            setError(error as? EditError == .emptyClip ? "That sequence is empty." : Self.message(for: error)); return false
        }
        return history.current != before
    }

    /// The format the first of `ids` would give an empty, never configured sequence, when it differs from the current one
    /// (size or frame rate). nil when `placeMedia` would not change the sequence format. The app asks the user first
    /// ("change sequence settings / keep existing"), then places with `adoptFormat` accordingly.
    public func formatMismatch(placing ids: [MediaRef.ID]) -> SequenceFormat? {
        guard let t = activeTimeline, !t.formatLocked, t.tracks.allSatisfy({ $0.clips.isEmpty }),
              let ref = ids.compactMap({ project.media($0) }).first(where: { ($0.info?.duration ?? $0.duration) != nil }),
              let v = ref.info?.video else { return nil }
        let still = ref.info?.isStill == true
        let f = SequenceFormat(width: v.displayWidth, height: v.displayHeight,
                               frameDuration: still ? t.format.frameDuration : v.nominalFrameDuration,
                               audioSampleRate: t.format.audioSampleRate).sanitized(fallback: t.format)
        return f == t.format ? nil : f
    }

    /// Name the New Sequence dialogs suggest: the first "Sequence NN" no sequence has (deleting one never causes a duplicate).
    public var suggestedSequenceName: String {
        let names = Set(project.timelines.map(\.name))
        var n = project.timelines.count + 1
        while names.contains(String(format: "Sequence %02d", n)) { n += 1 }
        return String(format: "Sequence %02d", n)
    }

    /// New empty sequence in the active sequence's format (V1-V3, A1-A3); it becomes the active one.
    @discardableResult
    public func addSequence(name: String? = nil, format: SequenceFormat? = nil, deliveryTarget: DeliveryTarget? = nil) -> Timeline.ID {
        let format = format ?? activeTimeline?.format ?? SequenceFormat(frameDuration: Time(1001, 30000))
        let names = Set(project.timelines.map(\.name))
        var n = project.timelines.count + 1
        while names.contains(String(format: "Sequence %02d", n)) { n += 1 }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var t = Timeline(name: trimmed.isEmpty ? String(format: "Sequence %02d", n) : trimmed, format: format,
                         tracks: Timeline.defaultTracks())
        t.deliveryTarget = deliveryTarget
        t.setEditMode(newSequenceEditMode)
        perform("New Sequence") { p in
            p.timelines.append(t)
            p.normalizeBins()
        }
        setActiveTimeline(t.id)
        return t.id
    }

    /// New Sequence from Template: the template's format, tracks, variants and graphics as a fresh sequence (one undo step).
    @discardableResult
    public func addSequence(from template: ProjectTemplate, name: String? = nil) -> Timeline.ID {
        let names = Set(project.timelines.map(\.name))
        var n = project.timelines.count + 1
        while names.contains(String(format: "Sequence %02d", n)) { n += 1 }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var t = template.makeSequence(name: trimmed.isEmpty ? String(format: "Sequence %02d", n) : trimmed)
        t.setEditMode(newSequenceEditMode)
        perform("New Sequence") { p in
            p.timelines.append(t)
            p.normalizeBins()
        }
        setActiveTimeline(t.id)
        return t.id
    }

    /// Sequence Settings: one undo step. Clips keep their scale and position; only the canvas / rates change.
    @discardableResult
    public func setSequenceFormat(_ format: SequenceFormat, deliveryTarget: DeliveryTarget? = nil) -> Bool {
        guard let id = activeTimelineID, activeTimeline?.format != format || activeTimeline?.deliveryTarget != deliveryTarget else { return false }
        do { try perform("Sequence Settings") { try $0.setFormat(format, of: id); try $0.setDeliveryTarget(deliveryTarget, of: id) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    /// Premiere "Set to Frame Size": Scale of the selected picture clips (or `ids`) becomes the value at which the whole
    /// picture fits the sequence frame (keyframes of Scale are removed, see `Project.setToFrameSize`). Premiere's
    /// "Scale to Frame Size" differs only by resampling, which we do not do (DECISIONS). One undo step.
    @discardableResult
    public func setToFrameSize(_ ids: Set<Clip.ID>? = nil) -> Bool { writeFrameScale(ids, fill: false) }

    /// Premiere "Set to Fill Frame": like `setToFrameSize`, but the picture covers the whole frame (edges cropped).
    @discardableResult
    public func setToFillFrame(_ ids: Set<Clip.ID>? = nil) -> Bool { writeFrameScale(ids, fill: true) }

    private func writeFrameScale(_ ids: Set<Clip.ID>?, fill: Bool) -> Bool {
        guard let tid = activeTimelineID else { return false }
        let targets = ids ?? selection
        guard !targets.isEmpty else { return false }
        var trial = project
        do {
            let n = fill ? try trial.setToFillFrame(targets, in: tid) : try trial.setToFrameSize(targets, in: tid)
            guard n > 0 else { return false }     // already at the value
            try perform(fill ? "Fill Frame" : "Fit to Frame") { $0 = trial }
        } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    /// I: In at the playhead. Like Out, In includes its own frame (Premiere); a later Out stays, an earlier one moves
    /// to the end of the sequence.
    public func markIn() {
        guard activeTimeline != nil else { return }
        let at = playhead
        attempt("Mark In") { $0.markIn(at: at) }
    }

    /// O: the frame under the playhead is the last frame inside the range (In = 10, Out = 20 is 11 frames); allowed at
    /// frame 0. With no In set, an edit placed from this range is back-timed (`Timeline.sourceEditPlacement`).
    public func markOut() {
        guard activeTimeline != nil else { return }
        let at = playhead
        attempt("Mark Out") { $0.markOut(at: at) }
    }

    /// X: In/Out around the clips under the playhead on the tracks the edit target rule picks.
    public func markClip() {
        guard let t = activeTimeline else { return }
        guard let range = t.markClipRange(at: playhead, selection: selection) else { return }
        attempt("Mark Clip") { $0.setMarkedRange(range) }
    }

    public func clearInOut() {
        guard activeTimeline?.inOut != nil else { return }
        attempt("Clear In and Out") { $0.setMarkedRange(nil) }
    }

    public func addMarkerAtPlayhead() {
        let at = playhead
        attempt("Add Marker") { _ = $0.addMarker(at: at) }
    }

    // MARK: Files

    private func snapshotForSave() -> (base: Project, file: Project) {
        var p = history.current
        p.activeTimeline = activeTimelineID
        p.activeVariants = activeVariants.filter { p.timeline($0.key)?.variant($0.value) != nil }
        return (history.current, p)
    }

    /// Saves to the current file. `.noFileURL` for an untitled project (use `saveAs`).
    public func save() async throws {
        guard let url = fileURL else { throw SaveError.noFileURL }
        // A project opened from a legacy `.ssproj` is written to a sibling `.sqproj`; the old file stays untouched.
        if ProjectFile.isLegacyURL(url) {
            let target = ProjectFile.convertedURL(for: url)
            try await saveAs(to: target)
            setError(SQL10n.format("Saved as “%@”; the old “%@” was left in place.", target.lastPathComponent, url.lastPathComponent))
            return
        }
        try await write(to: url)
    }

    public func saveAs(to url: URL) async throws {
        try await write(to: url)
        fileURL = url
        media.setProjectFolder(MediaManagement.projectFolder(forProjectAt: url))
        beginMarker()
        notify(.project)
    }

    /// Save a Copy: writes the project to `url` as a new document (own id, so it never shares autosave versions or crash
    /// records with this one) and changes nothing here: the open project keeps its file, its undo history and its dirty
    /// state. A copy never watches a folder. The same file as the open one is a plain save.
    public func saveCopy(to url: URL) async throws {
        if let current = fileURL, current.standardizedFileURL == url.standardizedFileURL, !ProjectFile.isLegacyURL(current) {
            try await save()
            return
        }
        let projectID = project.id
        let swaps = await collectLUTs(forSaveAt: url)
        guard project.id == projectID else { throw SaveError.projectChanged }
        var file = snapshotForSave().file
        file.replaceLUTPaths { swaps[$0] }
        file.id = UUID()
        file.mediaPolicy?.watchFolder = false
        do { try protectSalvagedOriginal(writingTo: url); try await saveQueue.write(file, to: url) } catch { setError("Could not save a copy:\(error.localizedDescription)"); throw error }
    }

    private func write(to url: URL) async throws {
        let projectID = project.id
        let swaps = await collectLUTs(forSaveAt: url)
        // The project was replaced while the LUTs were copied: this save belongs to the old one and writes nothing.
        guard project.id == projectID else { throw SaveError.projectChanged }
        let (base, snapshot) = snapshotForSave()
        var file = snapshot
        file.replaceLUTPaths { swaps[$0] }                  // the file holds the copies; the open project follows after the write
        do { try protectSalvagedOriginal(writingTo: url); try await saveQueue.write(file, to: url) } catch { setError("Could not save:\(error.localizedDescription)"); throw error }
        // The user switched projects while the file was written: nothing of this save applies to the new one.
        guard project.id == projectID else { throw SaveError.projectChanged }
        // The written state is the saved one (undo during the write leaves the project dirty); edits keep it dirty.
        let unchanged = history.current == base
        history.markSaved(base)
        let dirtyBefore = forceDirty
        if !swaps.isEmpty { amendProject { $0.replaceLUTPaths { swaps[$0] } } }   // also moves the saved state along
        // The amend is not an edit: undo or edits during the write are tracked by the history, so returning to
        // the written state reads as clean again.
        forceDirty = unchanged ? false : dirtyBefore
        notify(.project)
        onSaved?(file)
    }

    /// Replaces the session's project with the file's. The previous project's crash marker ends.
    /// A file that does not decode as a whole opens with the damaged parts dropped (`ProjectFile.readSalvaging`): the result
    /// is returned for the caller's notice, the project opens unsaved with no file (Save asks for a place, the original file is
    /// never overwritten) and its media folder is still the original's.
    @discardableResult
    public func open(url: URL) async throws -> ProjectSalvageReport? {
        let p: Project
        do { p = try await saveQueue.read(url) } catch {
            if case ProjectFileError.corrupt = error, let s = try? await saveQueue.readSalvaging(url), !s.report.isEmpty {
                replace(with: s.project, fileURL: nil, dirty: true, mediaFolderOf: url)
                salvagedFrom = url
                return s.report
            }
            setError("Could not open: \(error.localizedDescription)"); throw error
        }
        replace(with: p, fileURL: url, dirty: false)
        return nil
    }

    /// Project > Project Notes: the free text of the project (`Project.notes`), one undo step.
    /// The damaged file this project was salvaged from; the first write to that same path keeps a `.damaged.bak` copy first.
    private(set) var salvagedFrom: URL?
    private func protectSalvagedOriginal(writingTo url: URL) throws {
        guard let from = salvagedFrom, from.standardizedFileURL == url.standardizedFileURL else { return }
        try ProjectFile.backUpDamaged(package: from)
        salvagedFrom = nil
    }

    public func setProjectNotes(_ text: String) {
        guard project.notes != text else { return }
        perform(Self.projectNotesUndoName) { $0.notes = text }
    }
    static let projectNotesUndoName = "Edit Project Notes"

    public func newProject(_ project: Project = EditorSession.makeUntitled()) {
        replace(with: project, fileURL: nil, dirty: false)
    }

    private func replace(with p: Project, fileURL url: URL?, dirty: Bool, mediaFolderOf folder: URL? = nil) {
        SessionMarker(store: autosaveStore).end(projectID: project.id)
        onProjectReplaced?()                     // open, new, import, revert, close: background work of the old project stops
        onReleaseProject?(project, isDirty)
        history = History(p)
        salvagedFrom = nil
        playheadSteps = [:]
        sideSteps = [:]
        fileURL = url
        media.setProjectFolder(MediaManagement.projectFolder(forProjectAt: folder ?? url))
        forceDirty = dirty
        activeTimelineID = p.activeTimeline.flatMap { p.timeline($0) }?.id ?? p.pickableTimelines.first?.id
        activeVariants = p.activeVariants
        selection = []; captionSelection = []
        sequenceTabs = SequenceTabs()
        if let id = activeTimelineID { sequenceTabs.open(id) }
        if isPlaying || !engine.rate.isPaused { engine.pause(); isPlaying = false }
        resetFollow()
        bounds = PlaybackBounds()
        clipboard = nil                          // its clips refer to media of the old project
        playhead = .zero
        lastAutosave = nil
        mediaSnapshot = []; requestedMedia = []
        beginMarker()
        syncMedia()
        // A project without media skips syncMedia's proxy sync: its mode still applies and the old project's jobs stop.
        if let a = autoProxy, a.projectID != project.id { a.sync(project.media, projectID: project.id) }
        syncStyleKit()
        pushTimeline(force: true)
        engine.seek(to: .zero)
        notify([.project, .selection, .playhead])
        detectMissingColor()
        refreshMissingSoundInfo()
        refreshMissingShootInfo()
    }

    static let projectInputColorUndoName = "Set Project Input Color Space"

    /// W9.3: the project's camera input color space (`Project.inputColorSpace`; nil = none), used by untagged video
    /// that detected as Rec.709. One undo step; playback and export see it through `Project.mediaForRendering`.
    public func setProjectInputColorSpace(_ space: ColorSpaceID?) {
        guard project.inputColorSpace != space else { return }
        perform(Self.projectInputColorUndoName) { $0.inputColorSpace = space }
    }

    /// Media from before color detection (`MediaInfo.needsColorDetection`, v6 files) is probed in the background and its
    /// info updated once, outside undo and without dirtying the project. Runs on open; call again after a relink.
    public func detectMissingColor() {
        let pending = project.media.filter { $0.info?.needsColorDetection == true && $0.info?.video != nil }
        guard !pending.isEmpty else { return }
        let projectID = project.id
        let detect = colorDetector
        Task { [weak self] in
            for ref in pending {
                guard FileManager.default.fileExists(atPath: ref.path),
                      let found = await detect(URL(fileURLWithPath: ref.path)) else { continue }
                guard let self, self.project.id == projectID else { return }
                let before = self.history.current
            self.history.amendAll { p in
                    guard let i = p.media.firstIndex(where: { $0.id == ref.id && $0.path == ref.path }) else { return }
                    p.media[i].info?.detectedColorSpace = found.space
                    p.media[i].info?.embeddedLUTName = found.embeddedLUTName
                }
                self.projectDidChange()
            }
        }
    }

    /// F7.10: media from before sound info was stored (info without an audio part, not a still) is probed in the
    /// background so the Audio Channels menu can show its channels. Off the main actor; only a probe that found sound
    /// changes the item (outside undo, like the other probe refreshes). Runs on open; call again after a relink.
    public func refreshMissingSoundInfo() {
        let pending = project.media.filter { m in
            guard let info = m.info, info.isStill != true, info.soundProbed != true else { return false }
            return info.audio == nil || info.audio?.firstTrackChannels == nil     // no sound stored, or not counted across tracks
        }
        guard !pending.isEmpty else { return }
        let projectID = project.id
        let probe = mediaInfoProbe
        Task { [weak self] in
            var found: [MediaRef.ID: MediaInfo] = [:]
            var probedIDs: Set<MediaRef.ID> = []
            for ref in pending {
                guard FileManager.default.fileExists(atPath: ref.path),
                      let info = await probe(URL(fileURLWithPath: ref.path)) else { continue }
                probedIDs.insert(ref.id)
                if info.audio != nil { found[ref.id] = info }
            }
            guard !probedIDs.isEmpty, let self, self.project.id == projectID else { return }
            self.history.amendAll { p in      // folded into every state: no undo step, not dirty (saved with the next save)
                let same = Set(p.media.filter { m in pending.contains { $0.id == m.id && $0.path == m.path } }.map(\.id))
                _ = p.fitAudioChannelMaps(to: found.filter { id, _ in same.contains(id) })
                for i in p.media.indices where probedIDs.contains(p.media[i].id) && same.contains(p.media[i].id) {
                    p.media[i].info?.soundProbed = true       // remembered: silent or counted, not probed again
                }
            }
            self.projectDidChange()
        }
    }

    /// Media from before shooting date and camera were stored is read in the background (off the main actor) and the result
    /// folded into every history state: no undo step, saved with the next save. A file that has none is marked as looked up.
    public func refreshMissingShootInfo() {
        #if os(macOS)
        let pending = project.media.filter { $0.info != nil && $0.info?.shootProbed != true }
        guard !pending.isEmpty else { return }
        let projectID = project.id
        let probe = shootProbe
        Task { [weak self] in
            var found: [MediaRef.ID: (path: String, result: ShootMetadata.Result)] = [:]
            for ref in pending {
                guard FileManager.default.fileExists(atPath: ref.path) else { continue }
                found[ref.id] = (ref.path, await probe(URL(fileURLWithPath: ref.path)))
            }
            guard !found.isEmpty, let self, self.project.id == projectID else { return }
            self.history.amendAll { p in
                for i in p.media.indices {
                    guard let hit = found[p.media[i].id], hit.path == p.media[i].path, p.media[i].info != nil else { continue }
                    p.media[i].info?.created = hit.result.created
                    p.media[i].info?.cameraModel = hit.result.cameraModel
                    p.media[i].info?.shootProbed = true
                }
            }
            self.projectDidChange()
        }
        #endif   // shortcut: shooting date and camera are read on the Mac only; upgrade with the FFmpeg metadata probe.
    }

    /// Source Monitor In/Out of a media item. Not an undo step (Premiere keeps marks out of the edit history): the
    /// change is folded into every history state so Undo never reverts a mark. nil clears the item's marks.
    public func setSourceMarks(_ marks: SourceMarks?, for media: MediaRef.ID) {
        guard project.sourceMarks[media] != (marks?.isEmpty == true ? nil : marks) else { return }
        history.amendAll { p in p.sourceMarks[media] = (marks?.isEmpty == true) ? nil : marks }
        forceDirty = true
        notify(.project)
    }

    /// Source markers (M in the Source monitor) of a media item: like the marks, clip metadata outside the undo history.
    public func setSourceMarkers(_ markers: [Marker]?, for media: MediaRef.ID) {
        let value = (markers?.isEmpty ?? true) ? nil : markers
        guard project.media(media)?.sourceMarkers != value else { return }
        history.amendAll { p in
            if let i = p.media.firstIndex(where: { $0.id == media }) { p.media[i].sourceMarkers = value }
        }
        forceDirty = true
        notify(.project)
    }

    // MARK: Autosave and recovery

    /// Writes an autosave version when the project is dirty and the policy says one is due. The app calls this
    /// from a timer (`startAutosaveTimer`); tests call it with an injected clock. Returns whether a version was written.
    @discardableResult
    public func tickAutosave() async -> Bool {
        let now = clock()
        guard autosaveStore.policy.shouldAutosave(isDirty: isDirty, lastAutosave: lastAutosave, now: now) else { return false }
        let (_, file) = snapshotForSave()
        let projectID = project.id
        do {
            try await saveQueue.autosave(file, store: autosaveStore, date: now)
            // The project was replaced (open, new, recover) while the write ran: the version belongs to the old one.
            guard project.id == projectID else { return false }
            lastAutosave = now
            SQLog.info("autosave ok: \(project.name)")
            notify(.status)   // the status bar's "Edited · Backup 14:32" follows at once
            return true
        } catch {
            setError("Autosave failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes a named checkpoint of the project as it is now (never pruned, listed first in File > Project > Autosave Versions).
    /// Works for a clean or untitled project too. Returns the version, nil when the name is empty or the write failed.
    @discardableResult
    public func saveCheckpoint(name: String) async -> AutosaveVersion? {
        guard AutosaveStore.sanitized(name) != nil else { return nil }
        let (_, file) = snapshotForSave()
        do {
            let v = try await saveQueue.autosave(file, store: autosaveStore, date: clock(), name: name)
            SQLog.info("checkpoint ok: \(project.name)")
            return v
        } catch {
            setError("Checkpoint failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func startAutosaveTimer(checkEvery seconds: TimeInterval = 30) {
        stopAutosaveTimer()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.tickAutosave()
            }
        }
    }

    public func stopAutosaveTimer() { autosaveTask?.cancel(); autosaveTask = nil }

    /// Crashed sessions with an autosave newer than their saved file (run at launch).
    public static func recoveryCandidates(scanner: RecoveryScanner = RecoveryScanner(store: AutosaveStore())) -> [RecoveryCandidate] {
        scanner.scan()
    }

    /// Opens the autosave as the project it came from (same name, same file when that still exists), marked dirty: Save
    /// writes it back to its place. A project that was never saved opens untitled.
    public func recover(_ candidate: RecoveryCandidate, scanner: RecoveryScanner) async throws {
        let p: Project
        do { p = try await saveQueue.recover(candidate, scanner: scanner) } catch {
            setError("Could not recover: \(error.localizedDescription)"); throw error
        }
        SQLog.info("recovery ok: \(candidate.projectName)")
        let home = candidate.projectURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        replace(with: p, fileURL: home, dirty: true)
        scanner.dismiss(candidate)
    }
}
