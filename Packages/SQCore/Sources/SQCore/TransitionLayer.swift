import Foundation

// Transition layer (DECISIONS 2026-10-05, project file v53).
//
// A transition placed as its own clip on a video track, like an Adjustment Layer: a generator clip (`GeneratorRef.transitionLayer`)
// whose payload is a `TransitionLayer` (kind, style and the cut). It transitions everything composited below its track in the
// same sequence, so a stack of layers (talking head, b-roll, photos) goes through one transition without nesting.
//
// The cut is stored in the clip's own source time, like a marker on its content: a head trim (which moves the generator's
// source start with the clip start) leaves it where it is on the timeline, a move carries it along. It resolves clamped
// into the clip and onto the frame grid (`Clip.resolvedTransitionLayer`).
//
// What plays (`Timeline.videoLayers`): the stack below the layer's track is evaluated twice, as the two sides of the shared
// transition engine. Outgoing = the stack before the cut, incoming = the stack from the cut on. There is only one timeline
// below, so each side holds its edge frame on the far side of the cut: before the cut the outgoing side plays live and the
// incoming side shows the stack's first frame at the cut; from the cut on the outgoing side shows the stack's last frame
// before the cut and the incoming side plays live (Premiere's frozen handles). Progress runs over the whole span like a
// cut transition with custom alignment (`TransitionMix.videoWeight`, the kind's easing), so every existing kind looks the
// same as on a clip edge. Stingers and element transitions (one picture) are not layer kinds.

extension GeneratorRef {
    public static let transitionLayer = "transitionLayer"
}

/// The payload of a transition layer clip.
public struct TransitionLayer: Sendable, Hashable, Codable {
    public var kind: TransitionKind
    /// The cut in the clip's own source time: on the timeline at `clip.start + (cut - clip.source.start)`.
    public var cut: Time
    /// Style; nil = the kind's default (as `Transition`).
    public var easing: EasingCurve?
    public var direction: TransitionDirection?
    /// v89: travels the other way; nil = not reversed.
    public var reversed: Bool?
    public var softness: Double?
    public var motionBlur: Double?
    /// Through Color (`Transition.color`).
    public var color: [UInt8]?
    /// Parameters as `Transition.params` (Zoom In / Out's Amount); optional in the payload, nil = none.
    public var params: [String: Double]?

    public init(kind: TransitionKind, cut: Time) { self.kind = kind; self.cut = cut }

    public var effectiveEasing: EasingCurve { easing ?? kind.defaultEasing }
    public var effectiveDirection: TransitionDirection { direction ?? TransitionKind.defaultDirection }
    public var effectiveSoftness: Double { softness ?? TransitionKind.defaultSoftness }
    public var effectiveMotionBlur: Double { motionBlur ?? kind.defaultMotionBlur }

    public static let payloadVersion = 1

    var payload: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> TransitionLayer? { try? JSONDecoder().decode(TransitionLayer.self, from: data) }
}

extension TransitionKind {
    /// Kinds a transition layer can take: video transitions that mix two pictures.
    public var isLayerKind: Bool { trackKind == .video && !isStinger && !isElement }
    public static var layerKinds: [TransitionKind] { allCases.filter(\.isLayerKind) }
}

/// One transition layer a `LayerRequest` takes part in (`LayerRequest.stackTransitions`, outermost first).
public struct StackTransition: Sendable, Hashable {
    /// The transition layer clip.
    public var id: Clip.ID
    /// `.first`: the request belongs to the outgoing stack (before the cut), `.second` to the incoming one.
    public var role: LayerRequest.PairRole
    /// Canvas the two sides are composited in.
    public var format: SequenceFormat
    /// Nesting depth (`groups.count`) of the sequence the layer lives in.
    public var depth: Int
    /// How the two side images are combined (a dissolve or dip is `.sum` with the side opacities).
    public var render: TransitionRender
    /// C6: this side is held at another time than the level (its edge frame), so its Picture masks read only the mattes
    /// evaluated with it (possibly none), never the level's live ones.
    public var held: Bool
    public init(id: Clip.ID, role: LayerRequest.PairRole, format: SequenceFormat, depth: Int, render: TransitionRender,
                held: Bool = false) {
        self.id = id; self.role = role; self.format = format; self.depth = depth; self.render = render; self.held = held
    }
}

