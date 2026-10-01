import Foundation

/// A nested-sequence clip that a layer sits inside. The layer's own coordinates are in the inner sequence;
/// the group describes how that inner picture is placed into the parent.
public struct LayerGroup: Sendable, Hashable {
    /// The nested clip and the track it sits on, in the parent sequence.
    public var clip: Clip.ID, track: Track.ID
    /// The inner sequence and its format (size of the offscreen image the inner layers are composited into).
    public var sequence: Timeline.ID
    public var format: SequenceFormat
    /// Evaluated transform (incl. opacity) and corner radius of the nested clip at this instant.
    public var transform: ClipTransform
    public var cornerRadius: Double

    public init(clip: Clip.ID, track: Track.ID, sequence: Timeline.ID, format: SequenceFormat,
                transform: ClipTransform = .identity, cornerRadius: Double = 0) {
        self.clip = clip; self.track = track; self.sequence = sequence; self.format = format
        self.transform = transform; self.cornerRadius = cornerRadius
    }
}

/// What is visible at one instant for one track.
///
/// Nested sequences are flattened into the layer list, bottom to top, each layer tagged with the nested clips
/// (`groups`, outermost first) it lives in. Composition order for the compositor, per group:
/// 1. composite the group's inner layers (in order) into a transparent offscreen image of `group.format`
///    size, each inner layer with its own transform, opacity and corner radius (recursively for deeper groups);
/// 2. treat that image as a layer of the nested clip: apply the group's corner radius (in the image's own
///    pixels), then its `transform` (anchor, scale, rotation, position, in the parent sequence's pixels),
///    then its opacity as one factor for the whole image (not per inner layer).
/// A layer with empty `groups` belongs to the top sequence. Transforms are deliberately not multiplied into
/// the inner layers' transforms: rotation after non-uniform scale is not a scale+rotate of the parts, and
/// group opacity is not the product of the inner opacities.
public struct LayerRequest: Sendable, Hashable {
    public var clip: Clip.ID, media: UUID, track: Track.ID
    /// `Clip.sourceTime(at:)`: the source frame time shown at this instant (through speed and reverse), in the clip's own
    /// (inner) timeline.
    public var sourceTime: Time
    /// Evaluated (clamped) transform of the clip at this instant.
    public var transform: ClipTransform
    /// Rounded Corners radius in canvas pixels of the clip's own frame, >= 0.
    public var cornerRadius: Double
    /// Enclosing nested clips, outermost first. Empty for layers of the top sequence.
    public var groups: [LayerGroup]
    /// Set for a generator clip (text layer): there is no media to decode, render this instead.
    public var generator: GeneratorRef?
    /// `t - clip.start`: time since the clip's first frame (drives animations such as text in/out).
    /// For a generator, `sourceTime` equals this.
    public var localTime: Time
    /// The clip's static colour settings (resolved against the media by `ColorPipeline.from` in SQRender).
    public var color: ClipColor
    /// Set on the two layers of a cross dissolve (opacities already 1-w and w): the compositor sums them as premultiplied
    /// colour instead of compositing B over A. `format` is the canvas the pair is summed in.
    public var pair: PairInfo?

    public enum PairRole: Sendable, Hashable { case first, second }
    public struct PairInfo: Sendable, Hashable {
        public var id: Transition.ID, role: PairRole, format: SequenceFormat
        /// Nesting depth (`groups.count`) of the sequence the pair lives in.
        public var depth: Int
        public init(id: Transition.ID, role: PairRole, format: SequenceFormat, depth: Int) {
            self.id = id; self.role = role; self.format = format; self.depth = depth
        }
    }

    public init(clip: Clip.ID, media: UUID, track: Track.ID, sourceTime: Time, transform: ClipTransform = .identity,
                cornerRadius: Double = 0, groups: [LayerGroup] = [], generator: GeneratorRef? = nil,
                localTime: Time? = nil, color: ClipColor = .default) {
        self.color = color
        self.generator = generator; self.localTime = localTime ?? sourceTime
        self.clip = clip; self.media = media; self.track = track; self.sourceTime = sourceTime
        self.transform = transform; self.cornerRadius = cornerRadius; self.groups = groups
    }
}

/// A nested audio clip an `AudioSegment` sits inside.
public struct AudioNest: Sendable, Hashable {
    public var clip: Clip
    public var track: Track.ID
    /// Audio transitions of the nested clip (gain curves in the nest's own outer time).
    public var envelopes: [TransitionEnvelope]
    public init(clip: Clip, track: Track.ID, envelopes: [TransitionEnvelope] = []) {
        self.clip = clip; self.track = track; self.envelopes = envelopes
    }
}

