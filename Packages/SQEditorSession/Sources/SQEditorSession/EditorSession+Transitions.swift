import Foundation
import SQCore

/// Transitions as user actions: every call is ONE undo step (a drag of a transition edge coalesces into one).
extension EditorSession {
    /// Which tracks an Apply command works on.
    public enum TransitionScope: Sendable {
        case video, audio, both
        public var kinds: Set<TrackKind> {
            switch self { case .video: [.video]; case .audio: [.audio]; case .both: [.video, .audio] }
        }
    }

    /// The transition with its current (clamped) form, for Effect Controls and the timeline.
    public func transitionInfo(_ id: Transition.ID) -> (track: Track.ID, transition: Transition, resolved: ResolvedTransition?)? {
        guard let t = activeTimeline, let (tid, tr) = t.transition(id), let track = t.track(tid) else { return nil }
        return (tid, tr, track.resolvedTransitions(frameDuration: t.format.frameDuration).first { $0.id == id })
    }

    /// `keepClips`: Shift / Command click adds the transition to the selection instead of replacing the clips.
    public func selectTransition(_ id: Transition.ID?, keepClips: Bool = false) {
        guard selectedTransition != id else { return }
        selectedTransition = id
        if id != nil, !keepClips, !selection.isEmpty || !captionSelection.isEmpty { select(clips: [], captions: []) }
        notify(.selection)
    }

