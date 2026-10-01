import Foundation

// Transitions (project file v17).
//
// A transition belongs to a track and is anchored to clip IDs, not to times:
// - a cut transition names the outgoing and the incoming clip that touch at the cut,
// - a single-sided transition names one clip (`incoming` only = fade in at the head, `outgoing` only = fade out at the tail).
// What is stored is the user's intent (kind, requested duration, alignment). What actually plays is *resolved* from the
// current clips (`Track.resolvedTransitions`): the cut must still exist, and the duration is clamped to the handles (source
// media beyond the cut, through speed and reverse). So every edit keeps transitions consistent without touching the edit
// code: a transition whose cut is gone resolves to nothing (and `pruneTransitions` drops it), a slip that shrinks a handle
// re-clamps it, and undoing the slip restores the requested length. No repeated frames are used (clamp instead).

public enum TransitionKind: String, Sendable, Codable, CaseIterable {
    // Video
    case crossDissolve, dipToBlack, dipToWhite
    // Audio
    case constantPower, constantGain

    public var trackKind: TrackKind {
        switch self {
        case .crossDissolve, .dipToBlack, .dipToWhite: .video
        case .constantPower, .constantGain: .audio
        }
    }

    public var name: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .dipToBlack: "Dip to Black"
        case .dipToWhite: "Dip to White"
        case .constantPower: "Constant Power"
        case .constantGain: "Constant Gain"
        }
    }

    public static func kinds(for track: TrackKind) -> [TransitionKind] { allCases.filter { $0.trackKind == track } }
    /// Premiere's defaults: Cross Dissolve for video, Constant Power for audio.
    public static func defaultKind(for track: TrackKind) -> TransitionKind { track == .video ? .crossDissolve : .constantPower }
}

public enum TransitionAlignment: String, Sendable, Codable, CaseIterable {
    case center, startAtCut, endAtCut
    /// Dragged to a custom position over the cut (`Transition.customBefore` frames lie before the cut).
    case custom

    public var name: String {
        switch self {
        case .center: "Center at Cut"
        case .startAtCut: "Start at Cut"
        case .endAtCut: "End at Cut"
        case .custom: "Custom Start"
        }
    }
}

public struct Transition: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: TransitionKind
    /// Requested duration, whole frames of the sequence. The resolved duration may be shorter (handles).
    public var duration: Time
    public var alignment: TransitionAlignment
    /// Used by `.custom`: the part of the transition before the cut, whole frames.
    public var customBefore: Time
    /// Clip before the cut; nil = fade in at the head of `incoming`.
    public var outgoing: Clip.ID?
    /// Clip after the cut; nil = fade out at the tail of `outgoing`.
    public var incoming: Clip.ID?

    public init(id: UUID = UUID(), kind: TransitionKind, duration: Time, alignment: TransitionAlignment = .center,
                customBefore: Time = .zero, outgoing: Clip.ID?, incoming: Clip.ID?) {
        self.id = id; self.kind = kind; self.duration = duration; self.alignment = alignment
        self.customBefore = customBefore; self.outgoing = outgoing; self.incoming = incoming
    }

    public var isSingleSided: Bool { outgoing == nil || incoming == nil }
}

/// What a transition currently is on the timeline.
public struct ResolvedTransition: Sendable, Hashable, Identifiable {
    public var id: Transition.ID
    public var kind: TransitionKind
    public var alignment: TransitionAlignment
    public var outgoing: Clip.ID?, incoming: Clip.ID?
    /// The cut, or for a single-sided transition the clip edge it sits on.
    public var cut: Time
    public var span: TimeRange
    /// Parts of the span before and after `cut`; `before + after == span.duration`.
    public var before: Time, after: Time
    public var requestedDuration: Time
    public var frameDuration: Time