extension Clip {
    public var isTransitionLayer: Bool { generator?.kind == GeneratorRef.transitionLayer }

    /// The payload of a transition layer clip; nil for any other clip.
    public var transitionLayer: TransitionLayer? {
        guard let g = generator, g.kind == GeneratorRef.transitionLayer else { return nil }
        return TransitionLayer.decode(g.payload)
    }

    /// Timeline time of a stored cut (source time of the clip), unclamped.
    func timelineTime(ofSource s: Time) -> Time { start + (s - source.start) }

    /// The cut on the timeline, clamped into the clip (not yet snapped to frames).
    public var transitionLayerCut: Time? {
        guard let l = transitionLayer else { return nil }
        return min(max(timelineTime(ofSource: l.cut), start), timeline.end)
    }

    /// What the layer plays: the cut (clamped into the clip, snapped to the frame grid), before / after parts and the style.
    /// `outgoing` / `incoming` are nil (the sides are the stack below, not clips). nil for another clip, an unknown kind or
    /// a span shorter than a frame.
    public func resolvedTransitionLayer(frameDuration fd: Time) -> ResolvedTransition? {
        guard let l = transitionLayer, l.kind.isLayerKind, let raw = transitionLayerCut else { return nil }
        let span = timeline
        guard span.duration.frameIndex(frameDuration: fd) >= 1 else { return nil }
        let cut = min(max(raw.snapped(to: fd), span.start), span.end)
        let before = cut - span.start, after = span.end - cut
        let alignment: TransitionAlignment = before == .zero ? .startAtCut : after == .zero ? .endAtCut
            : before == span.duration.halvedFrames(fd) ? .center : .custom
        var r = ResolvedTransition(id: id, kind: l.kind, alignment: alignment, outgoing: nil, incoming: nil, cut: cut, span: span,
                                  before: before, after: after, requestedDuration: span.duration, frameDuration: fd,
                                  easing: l.effectiveEasing, direction: l.renderDirection, softness: l.effectiveSoftness,
                                  motionBlur: l.effectiveMotionBlur)
        r.color = l.color
        r.zoomAmount = l.zoomAmount
        return r
    }

    /// How the two sides combine on frame `i` of `r` (the clip-edge engine's maths).
    static func stackRender(_ r: ResolvedTransition, frameIndex i: Int) -> TransitionRender {
        if r.kind.isMotion {
            return TransitionRender.evaluate(kind: r.kind, direction: r.direction, softness: r.softness, motionBlur: r.motionBlur,
                                             easing: r.easing, frameIndex: i, frames: r.frames,
                                             zoomAmount: r.zoomAmount ?? TransitionRender.zoomAmount, zoomSettles: r.zoomAmount != nil)
        }
        let w = r.easing.mixWeight(TransitionMix.videoWeight(frameIndex: i, frames: r.frames))
        let m = TransitionMix.video(r.kind, weight: w)
        return TransitionRender(outgoing: TransitionSide(opacity: m.outgoing), incoming: TransitionSide(opacity: m.incoming),
                                compose: .sum)
    }
}

extension Time {
    /// Whole frames of half this duration, rounded down (the center split of a transition).
    func halvedFrames(_ fd: Time) -> Time { fd * (frameIndex(frameDuration: fd) / 2) }
}

extension Track {
    /// The enabled transition layer clip under `t`, if any.
    func activeTransitionLayer(at t: Time) -> Clip? {
        let k = clipIndex(endingAfter: t)
        guard k < clips.count else { return nil }
        let c = clips[k]
        return c.timeline.contains(t) && c.isEnabled && c.isTransitionLayer ? c : nil
    }
}

// MARK: Edits