/// One clip's contribution to a timeline range.
public struct AudioSegment: Sendable, Hashable {
    public var clip: Clip.ID, media: UUID, track: Track.ID
    /// In top-sequence time, also for segments inside nested sequences. `sourceStart` is media time.
    public var timeline: TimeRange, sourceStart: Time
    /// Enclosing nested audio clips, outermost first. Empty for segments of the top sequence.
    public var nests: [AudioNest]
    /// Clip speed. Source position advances `speed` source seconds per timeline second.
    public var speed: ClipSpeed
    /// Reversed: audio reads the source backwards from `sourceStart` (the source time at `timeline.start`).
    public var reversed: Bool
    /// Time-stretch (pitch kept) when speed is not 100 %; false = resample.
    public var keepsPitch: Bool
    /// Start of the whole clip in top-sequence time (anchor of the time-stretch grain grid, so any split of a
    /// range into render blocks gives identical samples).
    public var clipStart: Time
    /// The clip's used media range (what retimed audio may read; nothing outside it is played).
    public var source: TimeRange
    /// Audio transition gain curves of the clip (outgoing / incoming / fade), applied per sample on top of the volume.
    /// An outgoing or incoming segment is extended into its handle: `timeline` and `source` cover it.
    public var envelopes: [TransitionEnvelope]

    public init(clip: Clip.ID, media: UUID, track: Track.ID, timeline: TimeRange, sourceStart: Time,
                nests: [AudioNest] = [], speed: ClipSpeed = .normal, reversed: Bool = false,
                keepsPitch: Bool = true, clipStart: Time? = nil, source: TimeRange? = nil,
                envelopes: [TransitionEnvelope] = []) {
        self.envelopes = envelopes
        self.clip = clip; self.media = media; self.track = track
        self.timeline = timeline; self.sourceStart = sourceStart; self.nests = nests
        self.speed = speed; self.reversed = reversed; self.keepsPitch = keepsPitch
        self.clipStart = clipStart ?? timeline.start
        self.source = source ?? TimeRange(start: sourceStart, duration: timeline.duration)
    }

    /// Product of the enclosing nested clips' volume at top-sequence time `t` (1 when not nested).
    /// The segment's own clip volume is separate (evaluate it in inner time).
    /// Product of this segment's own transition curves at top-sequence time `t` (1 without transitions).
    public func envelopeGain(at t: Time) -> Double {
        var g = 1.0
        for e in envelopes { g *= e.gain(at: t) }
        return g
    }

    public func nestGain(at t: Time) -> Double {
        var t = t, gain = 1.0
        for n in nests {
            for e in n.envelopes { gain *= e.gain(at: t) }
            gain *= n.clip.volume(at: t)
            t = n.clip.source.start + (t - n.clip.start)
        }
        return gain
    }
}

/// Resolves a nested clip's sequence. `nil` = unknown sequence (the clip contributes nothing).
public typealias SequenceResolver = (Timeline.ID) -> Timeline?

extension Timeline {
    /// Visible layers at `t`, bottom to top (first video track first). Hidden tracks and gaps are omitted.
    /// Nested clips are resolved through `sequences` (recursively, with the source-time mapping); without a
    /// resolver they contribute nothing. A sequence that (corruptly) contains itself is skipped, not followed.
    public func videoLayers(at t: Time, sequences: SequenceResolver = { _ in nil }) -> [LayerRequest] {
        videoLayers(at: t, sequences: sequences, groups: [], visiting: [id])
    }

    private func videoLayers(at t: Time, sequences: SequenceResolver, groups: [LayerGroup],
                             visiting: Set<Timeline.ID>) -> [LayerRequest] {
        var out: [LayerRequest] = []
        let fd = format.frameDuration
        for track in tracks where track.kind == .video && track.isVisible {
            let state = track.videoEntries(at: t, frameDuration: fd)
            if let dip = state.dip {
                out.append(LayerRequest(clip: dip.id, media: dip.id, track: track.id, sourceTime: .zero,
                                        groups: groups, generator: GeneratorRef.solid(rgb: dip.color), localTime: .zero))
            }
            for (n, (c, factor)) in state.items.enumerated() {
                var tr = c.transform(at: t)
                tr.opacity *= factor
                let pair = state.pair.map { LayerRequest.PairInfo(id: $0, role: n == 0 ? .first : .second, format: format, depth: groups.count) }
                if let seqID = c.sequence {
                    guard !visiting.contains(seqID), let inner = sequences(seqID) else { continue }
                    let g = LayerGroup(clip: c.id, track: track.id, sequence: seqID, format: inner.format,
                                       transform: tr, cornerRadius: c.effects(at: t).cornerRadius)
                    var inners = inner.videoLayers(at: c.source.start + (t - c.start), sequences: sequences,
                                                   groups: groups + [g], visiting: visiting.union([seqID]))
                    if let pair { for k in inners.indices where inners[k].pair == nil { inners[k].pair = pair } }
                    out += inners
                } else {
                    let local = t - c.start
                    out.append(LayerRequest(clip: c.id, media: c.media, track: track.id,
                                            sourceTime: c.sourceTime(at: t, frameDuration: fd),
                                            transform: tr, cornerRadius: c.effects(at: t).cornerRadius,
                                            groups: groups, generator: c.generator, localTime: local, color: c.color))
                    out[out.count - 1].pair = pair
                }
            }
        }
        return out
    }