    public var duration: Time { span.duration }
    public var frames: Int { Int(span.duration.frameIndex(frameDuration: frameDuration)) }
    /// The handles ran short and `duration` is less than requested ("insufficient media").
    public var isClamped: Bool { span.duration < requestedDuration }
    public var isSingleSided: Bool { outgoing == nil || incoming == nil }

    /// Frame index inside the span (0 ..< frames) for timeline time `t`; nil outside.
    public func frameIndex(at t: Time) -> Int? {
        guard span.contains(t) else { return nil }
        return min(max(Int((t - span.start).frameIndex(frameDuration: frameDuration)), 0), frames - 1)
    }
}

/// The pure mixing functions of transitions (shared by playback and export).
public struct TransitionMix: Sendable, Equatable {
    public var outgoing: Double, incoming: Double, dip: Double

    /// Weight of the incoming picture on frame `frameIndex` of `frames`: strictly inside 0...1, so a one-frame transition
    /// shows the 50 % blend and the first frame is already slightly mixed (like a dissolve laid over the cut).
    public static func videoWeight(frameIndex: Int, frames: Int) -> Double { Double(frameIndex + 1) / Double(frames + 1) }

    /// Two-sided video mix at incoming weight `w`. Cross dissolve: `(1-w)*A + w*B`. Dips: A fades to the dip colour over the
    /// first half, B fades in from it over the second; at `w = 0.5` the picture is the dip colour only.
    public static func video(_ kind: TransitionKind, weight w: Double) -> TransitionMix {
        switch kind {
        case .dipToBlack, .dipToWhite:
            let o = max(0, 1 - 2 * w), i = max(0, 2 * w - 1)
            return TransitionMix(outgoing: o, incoming: i, dip: 1 - o - i)
        default:
            return TransitionMix(outgoing: 1 - w, incoming: w, dip: 0)
        }
    }

    /// Dip colour as display-encoded RGB bytes.
    public static func dipColor(_ kind: TransitionKind) -> [UInt8] { kind == .dipToWhite ? [255, 255, 255] : [0, 0, 0] }

    /// Audio gains at progress 0...1 through the transition. Constant Power: equal-power (cos/sin), the summed power of
    /// uncorrelated material stays constant. Constant Gain: linear, the summed amplitude of identical material stays constant.
    public static func audioGains(_ kind: TransitionKind, progress p: Double) -> (outgoing: Double, incoming: Double) {
        let p = min(max(p, 0), 1)
        if kind == .constantGain { return (1 - p, p) }
        return (cos(p * .pi / 2), sin(p * .pi / 2))
    }
}

/// The gain curve one clip's audio follows inside a transition span (see `AudioSegment.envelopes`).
public struct TransitionEnvelope: Sendable, Hashable {
    public enum Role: Sendable, Hashable { case outgoing, incoming }
    public var kind: TransitionKind
    public var span: TimeRange
    public var role: Role

    public init(kind: TransitionKind, span: TimeRange, role: Role) { self.kind = kind; self.span = span; self.role = role }

    /// Progress through the span at `t`, 0 before it and 1 after it.
    public func progress(at t: Time) -> Double {
        if t <= span.start { return 0 }
        if t >= span.end { return 1 }
        let a = t - span.start
        return Double(a.value) * Double(span.duration.timescale) / (Double(a.timescale) * Double(span.duration.value))
    }

    public func gain(at t: Time) -> Double {
        let g = TransitionMix.audioGains(kind, progress: progress(at: t))
        return role == .outgoing ? g.outgoing : g.incoming
    }
}

/// Where a transition can be applied.
public enum TransitionPoint: Sendable, Hashable {
    case cut(outgoing: Clip.ID, incoming: Clip.ID)
    case head(Clip.ID)
    case tail(Clip.ID)
}

// MARK: Resolution

extension Track {
    private static let unbounded: Int64 = 1 << 40

