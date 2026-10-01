import Foundation
import Observation
import SQCore
import SQMedia

/// The editing document: one project with undo history, the active sequence, playhead, selection, file state and
/// the Program engine. Every edit goes through `perform` / `performTimeline` (one undo step each); after each
/// commit, undo and redo the active timeline is pushed to the engine with `setTimeline`.
///
/// Timeline edits run through `Project.edit` so a nested clip can never make a sequence contain itself.
/// File work (save, open, autosave) runs on `ProjectSaveQueue`, off the main actor and serialised.
@MainActor @Observable
public final class EditorSession {
    public enum SaveError: Error, Equatable { case noFileURL }

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
    }

    // MARK: State

    public private(set) var history: History<Project>
    public private(set) var fileURL: URL?
    public private(set) var activeTimelineID: Timeline.ID?
    public private(set) var playhead: Time = .zero
    public private(set) var selection: Set<Clip.ID> = []
    public private(set) var captionSelection: Set<CaptionItem.ID> = []
    /// The transition selected on the timeline (Effect Controls shows its Duration and Alignment).
    public internal(set) var selectedTransition: Transition.ID?
    /// Clips copied with Cmd+C / Cmd+X (Paste puts them at the playhead).
    public var clipboard: TimelineClipboard?
    public private(set) var isPlaying = false
    /// Loop toggle and the range of "Play In to Out" (nil = whole sequence); see `PlaybackBounds`.
    public var bounds = PlaybackBounds()
    public private(set) var lastAutosave: Date?
    /// Message of the last refused or failed action (locked track, disk error...); UI shows it in the status bar.
    public private(set) var lastError: String?

    @ObservationIgnored public let engine: any ProgramEngine
    @ObservationIgnored public let media: ProjectMediaResolver
    @ObservationIgnored public let autosaveStore: AutosaveStore
    @ObservationIgnored private let saveQueue: ProjectSaveQueue
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored public var onChange: (@MainActor (Change) -> Void)?
    /// Asked when the first clip placed into an empty, never configured sequence differs from its format (Premiere's
    /// "change sequence settings / keep existing" prompt). true = adopt the clip's format. nil hook = adopt silently.
    @ObservationIgnored public var confirmFormatChange: (@MainActor (_ current: SequenceFormat, _ proposed: SequenceFormat) -> Bool)?

    @ObservationIgnored private var forceDirty = false
    @ObservationIgnored private var pushed: (timeline: Timeline, sequences: [Timeline.ID: Timeline])?
    @ObservationIgnored private var mediaSnapshot: [MediaRef] = []
    @ObservationIgnored private var requestedMedia: Set<UUID> = []
    @ObservationIgnored var gestureCounter = 0
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

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
                media: ProjectMediaResolver = ProjectMediaResolver(),
                saveQueue: ProjectSaveQueue = ProjectSaveQueue(),
                autosaveStore: AutosaveStore = AutosaveStore(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.history = History(project)
        self.fileURL = fileURL
        self.engine = engine
        self.media = media
        self.saveQueue = saveQueue
        self.autosaveStore = autosaveStore
        self.clock = clock
        self.activeTimelineID = project.activeTimeline ?? project.timelines.first?.id
        engine.onPositionChange = { [weak self] t in self?.enginePositionChanged(t) }
        beginMarker()
        syncMedia()
        pushTimeline(force: true)
    }

    /// Probe used by `detectMissingColor` (SQMedia `ColorDetection`); injectable for tests.
    @ObservationIgnored var colorDetector: @Sendable (URL) async -> (space: ColorSpaceID, embeddedLUTName: String?)? = { await ColorDetection.detect(url: $0) }

    deinit { autosaveTask?.cancel() }

    /// Empty project with one 29.97 fps HD sequence (V1-V4, A1-A4).
    public static func makeUntitled() -> Project {
        let t = Timeline(name: "Sequence 01", format: SequenceFormat(frameDuration: Time(1001, 30000)),
                         tracks: Timeline.defaultTracks(), formatLocked: false)
        return Project(name: "Untitled", timelines: [t])
    }

    /// Ends the crash marker and the autosave timer. Call on a clean quit or before replacing the session.
    public func close() {
        stopAutosaveTimer()
        SessionMarker(store: autosaveStore).end(projectID: project.id)
    }

    private func beginMarker() {
        try? SessionMarker(store: autosaveStore).begin(projectID: project.id, projectURL: fileURL, projectName: project.name)
    }

    func notify(_ c: Change) { onChange?(c) }

    // MARK: Editing

    /// One undo step. `coalescing`: consecutive edits with the same key merge. Throws the edit's error and then
    /// leaves the project untouched.
    public func perform(_ name: String, coalescing key: String? = nil,
                        _ edit: (inout Project) throws -> Void) rethrows {
        try history.commit(name, coalescing: key, edit)
        projectDidChange()
    }

    /// Edits the active timeline through `Project.edit`: a nesting cycle is refused with `.nestingCycle`.
    public func performTimeline(_ name: String, coalescing key: String? = nil,
                                _ body: (inout Timeline) throws -> Void) throws {
        guard let id = activeTimelineID else { throw EditError.timelineNotFound }
        try perform(name, coalescing: key) { try $0.edit(id) { try body(&$0); $0.normalizeAudioKeyMarks() } }
    }

    /// Like `performTimeline`, but a refused edit only sets `lastError`. Returns whether it was applied.
    @discardableResult
    func attempt(_ name: String, coalescing key: String? = nil, _ body: (inout Timeline) throws -> Void) -> Bool {
        let before = history.current
        do { try performTimeline(name, coalescing: key, body) } catch {
            setError(Self.message(for: error)); return false
        }
        return history.current != before
    }

    @discardableResult
    public func undo() -> Bool {
        guard history.undo() else { return false }
        projectDidChange()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard history.redo() else { return false }
        projectDidChange()
        return true
    }

    /// Applies a finished timeline gesture (`TimelineInteraction`) as ONE undo step by replaying its edits.
    public func commit(_ c: TimelineCommit) {
        let ok = attempt(c.undoName) { t in
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
            try perform("Nest") { p in seq = try p.nest(clips: ids, in: id, name: trimmed.isEmpty ? nil : trimmed) }
        } catch { setError(Self.message(for: error)); return nil }
        if let seq, let t = activeTimeline {
            setSelection(clips: Set(t.tracks.flatMap(\.clips).filter { $0.sequence == seq }.map(\.id)), captions: [])
        }
        return seq
    }

    public func setActiveTimeline(_ id: Timeline.ID) {
        guard project.timeline(id) != nil, id != activeTimelineID else { return }
        stopForSequenceChange()
        activeTimelineID = id
        selection = []; captionSelection = []
        syncMedia()
        pushTimeline(force: true)
        clampPlayheadToActiveSequence()
        notify([.project, .selection])
    }

    /// A different sequence becomes active: playback stops and the Play In to Out / Play Around range and return point of
    /// the old one are dropped (Loop stays as the user set it).
    private func stopForSequenceChange() {
        if isPlaying || !engine.rate.isPaused { engine.pause(); isPlaying = false; notify(.transport) }
        bounds = PlaybackBounds(loop: bounds.loop)
    }

    /// Puts the playhead on a frame of the (new) active sequence.
    private func clampPlayheadToActiveSequence() {
        let end = activeTimeline?.duration ?? .zero
        let last = max(.zero, end - frameDuration)
        if playhead > last { seek(to: last) } else { engine.seek(to: playhead) }
    }

    /// Withdraws every undo step above `depth` (Type tool: an empty text box leaves no trace). No redo entries remain.
    public func rewindUndo(toDepth depth: Int) {
        history.rewind(toDepth: depth)
        projectDidChange()
    }

    /// Folds the undo steps above `depth` into one named step (Type tool: add + typed text = "Add Text").
    public func foldUndo(fromDepth depth: Int, name: String) { history.squash(fromDepth: depth, name: name) }

    private func projectDidChange() {
        let before = activeTimelineID
        if let id = activeTimelineID, project.timeline(id) == nil { activeTimelineID = nil }
        if activeTimelineID == nil {
            activeTimelineID = project.activeTimeline.flatMap { project.timeline($0) }?.id ?? project.timelines.first?.id
            if activeTimelineID != before { stopForSequenceChange() }
        }
        pruneSelection()
        syncMedia()
        pushTimeline(force: false)
        if activeTimelineID != before { clampPlayheadToActiveSequence() }
        notify([.project, .selection])
    }

    private func pushTimeline(force: Bool) {
        guard let t = activeTimeline else { pushed = nil; return }
        let nested = Dictionary(uniqueKeysWithValues: project.reachableSequences(from: t.id).compactMap { id in
            project.timeline(id).map { (id, $0) }
        })
        if !force, let p = pushed, p.timeline == t, p.sequences == nested { return }
        pushed = (t, nested)
        engine.setTimeline(t, sequences: nested)
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
    public func relinkMedia(_ paths: [MediaRef.ID: String]) {
        guard !paths.isEmpty else { return }
        requestedMedia.subtract(paths.keys)       // so `syncMedia` prepares them again
        perform("Relink Media") { $0.relink(paths) }
    }

    private func syncMedia() {
        // Always: the active sequence's sample rate can change without the media changing.
        media.update(project.media, sampleRate: activeTimeline?.format.audioSampleRate)
        guard project.media != mediaSnapshot else { return }
        // Media whose file moved (relink to another path): the audio feeder reopens them. The video side does the same
        // through `PlaybackEngine.mediaChanged` once that lands; both are idempotent.
        var oldPaths: [UUID: String] = [:]
        for m in mediaSnapshot { oldPaths[m.id] = m.path }
        var moved: Set<UUID> = []
        for m in project.media { if let old = oldPaths[m.id], old != m.path { moved.insert(m.id) } }
        if !moved.isEmpty { engine.mediaChanged(moved) }
        mediaSnapshot = project.media
        let fresh = project.media.map(\.id).filter { requestedMedia.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        Task { [weak self, media] in
            await media.prepare(fresh)
            self?.notify(.media)
        }
    }

    func setError(_ m: String) { lastError = m; notify(.status) }
    public func clearError() { guard lastError != nil else { return }; lastError = nil; notify(.status) }

    static func message(for error: Error) -> String {
        switch error as? EditError {
        case .trackLocked: "The track is locked."
        case .collision: "Another clip is in the way."
        case .nestingCycle: "A sequence cannot contain itself."
        case .invalidFormat: "That sequence format is not valid."
        case .clipNotFound, .timelineNotFound: "The clip no longer exists."
        case .wrongTrackKind: "That clip does not belong on this track."
        case .emptyClip: "Nothing to edit."
        case .speedUnsupported: "Speed cannot be changed on that clip (titles and stills)."
        case .notACut: "Transitions go on a cut between two clips that touch, or on a clip edge."
        case .insufficientMedia: "Not enough media beyond the cut for a transition. Trim the clips to leave handles."
        default: error.localizedDescription
        }
    }

    // MARK: Selection

    public func select(clips: Set<Clip.ID>, captions: Set<CaptionItem.ID> = []) { setSelection(clips: clips, captions: captions) }

    private func setSelection(clips: Set<Clip.ID>, captions: Set<CaptionItem.ID>) {
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

    /// Moves the playhead (frame-snapped, never before zero) and shows that frame.
    public func seek(to t: Time) {
        let target = max(.zero, t.snapped(to: frameDuration))
        playhead = target
        engine.seek(to: target)
        notify(.playhead)
    }

    /// Reports the playhead without asking the engine to seek (the engine already is there).
    /// Only while playing: when paused the session's playhead is the truth and the engine's last presented frame
    /// may still lag behind a fast scrub. Playback stops at the end of the sequence.
    private func enginePositionChanged(_ t: Time) {
        guard isPlaying else { return }
        let end = activeTimeline?.duration ?? .zero
        // Stop at the sequence end: the last presented frame is one frame before `end`, and the engine may have stopped itself.
        let rate = engine.rate
        switch bounds.action(at: t, rate: rate, frameDuration: frameDuration, duration: end) {
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
        let atEnd = end > .zero && (t + frameDuration >= end) && engine.rate.isForward
        if atEnd || engine.rate.isPaused {
            engine.pause(); isPlaying = false
            if atEnd { playhead = end }
            notify([.playhead, .transport])
            return
        }
        guard t != playhead else { return }
        playhead = t
        notify(.playhead)
    }

    /// Play from the end of the sequence restarts at the start.
    private func restartIfAtEnd() {
        let end = activeTimeline?.duration ?? .zero
        if end > .zero, playhead >= end { seek(to: .zero) }
    }

    /// A click in the timeline or ruler: playback stops (and stays stopped until Play / Space / L).
    public func stopPlayback() {
        guard isPlaying || !engine.rate.isPaused else { return }
        engine.pause()
        isPlaying = false
        notify(.transport)
    }

    public func beginScrub() { stopPlayback(); engine.beginScrub() }
    public func scrub(to t: Time) {
        let target = max(.zero, t.snapped(to: frameDuration))
        playhead = target
        engine.scrub(to: target)
        notify(.playhead)
    }
    public func endScrub() { engine.endScrub() }

    public func playPause() {
        if ProcessInfo.processInfo.environment["SQ_KEYLOG"] == "1" { NSLog("SQKEY session.playPause isPlaying=\(isPlaying) rate=\(engine.rate)") }
        if isPlaying || !engine.rate.isPaused { engine.pause(); isPlaying = false } else { bounds.range = nil; restartIfAtEnd(); engine.play(.forward); isPlaying = true }
        notify(.transport)
    }

    public func apply(shuttle action: ShuttleAction) {
        switch action {
        case .setRate(let r):
            if r.isPaused { engine.pause(); isPlaying = false } else { bounds.range = nil; if r.isForward { restartIfAtEnd() }; engine.play(r); isPlaying = true }
            notify(.transport)
        case .step(let n): stepFrames(n)
        case .none: break
        }
    }

    public func stepFrames(_ n: Int) {
        if isPlaying { engine.pause(); isPlaying = false; notify(.transport) }
        seek(to: playhead + frameDuration * Int64(n))
    }

    public func goToStart() { seek(to: .zero) }
    public func goToEnd() { seek(to: activeTimeline?.duration ?? .zero) }

    /// Edit points Up/Down jump between: those of the targeted tracks, or of all tracks when none is targeted (Premiere).
    private func jumpPoints() -> [Time] {
        guard let t = activeTimeline else { return [] }
        let targeted = t.tracks.filter(\.isTargeted)
        guard !targeted.isEmpty else { return t.editPoints() }
        var set = Set<Time>()
        for tr in targeted { for c in tr.clips { set.insert(c.start); set.insert(c.timeline.end) } }
        return set.sorted()
    }

    public func goToNextEditPoint() {
        if let t = jumpPoints().first(where: { $0 > playhead }) { seek(to: t) }
    }

    public func goToPreviousEditPoint() {
        if let t = jumpPoints().last(where: { $0 < playhead }) { seek(to: t) }
    }

    public func goToIn() { if let io = activeTimeline?.inOut { seek(to: io.start) } }
    /// Out is stored one frame past its frame: go to the marked (last included) frame.
    public func goToOut() { if let io = activeTimeline?.inOut { seek(to: max(io.start, io.end - frameDuration)) } }

    // MARK: Timeline commands

    /// Delete (lift, leaves a gap) or ripple delete of the selected clips and captions.
    public func deleteSelection(ripple: Bool) {
        guard !selection.isEmpty || !captionSelection.isEmpty else { return }
        var edits: [TimelineEdit] = []
        if !selection.isEmpty {
            let ids = Array(selection)
            edits.append(ripple ? .rippleDelete(ids) : .lift(ids))
        }
        edits += captionSelection.sorted { $0.uuidString < $1.uuidString }.map { .deleteCaption($0) }
        let name = ripple && !selection.isEmpty ? "Ripple Delete" : "Delete"
        if attempt(name, { t in for e in edits { try e.apply(to: &t) } }) {
            selection = []; captionSelection = []
            notify(.selection)
        }
    }

    /// Cmd+K: cuts at the playhead on the tracks of the selected clips, else on the targeted tracks, else on all
    /// (`allTracks`: always all, Cmd+Shift+K).
    public func addEditAtPlayhead(allTracks: Bool = false) {
        guard let t = activeTimeline else { return }
        let selected = t.tracks.filter { tr in tr.clips.contains { selection.contains($0.id) } }.map(\.id)
        let targeted = t.tracks.filter(\.isTargeted).map(\.id)
        let ids = allTracks ? nil : (!selected.isEmpty ? selected : (!targeted.isEmpty ? targeted : nil))
        let at = playhead
        attempt(allTracks ? "Add Edit to All Tracks" : "Add Edit") { _ = try $0.addEdit(at: at, tracks: ids) }
    }

    /// Q (`.head`) / W (`.tail`): ripple-trims the clip under the playhead so that edge lands on it.
    public func rippleTrimToPlayhead(_ edge: ClipEdge) {
        let at = playhead
        var moved = Time.zero
        let done = attempt(edge == .head ? "Ripple Trim Previous Edit" : "Ripple Trim Next Edit") {
            moved = try $0.rippleTrimToPlayhead(edge, at: at, tracks: nil)
        }
        // Head trim: the picture under the playhead slid back by the cut, so the playhead goes with it and lands on
        // the new edit point (Premiere). A tail trim leaves the picture where it was.
        if done, edge == .head, moved != .zero { seek(to: at - moved) }
    }

    /// Tracks a range edit applies to: the targeted tracks, else every unlocked track.
    private func rangeTracks(_ t: Timeline) -> [Track.ID] {
        let targeted = t.tracks.filter { $0.isTargeted && !$0.isLocked }.map(\.id)
        return targeted.isEmpty ? t.tracks.filter { !$0.isLocked }.map(\.id) : targeted
    }

    /// Removes the In/Out range and leaves a gap.
    public func liftRange() {
        guard let t = activeTimeline, let io = t.inOut, !io.isEmpty else { return }
        let ids = rangeTracks(t)
        attempt("Lift") { try $0.lift(io, tracks: ids) }
    }

    /// Removes the In/Out range and closes the gap.
    public func extractRange() {
        guard let t = activeTimeline, let io = t.inOut, !io.isEmpty else { return }
        let ids = rangeTracks(t)
        attempt("Extract") { _ = try $0.extract(io, tracks: ids) }
    }

    /// Places media items one after another starting at `time` (default: the playhead): video on `track` (else the
    /// targeted or first video track), linked audio on the mirrored audio track (V2 -> A2, created when missing,
    /// see `Timeline.dropTargets`). Source marks from the Project panel are honoured. Into an empty sequence that was
    /// never configured (`formatLocked == false`) the first item sets the sequence format (size and frame rate).
    /// Returns false when nothing could be placed (unknown ID, refused edit).
    @discardableResult
    public func placeMedia(_ ids: [MediaRef.ID], at time: Time? = nil, videoTrack: Track.ID? = nil,
                           mode: ThreePointMode = .overwrite, adoptFormat: Bool = true, streams: SourceStreams = .both) -> Bool {
        guard let t = activeTimeline else { return false }
        let refs = ids.compactMap { project.media($0) }.filter { ($0.info?.duration ?? $0.duration) != nil }
        guard !refs.isEmpty else { return false }
        var adopts = adoptFormat && !t.formatLocked && t.tracks.allSatisfy { $0.clips.isEmpty }
        if adopts, let ask = confirmFormatChange, let proposed = formatMismatch(placing: ids) {
            adopts = ask(t.format, proposed)
        }
        let requested = time ?? playhead
        let marks = project.sourceMarks
        let done = attempt(mode == .insert ? "Insert" : "Overwrite") { tl in
            if adopts, let v = refs[0].info?.video {
                // Upright (display) size: a portrait phone clip makes a portrait sequence. A still keeps the frame rate.
                let still = refs[0].info?.isStill == true
                tl.format = SequenceFormat(width: v.displayWidth, height: v.displayHeight,
                                           frameDuration: still ? tl.format.frameDuration : v.nominalFrameDuration,
                                           audioSampleRate: tl.format.audioSampleRate)
            }
            var at = requested.snapped(to: tl.frameDuration)   // after a format change: the new frame grid
            for ref in refs {
                // Scale is relative to source pixels: a new clip is placed at the fit value ("Set to Frame Size"), so a
                // clip of another size shows whole instead of cropped. 1 for the clip that set the sequence format.
                let fit = ref.info?.video.map { tl.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
                let total = ref.info?.duration ?? ref.duration ?? .zero
                let still = ref.info?.isStill == true
                let source = still ? TimeRange(start: .zero, duration: total)      // stills: default length, no source marks
                                   : marks[ref.id]?.range ?? TimeRange(start: .zero, duration: total)
                let hasVideo = (ref.info?.video != nil || ref.info == nil) && streams.includesVideo
                let d = tl.dropTargets(pointer: videoTrack, hasVideo: hasVideo, hasAudio: ref.info?.audio != nil && streams.includesAudio)
                var targets: [Track.ID] = []
                if let v = d.video { targets.append(v) }
                if let a = d.audio { targets.append(a) } else if let n = d.newAudioOrdinal { targets.append(tl.ensureAudioTrack(atOrdinal: n)) }
                try tl.threePointEdit(source: source, media: ref.id, name: ref.name, mediaDuration: still ? nil : total,
                                      isStill: still, initialScale: fit, targets: targets, at: at, mode: mode)
                at += source.duration
            }
        }
        return done
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
                               audioSampleRate: t.format.audioSampleRate)
        return f == t.format ? nil : f
    }

    /// New empty sequence in the active sequence's format (V1, V2, A1, A2); it becomes the active one.
    @discardableResult
    public func addSequence(name: String? = nil, format: SequenceFormat? = nil) -> Timeline.ID {
        let format = format ?? activeTimeline?.format ?? SequenceFormat(frameDuration: Time(1001, 30000))
        let names = Set(project.timelines.map(\.name))
        var n = project.timelines.count + 1
        while names.contains(String(format: "Sequence %02d", n)) { n += 1 }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let t = Timeline(name: trimmed.isEmpty ? String(format: "Sequence %02d", n) : trimmed, format: format,
                         tracks: Timeline.defaultTracks())
        perform("New Sequence") { p in
            p.timelines.append(t)
            p.normalizeBins()
        }
        setActiveTimeline(t.id)
        return t.id
    }

    /// Sequence Settings: one undo step. Clips keep their scale and position; only the canvas / rates change.
    @discardableResult
    public func setSequenceFormat(_ format: SequenceFormat) -> Bool {
        guard let id = activeTimelineID, activeTimeline?.format != format else { return false }
        do { try perform("Sequence Settings") { try $0.setFormat(format, of: id) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    /// Premiere "Set to Frame Size" / "Scale to Frame Size": Scale of the selected picture clips (or `ids`) becomes the
    /// value at which the whole picture fits the sequence frame (keyframes of Scale are removed, see
    /// `Project.setToFrameSize`). Both menu items do this; there is no resampling to tell them apart. One undo step.
    @discardableResult
    public func setToFrameSize(_ ids: Set<Clip.ID>? = nil) -> Bool {
        guard let tid = activeTimelineID else { return false }
        let targets = ids ?? selection
        guard !targets.isEmpty else { return false }
        var trial = project
        do {
            guard try trial.setToFrameSize(targets, in: tid) > 0 else { return false }     // already at the fit value
            try perform("Set to Frame Size") { $0 = trial }
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

    /// X: In/Out around the clip under the playhead on the targeted tracks (all tracks when none is targeted).
    public func markClip() {
        guard let t = activeTimeline else { return }
        let targeted = t.tracks.filter(\.isTargeted).map(\.id)
        guard let range = t.markClipRange(at: playhead, tracks: targeted.isEmpty ? nil : targeted) else { return }
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
        return (history.current, p)
    }

    /// Saves to the current file. `.noFileURL` for an untitled project (use `saveAs`).
    public func save() async throws {
        guard let url = fileURL else { throw SaveError.noFileURL }
        // A project opened from a legacy `.ssproj` is written to a sibling `.sqproj`; the old file stays untouched.
        if ProjectFile.isLegacyURL(url) {
            let target = ProjectFile.convertedURL(for: url)
            try await saveAs(to: target)
            setError("Saved as “\(target.lastPathComponent)”; the old “\(url.lastPathComponent)” was left in place.")
            return
        }
        try await write(to: url)
    }

    public func saveAs(to url: URL) async throws {
        try await write(to: url)
        fileURL = url
        beginMarker()
        notify(.project)
    }

    private func write(to url: URL) async throws {
        let (base, file) = snapshotForSave()
        do { try await saveQueue.write(file, to: url) } catch { setError("Could not save: \(error.localizedDescription)"); throw error }
        // Edits made while the write was running keep the project dirty.
        if history.current == base { history.markSaved(); forceDirty = false }
        notify(.project)
    }

    /// Replaces the session's project with the file's. The previous project's crash marker ends.
    public func open(url: URL) async throws {
        let p: Project
        do { p = try await saveQueue.read(url) } catch { setError("Could not open: \(error.localizedDescription)"); throw error }
        replace(with: p, fileURL: url, dirty: false)
    }

    public func newProject(_ project: Project = EditorSession.makeUntitled()) {
        replace(with: project, fileURL: nil, dirty: false)
    }

    private func replace(with p: Project, fileURL url: URL?, dirty: Bool) {
        SessionMarker(store: autosaveStore).end(projectID: project.id)
        history = History(p)
        fileURL = url
        forceDirty = dirty
        activeTimelineID = p.activeTimeline.flatMap { p.timeline($0) }?.id ?? p.timelines.first?.id
        selection = []; captionSelection = []
        playhead = .zero
        lastAutosave = nil
        mediaSnapshot = []; requestedMedia = []
        beginMarker()
        syncMedia()
        pushTimeline(force: true)
        engine.seek(to: .zero)
        notify([.project, .selection, .playhead])
        detectMissingColor()
    }

    /// Media from before colour detection (`MediaInfo.needsColorDetection`, v6 files) is probed in the background and its
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
                self.history.amendAll { p in
                    guard let i = p.media.firstIndex(where: { $0.id == ref.id && $0.path == ref.path }) else { return }
                    p.media[i].info?.detectedColorSpace = found.space
                    p.media[i].info?.embeddedLUTName = found.embeddedLUTName
                }
                self.projectDidChange()
            }
        }
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
            return true
        } catch {
            setError("Autosave failed: \(error.localizedDescription)")
            return false
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

    /// Opens the autosave as an untitled copy (new id, "(Recovered)"), marked dirty. The original is not touched.
    public func recover(_ candidate: RecoveryCandidate, scanner: RecoveryScanner) async throws {
        let p: Project
        do { p = try await saveQueue.recover(candidate, scanner: scanner) } catch {
            setError("Could not recover: \(error.localizedDescription)"); throw error
        }
        replace(with: p, fileURL: nil, dirty: true)
        scanner.dismiss(candidate)
    }
}