extension Project {
    /// Places a transition layer on a video track (overwrite, like any generator drop) with its cut in the middle (whole frames,
    /// the earlier one for an odd length). Throws `.wrongTrackKind` for an audio track or a kind that is not a layer kind,
    /// otherwise like `addGeneratorClip`.
    @discardableResult
    public mutating func addTransitionLayer(kind: TransitionKind, in timeline: Timeline.ID, at start: Time, track: Track.ID,
                                            duration: Time) throws -> Clip.ID {
        guard kind.isLayerKind else { throw EditError.wrongTrackKind }
        let fd = self.timeline(timeline)?.frameDuration ?? Time(1, 30)
        let d = duration.snapped(to: fd)
        let layer = TransitionLayer(kind: kind, cut: d.halvedFrames(fd))
        return try addGeneratorClip(kind: GeneratorRef.transitionLayer, payload: layer.payload,
                                    payloadVersion: TransitionLayer.payloadVersion, name: "Transition Layer",
                                    in: timeline, at: start, track: track, duration: d)
    }

    /// Any transition layer in any sequence (gates ProjectFile v53).
    public var containsTransitionLayers: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains(where: \.isTransitionLayer) } }
    }
}

extension Timeline {
    private func transitionLayerClip(_ id: Clip.ID) throws -> (track: Int, clip: Clip, layer: TransitionLayer) {
        guard let m = find(id), let l = m.clip.transitionLayer else { throw EditError.clipNotFound }
        if tracks[m.track].isLocked { throw EditError.trackLocked }
        return (m.track, m.clip, l)
    }

    private mutating func writeLayer(_ l: TransitionLayer, into c: Clip, track: Int) {
        var c = c
        c.generator?.payload = l.payload
        tracks[track].replace(c)
    }

    /// The resolved transition layer clip `id`, or nil.
    public func resolvedTransitionLayer(_ id: Clip.ID) -> ResolvedTransition? {
        find(id)?.clip.resolvedTransitionLayer(frameDuration: frameDuration)
    }

    /// Moves the cut (center marker) of transition layer `id` to timeline time `t`, snapped to whole frames and clamped into the
    /// clip. Returns the cut as applied. Throws `.clipNotFound` for another clip, `.trackLocked` on a locked track.
    @discardableResult
    public mutating func setTransitionLayerCut(_ id: Clip.ID, to t: Time) throws -> Time {
        var (ti, c, l) = try transitionLayerClip(id)
        let cut = min(max(t.snapped(to: frameDuration), c.start), c.timeline.end)
        l.cut = c.source.start + (cut - c.start)
        writeLayer(l, into: c, track: ti)
        return cut
    }

    /// Room on the clip's own track before its start and after its end (nil = unbounded after).
    private func room(around c: Clip, track ti: Int) -> (before: Time, after: Time?) {
        let others = tracks[ti].clips.filter { $0.id != c.id }
        let prevEnd = others.filter { $0.timeline.end <= c.start }.map(\.timeline.end).max() ?? .zero
        let next = others.filter { $0.start >= c.timeline.end }.map(\.start).min()
        return (c.start - prevEnd, next.map { $0 - c.timeline.end })
    }

    /// Moves one edge of transition layer `id` by `delta` (positive = right, whole frames). `symmetric` (the plain drag): the
    /// other edge moves the opposite way by the same amount, so the cut keeps its place and both parts change alike;
    /// otherwise (Option) only this edge moves. Neither edge passes the cut, at least one frame stays, and neighbors on the
    /// track and the timeline start stop the drag. Returns how far the dragged edge moved.
    @discardableResult
    public mutating func resizeTransitionLayer(_ id: Clip.ID, edge: ClipEdge, by delta: Time, symmetric: Bool) throws -> Time {
        let (ti, c, _) = try transitionLayerClip(id)
        guard let r = c.resolvedTransitionLayer(frameDuration: frameDuration) else { throw EditError.clipNotFound }
        let fd = frameDuration
        let room = room(around: c, track: ti)
        // Growth of the dragged part (positive = longer) and how far it may go.
        var g = (edge == .head ? -delta : delta).snapped(to: fd)
        let own = edge == .head ? r.before : r.after, other = edge == .head ? r.after : r.before
        func roomOn(_ e: ClipEdge) -> Time? { e == .head ? room.before : room.after }
        let otherEdge: ClipEdge = edge == .head ? .tail : .head
        if g > .zero {
            if let x = roomOn(edge) { g = min(g, x) }
            if symmetric, let x = roomOn(otherEdge) { g = min(g, x) }
        } else if g < .zero {
            var shrink = own
            if symmetric { shrink = min(shrink, other) }
            // At least one frame stays.
            let total = r.span.duration
            let keep = symmetric ? Time.scaled(total - fd, by: 1, over: 2).snappedDown(fd) : total - fd
            shrink = min(shrink, max(.zero, keep))
            g = max(g, -shrink)
        }
        if g == .zero { return .zero }
        // Trim each edge (head + = shorter, tail + = longer). A head trim moves the generator's source start with it, so the
        // stored cut keeps its timeline place.
        _ = try trim(id, edge: edge, by: edge == .head ? -g : g)
        if symmetric { _ = try trim(id, edge: otherEdge, by: otherEdge == .head ? -g : g) }
        return edge == .head ? -g : g
    }