    /// Largest duration in frames the handles allow for this alignment (0 = none), given the portion limits.
    private static func maxFrames(_ alignment: TransitionAlignment, customBefore cb: Int64, beforeMax b: Int64, afterMax a: Int64) -> Int64 {
        switch alignment {
        case .center: return min(2 * b + 1, 2 * a)
        case .startAtCut: return a
        case .endAtCut: return b
        case .custom: return cb <= b ? cb + a : b
        }
    }

    /// Parts before and after the cut for a duration of `d` frames.
    private static func split(_ alignment: TransitionAlignment, customBefore cb: Int64, _ d: Int64) -> (before: Int64, after: Int64) {
        let b: Int64
        switch alignment {
        case .center: b = d / 2
        case .startAtCut: b = 0
        case .endAtCut: b = d
        case .custom: b = min(cb, d)
        }
        return (b, d - b)
    }

    /// The current, playable form of every transition of this track, in timeline order.
    public func resolvedTransitions(frameDuration fd: Time) -> [ResolvedTransition] {
        var out: [ResolvedTransition] = []
        for tr in transitions {
            if let r = resolve(tr, frameDuration: fd) { out.append(r) }
        }
        return out.sorted { $0.span.start < $1.span.start }
    }

    /// Index of clip `id`, looking next to `hint` first (the evaluation loops already know where they are).
    func clipIndex(_ id: Clip.ID, near hint: Int?) -> Int? {
        if let h = hint, !clips.isEmpty {
            for i in max(0, h - 2)...min(clips.count - 1, h + 2) where i >= 0 && clips[i].id == id { return i }
        }
        return clips.firstIndex { $0.id == id }
    }

