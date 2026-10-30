import Foundation
import SQCore

/// Selection follows playhead (Premiere: Sequence > Selection Follows Playhead). Rule: the selection is replaced
/// whenever the playhead crosses a clip boundary on a targeted track; inside the same clips a manual selection is left
/// alone, Escape stays cleared until the next crossing. Untargeted tracks never take part; nothing under the playhead
/// means nothing selected; with no track targeted at all the selection is left alone.
///
/// When it is evaluated (the playhead itself never waits for it):
/// - Playing: never. The selection is evaluated once when playback stops (pause, stop, end, a range's end).
/// - Scrub drag, and a run of frame steps (held arrow key, shuttle steps): deferred. Every move only notes that an
///   evaluation is due; one evaluation of the latest position runs once the playhead rested for `followSettle`, or at
///   once when the drag ends.
/// - A single jump (click, go to an edit, timecode entry, one frame step): at once.
/// A change of the selection is view state: no undo step, no dirty flag, no project snapshot.
extension EditorSession {
    /// How a playhead move asks for the follow evaluation.
    enum FollowTrigger {
        /// One jump: evaluated at once.
        case jump
        /// One of possibly many frame steps: at once when it stands alone, deferred inside a run.
        case step
        /// A move of a scrub drag: always deferred.
        case scrub
    }

    public func setSelectionFollowsPlayhead(_ on: Bool) {
        guard on != selectionFollowsPlayhead else { return }
        selectionFollowsPlayhead = on
        followState = nil
        cancelPendingFollow()
        if on, !isPlaying { followPlayhead() }
    }

    /// The playhead moved while parked. Costs a range compare unless a clip boundary was crossed.
    func playheadMoved(_ trigger: FollowTrigger) {
        guard selectionFollowsPlayhead, !isPlaying else { return }
        if trigger == .jump {
            if followPending || !(followState?.covers(playhead) ?? false) { followPlayhead() }
            return
        }
        let now = ContinuousClock.now
        let inRun = trigger == .scrub || (followLastStep.map { now - $0 < followStepRun } ?? false)
        if trigger == .step { followLastStep = now }
        if !followPending, let f = followState, f.covers(playhead) { return }      // same clips: nothing is due
        guard inRun else { followPlayhead(); return }
        followPending = true
        followDeadline = now + followSettle
        guard followTask == nil else { return }
        followTask = Task { @MainActor [weak self] in
            while let deadline = self?.followDeadline, ContinuousClock.now < deadline {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if Task.isCancelled { return }
            }
            self?.followTask = nil
            self?.flushFollowSelection()
        }
    }

    /// Brings the selection up to the playhead now: applies a deferred evaluation (end of a scrub drag), and evaluates
    /// while playing. Called before anything that works on the selection (a command, an effect double-click), so it
    /// acts on the clip under the playhead and not on the one playback started in.
    public func flushFollowSelection() {
        guard followPending || isPlaying else { return }
        followPlayhead()
    }

    /// True while a deferred evaluation waits (tests).
    var isFollowPending: Bool { followPending }

    func cancelPendingFollow() {
        followPending = false
        followTask?.cancel(); followTask = nil
    }

    /// A manual selection while an evaluation is still due or while playing (where nothing is evaluated): the follow
    /// state catches up with the playhead first, so the manual selection is not replaced a moment later (by the
    /// deferred evaluation, by the stop) and holds until the next boundary.
    func settleFollowForManualSelection() {
        // Also when no evaluation is due: a clip just added (Text tool, drop, shape) changes what lies under the playhead,
        // and a stale or missing follow state would re-evaluate on the next seek and replace the new selection with the
        // clip on the targeted track.
        cancelPendingFollow()
        guard selectionFollowsPlayhead, colorSourceView == nil, let t = activeTimeline,
              t.tracks.contains(where: \.isTargeted) else { return }
        followState = t.followedClips(at: playhead)
    }

    /// Transport changed (called before every notification): the stop of a playback evaluates once, a start drops
    /// what a scrub left pending.
    func followTransportChanged() {
        guard isPlaying != followWasPlaying else { return }
        followWasPlaying = isPlaying
        if isPlaying { cancelPendingFollow() } else { followPlayhead() }
    }

    /// Evaluates the playhead position now and replaces the selection when a boundary was crossed.
    func followPlayhead() {
        cancelPendingFollow()
        guard selectionFollowsPlayhead, colorSourceView == nil, let t = activeTimeline,
              t.tracks.contains(where: \.isTargeted) else { return }
        if let f = followState, f.covers(playhead) { return }
        followEvaluations += 1
        let started = FollowTiming.logs ? ContinuousClock.now : nil
        #if os(macOS)
        let state = TimelineSignpost.log.beginInterval("followSelection")
        #endif
        defer {
            #if os(macOS)
            TimelineSignpost.log.endInterval("followSelection", state)
            #endif
            if let started { FollowTiming.report("followSelection", since: started) }
        }
        let f = t.followedClips(at: playhead)
        let previous = followState
        followState = f
        if let previous, previous.ids == f.ids { return }
        setSelection(clips: expandingLinks(f.ids), captions: captionSelection)
    }

    /// Another project or sequence is shown: nothing of the old one is due or remembered.
    func resetFollow() {
        cancelPendingFollow()
        followState = nil
        followLastStep = nil
        followWasPlaying = isPlaying
    }
}

/// `SQ_FOLLOW_LOG=1`: logs how long a follow evaluation (with every synchronous observer of the selection change) and
/// an Effect Controls rebuild took. The same intervals are signposts (`TimelineSignpost`: `followSelection`,
/// `effectControlsRebuild`).
public enum FollowTiming {
    public static let logs = ProcessInfo.processInfo.environment["SQ_FOLLOW_LOG"] == "1"

    public static func report(_ name: String, since start: ContinuousClock.Instant) {
        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        NSLog("SQFOLLOW %@ %.3f ms", name, ms)
    }
}