    /// Places transition layer `id` around its fixed cut: `.center` half before (whole frames), `.startAtCut` all after,
    /// `.endAtCut` all before. `.custom` changes nothing. The length stays; a neighbor in the way throws `.collision`.
    public mutating func setTransitionLayerAlignment(_ id: Clip.ID, _ alignment: TransitionAlignment) throws {
        let (_, c, _) = try transitionLayerClip(id)
        guard let r = c.resolvedTransitionLayer(frameDuration: frameDuration) else { throw EditError.clipNotFound }
        let before: Time
        switch alignment {
        case .center: before = r.span.duration.halvedFrames(frameDuration)
        case .startAtCut: before = .zero
        case .endAtCut: before = r.span.duration
        case .custom: return
        }
        try place(id, start: r.cut - before, duration: r.span.duration, cut: r.cut)
    }

    /// Sets the length of transition layer `id` (whole frames, at least one) around its fixed cut, keeping the share before the
    /// cut. A neighbor in the way throws `.collision`.
    public mutating func setTransitionLayerDuration(_ id: Clip.ID, _ duration: Time) throws {
        let (_, c, _) = try transitionLayerClip(id)
        guard let r = c.resolvedTransitionLayer(frameDuration: frameDuration) else { throw EditError.clipNotFound }
        let fd = frameDuration
        let n = max(1, duration.frameIndex(frameDuration: fd))
        let total = max(1, r.span.duration.frameIndex(frameDuration: fd))
        let b = r.before.frameIndex(frameDuration: fd)
        let nb = min(n, Int64((Double(b) * Double(n) / Double(total)).rounded()))
        try place(id, start: r.cut - fd * nb, duration: fd * n, cut: r.cut)
    }

    /// Sets the clip to `[start, start + duration)` keeping its cut at `cut` (one change, checked against the track).
    private mutating func place(_ id: Clip.ID, start: Time, duration: Time, cut: Time) throws {
        var (ti, c, l) = try transitionLayerClip(id)
        guard start >= .zero else { throw EditError.collision }
        // A generator's content has no limits: move its source start with the start, like a head trim.
        c.source.start += start - c.start
        c.animation = c.animation.shifted(by: c.start - start)
        c.effects = c.effects.map { $0.shifted(by: c.start - start) }
        c.source.duration = duration
        c.start = start
        l.cut = c.source.start + (cut - c.start)
        c.generator?.payload = l.payload
        var work = tracks
        work[ti].replace(c)
        guard work[ti].isConsistent else { throw EditError.collision }
        tracks = work
    }

    /// Changes the kind or style of transition layer `id`. Throws `.wrongTrackKind` when the kind is not a layer kind.
    public mutating func setTransitionLayer(_ id: Clip.ID, _ change: (inout TransitionLayer) -> Void) throws {
        var (ti, c, l) = try transitionLayerClip(id)
        change(&l)
        guard l.kind.isLayerKind else { throw EditError.wrongTrackKind }
        c.generator?.payload = l.payload
        tracks[ti].replace(c)
    }
}

extension Time {
    /// Largest whole multiple of `fd` at or before `self`.
    func snappedDown(_ fd: Time) -> Time { fd * frameIndex(frameDuration: fd) }
}