    /// Audible clip pieces inside `range`. If any audio track is solo only solo tracks sound; muted tracks never.
    /// Nested audio clips are resolved through `sequences`; inner segments come back in top-sequence time.
    public func audioSegments(in range: TimeRange, sequences: SequenceResolver = { _ in nil }) -> [AudioSegment] {
        audioSegments(in: range, sequences: sequences, nests: [], visiting: [id])
    }

    private func audioSegments(in range: TimeRange, sequences: SequenceResolver, nests: [AudioNest],
                               visiting: Set<Timeline.ID>) -> [AudioSegment] {
        let audio = tracks.filter { $0.kind == .audio }
        let anySolo = audio.contains { $0.isSolo }
        var out: [AudioSegment] = []
        for track in audio where !track.isMuted && (!anySolo || track.isSolo) {
            // Clips that can sound in `range`: those overlapping it plus one neighbour each side (handles reach into them).
            let first = max(0, track.clipIndex(endingAfter: range.start) - 1)
            var last = first
            while last < track.clips.count, track.clips[last].start < range.end { last += 1 }
            let candidates = track.clips[first..<min(track.clips.count, last + 1)]
            let info = track.audioTransitionInfo(frameDuration: format.frameDuration, for: Set(candidates.map(\.id)))
            for c in candidates {
                let x = info[c.id]
                // A clip in a transition plays on into its handle: outgoing past its end, incoming before its start.
                let extended = TimeRange(start: c.start - (x?.head ?? .zero), end: c.timeline.end + (x?.tail ?? .zero))
                guard let r = extended.intersection(range), !r.isEmpty else { continue }
                let a = r.start - c.start
                let innerStart = c.reversed ? c.source.end - c.speed.scale(a) : c.source.start + c.speed.scale(a)
                let envelopes = x?.envelopes ?? []
                if let seqID = c.sequence {
                    guard !visiting.contains(seqID), let inner = sequences(seqID) else { continue }
                    let offset = c.start - c.source.start           // inner time + offset = outer time
                    let innerRange = TimeRange(start: innerStart, duration: r.duration)
                    for var s in inner.audioSegments(in: innerRange, sequences: sequences,
                                                     nests: nests + [AudioNest(clip: c, track: track.id, envelopes: envelopes)],
                                                     visiting: visiting.union([seqID])) {
                        s.timeline = TimeRange(start: s.timeline.start + offset, duration: s.timeline.duration)
                        s.clipStart += offset
                        out.append(s)
                    }
                } else {
                    var source = c.source
                    if let x {
                        let h = c.speed.scale(x.head), tl = c.speed.scale(x.tail)
                        let lo = c.reversed ? tl : h, hi = c.reversed ? h : tl      // source time consumed before / after the range
                        var start = max(.zero, source.start - lo), end = source.end + hi
                        if let m = c.mediaDuration { end = min(end, m) }
                        start = min(start, source.start); end = max(end, source.end)
                        source = TimeRange(start: start, end: end)
                    }
                    out.append(AudioSegment(clip: c.id, media: c.media, track: track.id, timeline: r,
                                            sourceStart: innerStart, nests: nests, speed: c.speed, reversed: c.reversed,
                                            keepsPitch: c.keepsPitch, clipStart: c.start, source: source, envelopes: envelopes))
                }
            }
        }
        return out
    }

    /// Sorted, unique clip starts and ends over all tracks.
    public func editPoints() -> [Time] {
        var set = Set<Time>()
        for track in tracks {
            for c in track.clips { set.insert(c.start); set.insert(c.timeline.end) }
        }
        return set.sorted()
    }

    /// End of the last clip; `.zero` when empty.
    public var duration: Time { tracks.map(\.end).max() ?? .zero }
}
