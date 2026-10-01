import Foundation
import SQCore

/// Transitions as user actions: every call is ONE undo step (a drag of a transition edge coalesces into one).
extension EditorSession {
    /// Which tracks an Apply command works on.
    public enum TransitionScope: Sendable {
        case video, audio, both
        var kinds: Set<TrackKind> {
            switch self { case .video: [.video]; case .audio: [.audio]; case .both: [.video, .audio] }
        }
    }

    /// The transition with its current (clamped) form, for Effect Controls and the timeline.
    public func transitionInfo(_ id: Transition.ID) -> (track: Track.ID, transition: Transition, resolved: ResolvedTransition?)? {
        guard let t = activeTimeline, let (tid, tr) = t.transition(id), let track = t.track(tid) else { return nil }
        return (tid, tr, track.resolvedTransitions(frameDuration: t.format.frameDuration).first { $0.id == id })
    }

    public func selectTransition(_ id: Transition.ID?) {
        guard selectedTransition != id else { return }
        selectedTransition = id
        if id != nil, !selection.isEmpty || !captionSelection.isEmpty { select(clips: [], captions: []) }
        notify(.selection)
    }

    /// Places the default transition (Cross Dissolve / Constant Power at the default length) at the selected edit(s), else at
    /// the edges of the selected clips, else at the edit nearest the playhead on the targeted tracks of `scope`.
    /// Returns how many were applied; a refusal (no edit found, not enough media) only sets the status message.
    @discardableResult
    public func applyDefaultTransitions(scope: TransitionScope, edges: EdgeSelection?,
                                        defaults: TransitionDefaults = .load()) -> Int {
        guard let t = activeTimeline else { return 0 }
        let targets = TransitionTargets.resolve(in: t, kinds: scope.kinds, edges: edges, selection: selection, playhead: playhead)
        guard !targets.isEmpty else {
            setError(scope == .audio ? "Target an audio track, or select an edit, to apply a transition."
                                     : "Target a track, or select an edit, to apply a transition.")
            return 0
        }
        var applied = 0
        var kindsUsed = Set<TransitionKind>()
        let ok = attempt(targets.count == 1 ? "Apply Transition" : "Apply Transitions") { tl in
            for target in targets {
                guard let track = tl.track(target.track) else { continue }
                let kind = TransitionKind.defaultKind(for: track.kind)
                let d = defaults.duration(for: track.kind, frameDuration: tl.format.frameDuration)
                if (try? tl.addTransition(point: target.point, kind: kind, track: target.track, duration: d)) != nil {
                    applied += 1; kindsUsed.insert(kind)
                }
            }
            if applied == 0 { throw EditError.insufficientMedia }
        }
        return ok ? applied : 0
    }

    /// Applies `kind` at one place (drag from the Effects panel onto a cut or clip end). Duration: the default for the kind.
    @discardableResult
    public func addTransition(kind: TransitionKind, track: Track.ID, point: TransitionPoint, alignment: TransitionAlignment,
                              defaults: TransitionDefaults = .load()) -> Transition.ID? {
        var made: Transition.ID?
        let ok = attempt("Apply \(kind.name)") { t in
            let d = defaults.duration(for: kind.trackKind, frameDuration: t.format.frameDuration)
            made = try t.addTransition(point: point, kind: kind, track: track, duration: d, alignment: alignment)
        }
        if ok, let made { selectTransition(made) }
        return ok ? made : nil
    }

    /// Changes duration / alignment (Effect Controls, edge and body drags, the duration dialog). `continuesGesture`: edits of
    /// one drag are one undo step.
    public func setTransition(_ id: Transition.ID, duration: Time? = nil, alignment: TransitionAlignment? = nil,
                              customBefore: Time? = nil, kind: TransitionKind? = nil, continuesGesture: Bool = false) {
        if !continuesGesture { gestureCounter += 1 }
        attempt("Change Transition", coalescing: "transition:\(id):\(gestureCounter)") {
            try $0.setTransition(id, kind: kind, duration: duration, alignment: alignment, customBefore: customBefore)
        }
    }

    /// Removes the selected transition (Delete). False when none is selected.
    @discardableResult
    public func removeSelectedTransition() -> Bool {
        guard let id = selectedTransition else { return false }
        return removeTransition(id)
    }

    @discardableResult
    public func removeTransition(_ id: Transition.ID) -> Bool {
        let ok = attempt("Clear Transition") { try $0.removeTransition(id) }
        if ok { selectTransition(nil) }
        return ok
    }
}
