import Foundation

/// How timeline time became the source time of one evaluated layer: the nested clips around it (outermost first) and
/// the clip itself, found once in the timeline. `sourceTime(at:)` then answers for a nearby timeline time with the
/// clips' own time mappings only, without evaluating the timeline again (the Magic matte look-ahead asks for the next
/// four ticks on every tick).
///
/// It answers only where the full evaluation gives the same time, and nil everywhere else: a time outside one of the
/// clips (a clip edge was crossed, a transition half held beyond it) or under a transition layer. The caller evaluates
/// the timeline for such a time.
public struct LayerTimePath: Sendable {
    private struct Step: Sendable {
        var clip: Clip
        /// Frame duration of the sequence the clip is on.
        var frame: Time
        /// A nested clip: its sequence's frame duration. nil: the layer's own clip.
        var innerFrame: Time?
        /// The shown video tracks above the clip's track: a transition layer on one of them holds the clip.
        var above: ArraySlice<Track>
    }

    private var steps: [Step] = []

    /// nil when the layer is not a file or nested clip found on its track at `t` (a graphics item, a transition half
    /// outside its clip, a side of a transition layer), or when the path does not give the layer's own source time.
    public init?(_ layer: LayerRequest, at t: Time, in timeline: Timeline, sequences: SequenceResolver) {
        guard layer.stackTransitions.isEmpty else { return nil }
        var tl = timeline
        var u = t
        func step(_ clip: Clip.ID, on track: Track.ID, innerFrame: Time?) -> Step? {
            guard let i = tl.tracks.firstIndex(where: { $0.id == track }) else { return nil }
            let k = tl.tracks[i].clipIndex(endingAfter: u)
            guard k < tl.tracks[i].clips.count, tl.tracks[i].clips[k].id == clip else { return nil }
            let above = tl.tracks[(i + 1)...].filter { $0.kind == .video && $0.isVisible }
            return Step(clip: tl.tracks[i].clips[k], frame: tl.format.frameDuration, innerFrame: innerFrame, above: above[...])
        }
        for g in layer.groups {
            guard g.sequence != g.clip, let inner = sequences(g.sequence),
                  let s = step(g.clip, on: g.track, innerFrame: inner.format.frameDuration), s.clip.sequence == g.sequence,
                  let next = Self.inner(s, at: u) else { return nil }
            steps.append(s)
            u = next
            tl = s.clip.angleView(of: inner)
        }
        guard let s = step(layer.clip, on: layer.track, innerFrame: nil), s.clip.sequence == nil, !s.clip.isGraphics else { return nil }
        steps.append(s)
        guard sourceTime(at: t) == layer.sourceTime else { return nil }
    }

    /// The source time the layer reads at timeline time `t`; nil when the evaluation has to say (see the type).
    public func sourceTime(at t: Time) -> Time? {
        var u = t
        for s in steps {
            guard let next = Self.inner(s, at: u) else { return nil }
            u = next
        }
        return u
    }

    /// The time one step maps `u` to (a nested clip: time in its sequence; the layer's clip: source time), as
    /// `Timeline.videoLayers` does it.
    private static func inner(_ s: Step, at u: Time) -> Time? {
        guard s.clip.timeline.contains(u) else { return nil }
        for track in s.above where track.activeTransitionLayer(at: u) != nil { return nil }
        let tq = s.clip.posterizedTime(at: u, frameDuration: s.frame)
        guard let innerFrame = s.innerFrame else { return s.clip.sourceTime(at: tq, frameDuration: s.frame) }
        return s.clip.holdFrame ?? s.clip.innerTime(atLocal: s.clip.heldReadTime(at: tq, frameDuration: s.frame) - s.clip.start,
                                                    innerFrameDuration: innerFrame)
    }
}