    /// Places the default transition (Cross Dissolve / Constant Power at the default length) at the selected edit(s), else at
    /// the edges of the selected clips, else at the edit nearest the playhead on the targeted tracks of `scope`.
    /// Returns how many were applied; a refusal (no edit found, not enough media) only sets the status message.
    @discardableResult
    public func applyDefaultTransitions(scope: TransitionScope, edges: EdgeSelection?, kind only: TransitionKind? = nil,
                                        defaults: TransitionDefaults = .load()) -> Int {
        guard let t = activeTimeline else { return 0 }
        let targets = TransitionTargets.resolve(in: t, kinds: scope.kinds, edges: edges, selection: selection, playhead: playhead,
                                                clipEdgesOnly: only?.isElement == true)
        guard !targets.isEmpty else {
            setError(scope == .audio ? "Target an audio track, or select an edit, to apply a transition."
                                     : "Target a track, or select an edit, to apply a transition.")
            return 0
        }
        var applied = 0
        let bothEnds = only?.isElement == true ? Self.clipsWithBothEnds(targets) : []
        let user = effectDefaults
        let roles = AudioRoleDefaults.load()
        let ok = attempt(only.map { "Apply \($0.name)" } ?? (targets.count == 1 ? "Apply Transition" : "Apply Transitions")) { tl in
            for target in targets {
                guard let track = tl.track(target.track) else { continue }
                let kind = only ?? (track.kind == .audio ? roles.crossfadeKind : TransitionKind.defaultKind(for: track.kind))
                guard kind.trackKind == track.kind else { continue }
                let fd = tl.format.frameDuration
                // FB-W: the user's default of the kind first, else the one factory length of the kind (same as a drag).
                var d = user.transition(kind)?.duration ?? Self.factoryTransitionDuration(kind, frameDuration: fd, defaults: defaults)
                // Audio: a tagged clip brings its role's length (dialogue short, music long) unless the user set a default.
                if only == nil, track.kind == .audio, user.transition(kind) == nil,
                   let tag = Self.roleTag(of: target.point, on: track) {
                    d = roles.transitionDuration(for: tag, fallbackSeconds: defaults.audioSeconds, frameDuration: fd)
                }
                // Start and end of one clip: half the clip each at most, so the Out is not starved by the In.
                if let c = target.point.elementClip, bothEnds.contains(c), let clip = track.clips.first(where: { $0.id == c }) {
                    d = Timeline.elementDuration(d, clipDuration: clip.duration, bothEnds: true, frameDuration: fd)
                }
                if let id = try? tl.addTransition(point: target.point, kind: kind, track: target.track, duration: d) {
                    // The user's default look, else the factory look (new transitions only; DECISIONS 2026-10-06).
                    if let u = user.transition(kind) { try? tl.applyTransitionDefault(u, to: id) } else { try? tl.applyFactoryLook(id) }
                    applied += 1
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
        let user = effectDefaults.transition(kind)
        let ok = attempt("Apply \(kind.name)") { t in
            let d = user?.duration ?? Self.factoryTransitionDuration(kind, frameDuration: t.format.frameDuration, defaults: defaults)
            let id = try t.addTransition(point: point, kind: kind, track: track, duration: d, alignment: alignment)
            if let user { try t.applyTransitionDefault(user, to: id) } else { try t.applyFactoryLook(id) }   // FB-W
            made = id
        }
        if ok, let made { selectTransition(made) }
        return ok ? made : nil
    }

    /// Role (audio tag) of the clip a transition point sits on: the incoming clip of a cut, else the clip itself.
    static func roleTag(of point: TransitionPoint, on track: Track) -> AudioTag? {
        let id: Clip.ID
        switch point { case .cut(_, let incoming): id = incoming; case .head(let c), .tail(let c): id = c }
        return track.clips.first(where: { $0.id == id }).flatMap { track.role(of: $0) }
    }

    /// Length a new transition of `kind` gets without a user default: kinds tuned to the maintainer's edits (quick fade, slide, whip,
    /// pop) bring their own; the rest use the Preferences.
    static func factoryTransitionDuration(_ kind: TransitionKind, frameDuration fd: Time, defaults: TransitionDefaults) -> Time {
        kind.presetDuration(frameDuration: fd) ?? defaults.duration(for: kind.trackKind, frameDuration: fd)
    }

    // MARK: User defaults (FB-W)

    public func hasTransitionDefault(_ kind: TransitionKind) -> Bool { effectDefaults.hasDefault(transition: kind) }

    /// "Use as Default": the transition's look and length become the default of its kind (every edge).
    @discardableResult
    public func useTransitionAsDefault(_ id: Transition.ID) -> Bool {
        guard let tr = activeTimeline?.transition(id)?.1, !tr.kind.isStinger else { return false }
        var d = effectDefaults
        d.setDefault(from: tr)
        changeEffectDefaults(to: d)
        return true
    }

    /// "Reset Default to Factory": forgets the user default of `kind`.
    public func resetTransitionDefaultToFactory(_ kind: TransitionKind) {
        var d = effectDefaults
        d.removeDefault(transition: kind)
        changeEffectDefaults(to: d)
    }

    /// "Reset": length and look of the transition go back to the user default of its kind, else factory. One undo step.
    @discardableResult
    public func resetTransition(_ id: Transition.ID, defaults: TransitionDefaults = .load()) -> Bool {
        guard let tr = activeTimeline?.transition(id)?.1, let fd = activeTimeline?.format.frameDuration else { return false }
        let user = effectDefaults.transition(tr.kind)
        let factory = Self.factoryTransitionDuration(tr.kind, frameDuration: fd, defaults: defaults)
        return attempt("Reset \(tr.kind.name)") { try $0.resetTransition(id, to: user, factoryDuration: factory) }
    }

    func changeEffectDefaults(to d: EffectDefaults) {
        guard d != effectDefaults else { return }
        effectDefaults = d
        onEffectDefaultsChange?(d)
    }

    /// Clips whose head and tail are both among `targets` (element transitions on both ends share the clip).
    static func clipsWithBothEnds(_ targets: [TransitionTargets.Target]) -> Set<Clip.ID> {
        var heads = Set<Clip.ID>(), tails = Set<Clip.ID>()
        for t in targets {
            switch t.point {
            case .head(let c): heads.insert(c)
            case .tail(let c): tails.insert(c)
            case .cut: break
            }
        }
        return heads.intersection(tails)
    }

    /// FB-G: drops an element transition (Move / Zoom / Pop) on one clip: the head (In), the tail (Out) or both (a drop on
    /// the middle of the clip; half the clip each at most, an end where nothing fits is left out). One undo step; the new
    /// transition (the head one when both) is selected.
    @discardableResult
    public func addElementTransition(kind: TransitionKind, track: Track.ID, clip: Clip.ID, edges: [ClipEdge],
                                     defaults: TransitionDefaults = .load()) -> [Transition.ID] {
        guard kind.isElement, !edges.isEmpty else { return [] }
        var made: [Transition.ID] = []
        let user = effectDefaults.transition(kind)
        let ok = attempt("Apply \(kind.name)") { t in
            let d = user?.duration ?? Self.factoryTransitionDuration(kind, frameDuration: t.format.frameDuration, defaults: defaults)
            made = try t.addElementTransitions(kind: kind, track: track, clip: clip, edges: edges, duration: d)
            for id in made { if let user { try t.applyTransitionDefault(user, to: id) } else { try t.applyFactoryLook(id) } }   // FB-W
        }
        guard ok else { return [] }
        if let first = made.first { selectTransition(first) }
        return made
    }

    /// FB-G: parameters of an element transition (Effect Controls rows).
    public func setTransitionParams(_ id: Transition.ID, _ params: [String: Double], continuesGesture: Bool = false) {
        if !continuesGesture { gestureCounter += 1 }
        attempt("Change Transition", coalescing: "transition:\(id):\(gestureCounter)") { try $0.setTransition(id, params: params) }
    }

    /// Changes duration / alignment (Effect Controls, edge and body drags, the duration dialog). `continuesGesture`: edits of
    /// one drag are one undo step.
    public func setTransition(_ id: Transition.ID, duration: Time? = nil, alignment: TransitionAlignment? = nil,
                              customBefore: Time? = nil, kind: TransitionKind? = nil, continuesGesture: Bool = false) {
        if !continuesGesture { gestureCounter += 1 }
        attempt("Change Transition", coalescing: "transition:\(id):\(gestureCounter)") {
            // A new kind starts from its factory look (parameters; the curve unless it was an own one).
            if let kind { try $0.changeTransitionKind(id, to: kind) }
            try $0.setTransition(id, duration: duration, alignment: alignment, customBefore: customBefore)
        }
    }

    /// Changes the style of a transition (Effect Controls: Easing, Direction, Softness, Motion Blur).
    public func setTransitionStyle(_ id: Transition.ID, easing: EasingCurve? = nil, direction: TransitionDirection? = nil,
                                   softness: Double? = nil, motionBlur: Double? = nil, color: [UInt8]? = nil,
                                   reversed: Bool? = nil, borderWidth: Double? = nil, borderColor: [UInt8]? = nil,
                                   continuesGesture: Bool = false) {
        if !continuesGesture { gestureCounter += 1 }
        attempt("Change Transition", coalescing: "transition:\(id):\(gestureCounter)") {
            try $0.setTransition(id, easing: easing, direction: direction, softness: softness, motionBlur: motionBlur, color: color,
                                 reversed: reversed, borderWidth: borderWidth, borderColor: borderColor)
        }
    }

    /// N6b: project media a Stinger can play (video with a time axis), by name.
    public var stingerCandidates: [MediaRef] {
        (project.media.filter { m in
            guard let info = m.info else { return true }   // not probed yet: offer it, the render shows it once decoded
            return info.video != nil && !info.isStill
        }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// N6b: picks the Stinger clip of a cut transition (Effect Controls). A new clip sets the transition's length to the
    /// clip's and fits its picture to the frame; nil removes it (a plain cut). `cutFraction` alone moves the switch point.
    public func setTransitionStinger(_ id: Transition.ID, media: MediaRef.ID?, cutFraction: Double? = nil,
                                     continuesGesture: Bool = false) {
        if !continuesGesture { gestureCounter += 1 }
        guard let tid = activeTimelineID, let current = activeTimeline?.transition(id)?.transition else { return }
        do {
            try perform("Change Stinger", coalescing: "stinger:\(id):\(gestureCounter)") { p in
                if let media, media != current.stinger?.media {
                    try p.setStinger(transition: id, media: media, cutFraction: cutFraction ?? current.stinger?.cutFraction ?? 0.5, in: tid)
                } else if media == nil {
                    try p.edit(tid) { try $0.setStinger(id, nil) }
                } else if let cutFraction, var s = current.stinger {
                    s.cutFraction = cutFraction
                    try p.edit(tid) { try $0.setStinger(id, s) }
                }
            }
        } catch { setError(Self.message(for: error)) }
    }

    /// Removes the selected transition (Delete). False when none is selected.
    @discardableResult
    public func removeSelectedTransition() -> Bool {
        guard let id = selectedTransition else { return false }
        // Gone already (undo, an edit that removed its cut): forget it and let Delete act on the clips / gap instead.
        guard activeTimeline?.transition(id) != nil else { selectedTransition = nil; return false }
        return removeTransition(id)
    }

    @discardableResult
    public func removeTransition(_ id: Transition.ID) -> Bool {
        let ok = attempt("Clear Transition") { try $0.removeTransition(id) }
        if ok { selectTransition(nil) }
        return ok
    }
}

extension TransitionPoint {
    /// The clip of a one-sided point (head / tail); nil for a cut.
    var elementClip: Clip.ID? {
        switch self {
        case .head(let c), .tail(let c): c
        case .cut: nil
        }
    }
}