    /// Index of the first clip that ends after `t` (binary search; clips are sorted and never overlap).
    func clipIndex(endingAfter t: Time) -> Int {
        var lo = 0, hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clips[mid].timeline.end > t { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// `budgeted`: also respect the clip's other (earlier) transition. A clip holds at most its own length of transition
    /// frames: the head transition keeps what it asks for (it comes first on the timeline), the tail one gets what is left.
    func resolve(_ tr: Transition, frameDuration fd: Time, hint: Int? = nil, budgeted: Bool = true) -> ResolvedTransition? {
        guard tr.kind.trackKind == kind else { return nil }
        func frames(_ t: Time) -> Int64 { max(0, t.frameIndex(frameDuration: fd)) }
        func cap(_ t: Time?) -> Int64 { t.map { min(frames($0), Self.unbounded) } ?? Self.unbounded }
        let want = max(1, frames(tr.duration))
        let cb = frames(tr.customBefore)

        func make(cut: Time, d: Int64, b: Int64, a: Int64) -> ResolvedTransition {
            ResolvedTransition(id: tr.id, kind: tr.kind, alignment: tr.alignment, outgoing: tr.outgoing, incoming: tr.incoming,
                               cut: cut, span: TimeRange(start: cut - fd * b, duration: fd * d), before: fd * b, after: fd * a,
                               requestedDuration: fd * want, frameDuration: fd)
        }

        switch (tr.outgoing, tr.incoming) {
        case let (o?, i?):
            guard let oi = clipIndex(o, near: hint), oi + 1 < clips.count, clips[oi + 1].id == i,
                  clips[oi].timeline.end == clips[oi + 1].start else { return nil }
            let out = clips[oi], inc = clips[oi + 1]
            let bMax = min(cap(inc.headHandle), max(0, frames(out.duration) - (budgeted ? headPortion(of: o, except: tr.id, fd) : 0)))
            let aMax = min(cap(out.tailRoom), frames(inc.duration))
            let d = min(want, Self.maxFrames(tr.alignment, customBefore: cb, beforeMax: bMax, afterMax: aMax))
            guard d >= 1 else { return nil }
            let (b, a) = Self.split(tr.alignment, customBefore: cb, d)
            return make(cut: inc.start, d: d, b: b, a: a)
        case let (nil, i?):
            guard let ci = clipIndex(i, near: hint) else { return nil }
            let c = clips[ci]
            let d = min(want, frames(c.duration))
            guard d >= 1 else { return nil }
            return make(cut: c.start, d: d, b: 0, a: d)
        case let (o?, nil):
            guard let ci = clipIndex(o, near: hint) else { return nil }
            let c = clips[ci]
            let d = min(want, max(0, frames(c.duration) - (budgeted ? headPortion(of: o, except: tr.id, fd) : 0)))
            guard d >= 1 else { return nil }
            return make(cut: c.timeline.end, d: d, b: d, a: 0)
        case (nil, nil):
            return nil
        }
    }

    /// Frames of clip `o` taken by the transition that sits on its head (the earlier one), before any budgeting.
    private func headPortion(of o: Clip.ID, except id: Transition.ID, _ fd: Time) -> Int64 {
        guard let h = transitions.first(where: { $0.incoming == o && $0.id != id }),
              let r = resolve(h, frameDuration: fd, budgeted: false) else { return 0 }
        return r.after.frameIndex(frameDuration: fd)
    }

    /// Largest whole-frame duration the handles allow for `tr` right now (0 = nothing fits).
    func maxTransitionFrames(_ tr: Transition, frameDuration fd: Time) -> Int64 {
        var probe = tr
        probe.duration = fd * Self.unbounded
        return resolve(probe, frameDuration: fd).map { Int64($0.frames) } ?? 0
    }

    /// Drops transitions whose cut or clip no longer exists (or that nothing fits into any more).
    mutating func pruneTransitions(frameDuration fd: Time) {
        guard !transitions.isEmpty else { return }
        let keep = transitions.filter { resolve($0, frameDuration: fd) != nil }
        if keep.count != transitions.count { transitions = keep }
    }

    // MARK: Evaluation helpers (video / audio)

    /// What the track shows at `t`: an optional solid dip layer (bottom) and the clips with an opacity factor.
    /// Without a transition at `t` this is just the clip under `t` at opacity 1.
    func videoEntries(at t: Time, frameDuration fd: Time)
        -> (dip: (id: Transition.ID, color: [UInt8])?, pair: Transition.ID?, items: [(clip: Clip, opacity: Double)]) {
        let k = clipIndex(endingAfter: t)
        let base = k < clips.count && clips[k].timeline.contains(t) ? clips[k] : nil
        guard !transitions.isEmpty else { return (nil, nil, base.map { [($0, 1.0)] } ?? []) }
        // Only transitions on the clip at `t` and its neighbours can reach `t` (a span never leaves the clips it joins).
        let near = Set(clips[max(0, k - 1)..<min(clips.count, k + 2)].map(\.id))
        for tr in transitions where tr.outgoing.map(near.contains) == true || tr.incoming.map(near.contains) == true {
            guard let r = resolve(tr, frameDuration: fd, hint: k), let i = r.frameIndex(at: t) else { continue }
            let w = TransitionMix.videoWeight(frameIndex: i, frames: r.frames)
            let dipKind = r.kind == .dipToBlack || r.kind == .dipToWhite
            let dip = dipKind ? (r.id, TransitionMix.dipColor(r.kind)) : nil
            switch (r.outgoing, r.incoming) {
            case let (o?, i?):
                guard let oc = clip(o), let ic = clip(i) else { continue }
                if dipKind {
                    let m = TransitionMix.video(r.kind, weight: w)
                    return (dip, nil, [(oc, m.outgoing), (ic, m.incoming)])
                }
                // Cross dissolve: premultiplied sum A*(1-w) + B*w in linear light (the compositor's `pair` node).
                return (nil, r.id, [(oc, 1 - w), (ic, w)])
            case let (nil, i?):
                guard let ic = clip(i) else { continue }
                return (dip, nil, [(ic, w)])
            case let (o?, nil):
                guard let oc = clip(o) else { continue }
                return (dip, nil, [(oc, 1 - w)])
            case (nil, nil):
                continue
            }
        }
        return (nil, nil, base.map { [($0, 1.0)] } ?? [])
    }

    /// Per clip: how far its audio extends into its handles and the gain envelopes of its audio transitions.
    /// Only for the transitions that touch `ids` (the clips the caller is about to read).
    func audioTransitionInfo(frameDuration fd: Time, for ids: Set<Clip.ID>)
        -> [Clip.ID: (head: Time, tail: Time, envelopes: [TransitionEnvelope])] {
        guard kind == .audio, !transitions.isEmpty else { return [:] }
        var info: [Clip.ID: (head: Time, tail: Time, envelopes: [TransitionEnvelope])] = [:]
        for tr in transitions where tr.outgoing.map(ids.contains) == true || tr.incoming.map(ids.contains) == true {
            guard let r = resolve(tr, frameDuration: fd) else { continue }
            if let o = r.outgoing {
                var e = info[o] ?? (.zero, .zero, [])
                e.tail = max(e.tail, r.after)
                e.envelopes.append(TransitionEnvelope(kind: r.kind, span: r.span, role: .outgoing))
                info[o] = e
            }
            if let i = r.incoming {
                var e = info[i] ?? (.zero, .zero, [])
                e.head = max(e.head, r.before)
                e.envelopes.append(TransitionEnvelope(kind: r.kind, span: r.span, role: .incoming))
                info[i] = e
            }
        }
        return info
    }
}

// MARK: Timeline API

extension Timeline {
    /// One second in whole frames of the sequence (Premiere's initial default duration of both kinds).
    public static func defaultTransitionDuration(frameDuration fd: Time) -> Time {
        fd * max(1, Int64((Double(fd.timescale) / Double(fd.value)).rounded()))
    }

    public func resolvedTransitions(on track: Track.ID) -> [ResolvedTransition] {
        self.track(track)?.resolvedTransitions(frameDuration: format.frameDuration) ?? []
    }

    /// Looks a transition up by ID.
    public func transition(_ id: Transition.ID) -> (track: Track.ID, transition: Transition)? {
        for t in tracks { if let tr = t.transitions.first(where: { $0.id == id }) { return (t.id, tr) } }
        return nil
    }

    /// Largest whole-frame duration the clip handles allow for the transition now.
    public func maxTransitionFrames(_ id: Transition.ID) -> Int64 {
        guard let (tid, tr) = transition(id), let t = track(tid) else { return 0 }
        return t.maxTransitionFrames(tr, frameDuration: format.frameDuration)
    }

    /// The cut or clip edge on `track` nearest to `t`: where Apply Video/Audio Transition lands.
    public func transitionPoint(near t: Time, on track: Track.ID) -> TransitionPoint? {
        guard let tr = self.track(track) else { return nil }
        var best: (TransitionPoint, Time)?
        func consider(_ p: TransitionPoint, at time: Time) {
            let d = time >= t ? time - t : t - time
            if best == nil || d < best!.1 { best = (p, d) }
        }
        let cs = tr.clips
        for (i, c) in cs.enumerated() {
            let prevTouches = i > 0 && cs[i - 1].timeline.end == c.start
            let nextTouches = i + 1 < cs.count && cs[i + 1].start == c.timeline.end
            if prevTouches { consider(.cut(outgoing: cs[i - 1].id, incoming: c.id), at: c.start) } else { consider(.head(c.id), at: c.start) }
            if !nextTouches { consider(.tail(c.id), at: c.timeline.end) }
        }
        return best?.0
    }

    /// Whole frames, at least 1.
    private func snapped(_ d: Time) -> Time {
        let fd = format.frameDuration
        return fd * max(1, d.frameIndex(frameDuration: fd))
    }

    private func trackIndex(_ id: Track.ID) throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        return i
    }

    /// Applies a transition at a cut (`outgoing` and `incoming` touching) or to one clip edge (the other side nil). A transition
    /// already at that place is replaced. The duration is snapped to whole frames and clamped to the handles; when no frame
    /// fits, `insufficientMedia`. Returns the new transition's ID.
    @discardableResult
    public mutating func addTransition(kind: TransitionKind, track trackID: Track.ID, outgoing: Clip.ID?, incoming: Clip.ID?,
                                       duration: Time, alignment: TransitionAlignment = .center,
                                       customBefore: Time = .zero) throws -> Transition.ID {
        let ti = try trackIndex(trackID)
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        guard kind.trackKind == tracks[ti].kind else { throw EditError.wrongTrackKind }
        guard outgoing != nil || incoming != nil else { throw EditError.clipNotFound }
        for id in [outgoing, incoming].compactMap({ $0 }) where tracks[ti].clip(id) == nil { throw EditError.clipNotFound }
        if let o = outgoing, let i = incoming {
            guard let oc = tracks[ti].clip(o), let ic = tracks[ti].clip(i), oc.timeline.end == ic.start else { throw EditError.notACut }
        }
        let fd = format.frameDuration
        var tr = Transition(kind: kind, duration: snapped(duration), alignment: alignment,
                            customBefore: fd * max(0, customBefore.frameIndex(frameDuration: fd)), outgoing: outgoing, incoming: incoming)
        let fit = tracks[ti].maxTransitionFrames(tr, frameDuration: fd)
        guard fit >= 1 else { throw EditError.insufficientMedia }
        tr.duration = min(tr.duration, fd * fit)
        // One transition per clip edge (Premiere): a new one replaces what already sits on the same edge(s).
        tracks[ti].transitions.removeAll { other in
            (outgoing != nil && other.outgoing == outgoing) || (incoming != nil && other.incoming == incoming)
        }
        tracks[ti].transitions.append(tr)
        return tr.id
    }

    @discardableResult
    public mutating func addTransition(point: TransitionPoint, kind: TransitionKind, track: Track.ID, duration: Time,
                                       alignment: TransitionAlignment = .center) throws -> Transition.ID {
        switch point {
        case let .cut(o, i): try addTransition(kind: kind, track: track, outgoing: o, incoming: i, duration: duration, alignment: alignment)
        case let .head(c): try addTransition(kind: kind, track: track, outgoing: nil, incoming: c, duration: duration, alignment: alignment)
        case let .tail(c): try addTransition(kind: kind, track: track, outgoing: c, incoming: nil, duration: duration, alignment: alignment)
        }
    }

    /// Changes a transition's properties. The duration is snapped to whole frames and clamped to the handles. A change of
    /// alignment keeps the duration as far as the handles allow.
    public mutating func setTransition(_ id: Transition.ID, kind: TransitionKind? = nil, duration: Time? = nil,
                                       alignment: TransitionAlignment? = nil, customBefore: Time? = nil) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }),
              let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        let fd = format.frameDuration
        var tr = tracks[ti].transitions[ni]
        if let kind {
            guard kind.trackKind == tracks[ti].kind else { throw EditError.wrongTrackKind }
            tr.kind = kind
        }
        if let alignment { tr.alignment = alignment }
        if let customBefore { tr.customBefore = fd * max(0, customBefore.frameIndex(frameDuration: fd)) }
        if let duration { tr.duration = snapped(duration) }
        let fit = tracks[ti].maxTransitionFrames(tr, frameDuration: fd)
        if fit >= 1 { tr.duration = min(tr.duration, fd * fit) }
        tracks[ti].transitions[ni] = tr
    }

    public mutating func removeTransition(_ id: Transition.ID) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        tracks[ti].transitions.removeAll { $0.id == id }
    }

    /// Drops transitions whose cut is gone or whose handles hold no frame any more. `Project.edit` calls this after every edit.
    public mutating func pruneTransitions() {
        let fd = format.frameDuration
        for i in tracks.indices { tracks[i].pruneTransitions(frameDuration: fd) }
    }
}
