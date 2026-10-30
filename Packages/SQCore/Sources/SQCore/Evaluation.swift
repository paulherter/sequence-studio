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
    /// Crop, Rounded Corners, Gaussian Blur and Ultra Key of the nested clip, applied to the group image as a whole.
    public var effects: ClipEffects
    public var blendMode: BlendMode

    public init(clip: Clip.ID, track: Track.ID, sequence: Timeline.ID, format: SequenceFormat,
                transform: ClipTransform = .identity, cornerRadius: Double = 0,
                effects: ClipEffects? = nil, blendMode: BlendMode = .normal) {
        self.clip = clip; self.track = track; self.sequence = sequence; self.format = format
        self.effects = effects ?? ClipEffects(cornerRadius: cornerRadius); self.blendMode = blendMode
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
    /// Set for a shape generator: the shape evaluated at this instant (`Clip.shapeStyle`). nil with a shape generator =
    /// its Shape effect is switched off (draw nothing).
    public var shape: ShapeStyle?
    /// `t - clip.start`: time since the clip's first frame (drives animations such as text in/out).
    /// For a generator, `sourceTime` equals this.
    public var localTime: Time
    /// The clip's static color settings (resolved against the media by `ColorPipeline.from` in SQRender).
    public var color: ClipColor
    /// Evaluated Crop, Rounded Corners and Gaussian Blur of the clip (`cornerRadius` above is `effects.cornerRadius`).
    /// How a source time between two frames is shown (Time Interpolation of the clip). `.frameBlend`: mix the frame
    /// covering `sourceTime` with the next one by the fractional position (`FrameBlend` in SQRender). Never for a held clip.
    public var interpolation: TimeInterpolation
    /// End of the clip's source range: a blend never reads a frame that starts at or after it. nil = unbounded.
    public var sourceEnd: Time?
    /// Start of the clip's source range: a temporal filter (Denoise, Deflicker, Trails) never reads a frame that ends at or
    /// before it, so no neighbor comes from material cut away (`TemporalWindow`). nil = unbounded.
    public var sourceStart: Time?
    public var effects: ClipEffects
    /// How this layer is combined with the ones below it.
    public var blendMode: BlendMode
    /// Set on the two layers of a cross dissolve (opacities already 1-w and w): the compositor sums them as premultiplied
    /// color instead of compositing B over A. `format` is the canvas the pair is summed in.
    public var pair: PairInfo?
    /// The layer belongs to a transition in progress (either side of a dissolve or dip, or a fade): the engine holds the last
    /// frame rather than draw a half-decoded transition.
    public var inTransition = false
    /// W7.1: sub-frame transforms when a Transform effect's Shutter Angle blurs the motion (`Clip.motionBlur`); nil = sharp.
    public var motionBlur: MotionBlurSamples?
    /// GFX: set on a layer of a graphics clip (the clip is its last group): that clip's length, which text animations anchor
    /// their out phase on (the layer's own id is not a timeline clip).
    public var clipDuration: Time?
    /// The clip's enabled Stabilizer uses Gyroflow: the decoded source frame is warped by the gyro engine with these
    /// options before anything else (playback and export alike). nil = no gyro warp.
    public var gyro: GyroflowOptions?
    /// Transition layers this layer is part of (it lies on a track below them), outermost (highest) first. The compositor
    /// composites each side of a layer apart and combines them (`RenderNode.transition`). Empty for most layers.
    public var stackTransitions: [StackTransition] = []
    /// C6 Picture masks: set on the layers of a matte track (evaluated alone at the same time, eye ignored, transition layers
    /// dropped) that the Picture masks naming this track read. They are not drawn into the picture: the compositor
    /// composites the layers with this tag and the same `groups` (same nesting level) into the matte of that level, and
    /// masks with `pictureTrack` == this id sample it (docs/ARCHITECTURE.md "Picture masks"). nil for every drawn layer.
    public var matteFor: Track.ID?
    /// Nesting level (`groups.count` of the consumers) whose Picture masks read this matte layer; the layer's own `groups`
    /// may go deeper (a nested clip on the matte track). Only meaningful with `matteFor`.
    public var matteDepth = 0

    public enum PairRole: Sendable, Hashable { case first, second }
    public struct PairInfo: Sendable, Hashable {
        public var id: Transition.ID, role: PairRole, format: SequenceFormat
        /// Nesting depth (`groups.count`) of the sequence the pair lives in.
        public var depth: Int
        /// Set for a motion transition: the two sides are composited apart and combined by this (not summed). A side may
        /// be missing (single-sided transition, disabled clip): `.first` is always the outgoing clip, `.second` the incoming.
        public var render: TransitionRender?
        public init(id: Transition.ID, role: PairRole, format: SequenceFormat, depth: Int, render: TransitionRender? = nil) {
            self.id = id; self.role = role; self.format = format; self.depth = depth; self.render = render
        }
    }

    public init(clip: Clip.ID, media: UUID, track: Track.ID, sourceTime: Time, transform: ClipTransform = .identity,
                cornerRadius: Double = 0, groups: [LayerGroup] = [], generator: GeneratorRef? = nil,
                localTime: Time? = nil, color: ClipColor = .default,
                effects: ClipEffects? = nil, blendMode: BlendMode = .normal,
                interpolation: TimeInterpolation = .frameSampling, sourceEnd: Time? = nil) {
        self.sourceEnd = sourceEnd
        self.interpolation = interpolation
        self.color = color
        self.effects = effects ?? ClipEffects(cornerRadius: cornerRadius)
        self.blendMode = blendMode
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
    /// The whole audible span of the clip in top-sequence time (handles included, cut by enclosing nested clips), independent
    /// of the queried range: `timeline` is only the queried piece. A through edit (same media, continuous source) is no edge.
    public var extent: TimeRange

    public init(clip: Clip.ID, media: UUID, track: Track.ID, timeline: TimeRange, sourceStart: Time,
                nests: [AudioNest] = [], speed: ClipSpeed = .normal, reversed: Bool = false,
                keepsPitch: Bool = true, clipStart: Time? = nil, source: TimeRange? = nil,
                envelopes: [TransitionEnvelope] = [], extent: TimeRange? = nil) {
        self.envelopes = envelopes
        self.extent = extent ?? timeline
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
            t = n.clip.sourceInstant(atLocal: t - n.clip.start)
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
    /// `variant`: evaluate for that format variant (its canvas, each clip resolved through `Clip.resolved(for:base:)`);
    /// nil or an unknown id = the sequence's own format. The inner sequence of a nested clip is evaluated in its variant
    /// with the same id when it has one (Nest copies the variants, W5.1) and the nested clip is then not conformed again;
    /// otherwise it is evaluated at its own format and only the nested clip itself is conformed / overridden.
    /// Playback and export evaluate `Project.variantView` instead, which resolves every clip once, not per frame.
    public func videoLayers(at t: Time, sequences: SequenceResolver = { _ in nil },
                            variant: FormatVariant.ID? = nil) -> [LayerRequest] {
        if variant == nil, let span = renderCacheSpans.first(where: { $0.range.contains(t) }),
           let track = tracks.first(where: { $0.kind == .video && $0.isVisible }) {
            return [LayerRequest(clip: span.media, media: span.media, track: track.id, sourceTime: t - span.range.start)]
        }
        return videoLayers(at: t, sequences: sequences, groups: [], visiting: [id], variant: self.variant(variant))
    }

    /// `below`: only tracks with a lower index (the stack under a transition layer); nil = all tracks.
    /// `onlyTrack`: C6 matte evaluation, only that video track (shown or not), its transition layers ignored. `matte`: this
    /// evaluation (and every nested one inside it) makes a matte, so it asks for no Picture mattes of its own (no chains).
    private func videoLayers(at t: Time, sequences: SequenceResolver, groups: [LayerGroup],
                             visiting: Set<Timeline.ID>, variant: FormatVariant? = nil, below: Int? = nil,
                             onlyTrack: Track.ID? = nil, matte: Bool = false) -> [LayerRequest] {
        var out: [LayerRequest] = []
        // C6: the side of each transition layer of this level that plays live at `t` (the other is held at another time
        // and brings its own mattes, evaluated at that time).
        var liveRole: [Clip.ID: LayerRequest.PairRole] = [:]
        let fd = format.frameDuration
        let canvas = variant?.format(base: format) ?? format
        for (trackIndex, track) in tracks.enumerated() where track.kind == .video && (onlyTrack.map { $0 == track.id } ?? track.isVisible) {
            if let below, trackIndex >= below { break }
            // A transition layer on this track: everything below it so far becomes its two sides.
            if onlyTrack == nil, let layer = track.activeTransitionLayer(at: t), let r = layer.resolvedTransitionLayer(frameDuration: fd),
               let i = r.frameIndex(at: t) {
                func stack(at u: Time) -> [LayerRequest] {
                    u == t ? out : videoLayers(at: u, sequences: sequences, groups: groups, visiting: visiting,
                                               variant: variant, below: trackIndex, matte: matte)
                }
                // Before the cut: outgoing live, incoming held at the cut. From the cut: outgoing held on its last frame.
                let first = t < r.cut ? out : (r.cut - fd >= .zero ? stack(at: r.cut - fd) : [])
                let second = t < r.cut ? stack(at: r.cut) : out
                liveRole[layer.id] = t < r.cut ? .first : .second
                let render = Clip.stackRender(r, frameIndex: i)
                func tagged(_ ls: [LayerRequest], _ role: LayerRequest.PairRole) -> [LayerRequest] {
                    let tag = StackTransition(id: layer.id, role: role, format: canvas, depth: groups.count, render: render,
                                              held: role != liveRole[layer.id])
                    return ls.map { var l = $0; l.stackTransitions.insert(tag, at: 0); l.inTransition = true; return l }
                }
                out = []
                if r.kind.isDip {
                    out.append(LayerRequest(clip: layer.id, media: layer.id, track: track.id, sourceTime: .zero, groups: groups,
                                            generator: GeneratorRef.solid(rgb: TransitionMix.dipColor(r.kind, custom: r.color)), localTime: .zero))
                    out[out.count - 1].inTransition = true
                }
                out += tagged(first, .first) + tagged(second, .second)
                continue
            }
            let state = track.videoEntries(at: t, frameDuration: fd)
            if let dip = state.dip {
                out.append(LayerRequest(clip: dip.id, media: dip.id, track: track.id, sourceTime: .zero,
                                        groups: groups, generator: GeneratorRef.solid(rgb: dip.color), localTime: .zero))
            }
            // Two clips of a dissolve pair are summed first; each keeps its own effects, and the pair as a whole gets one blend
            // mode (the incoming clip's, else the outgoing one's: see `RenderNode.tree`).
            for (n, (c0, factor)) in state.items.enumerated() {
                if c0.isTransitionLayer { continue }     // no picture of its own (an unknown kind does nothing)
                // A nested sequence that has the same variant is rendered in it (`Project.variantView` does the same);
                // its clip is then not conformed a second time.
                let innerVariant = variant.flatMap { v in c0.sequence.flatMap(sequences)?.variant(v.id) }
                let c = variant.map { c0.resolved(for: $0, base: format, conformsPicture: innerVariant == nil) } ?? c0
                var tr = c.renderTransform(at: t, frame: Vec2(Double(canvas.displayWidth), Double(canvas.height)))
                tr.opacity *= factor
                let inTransition = state.pair != nil || state.motion != nil || state.dip != nil || state.stinger != nil || factor != 1
                var pair = state.pair.map { LayerRequest.PairInfo(id: $0, role: n == 0 ? .first : .second, format: canvas, depth: groups.count) }
                if let m = state.motion {
                    pair = LayerRequest.PairInfo(id: m.id, role: c.id == m.incoming ? .second : .first, format: canvas,
                                                 depth: groups.count, render: m.render)
                }
                let fx = c.effects(at: t)
                // Posterize Time: this clip reads the source frame of the start of its hold interval.
                let tq = c.posterizedTime(at: t, frameDuration: fd)
                // A total crop leaves nothing of this clip; its partner in a pair still shows.
                if fx.isEmpty { continue }
                let blend = c.opacityEnabled ? c.blendMode : BlendMode.normal
                if let seqID = c.sequence {
                    // An Angles clip plays only its active angle: the other angles are never requested (or decoded).
                    guard !visiting.contains(seqID), let inner = sequences(seqID).map(c.angleView(of:)) else { continue }
                    let g = LayerGroup(clip: c.id, track: track.id, sequence: seqID,
                                       format: innerVariant?.format(base: inner.format) ?? inner.format,
                                       transform: tr, cornerRadius: fx.cornerRadius, effects: fx, blendMode: blend)
                    // A held nested clip shows one instant of the inner sequence.
                    // A held half of a transition (no inner time beyond the edge) shows the clip's edge frame.
                    let innerTime = c.holdFrame ?? c.innerTime(atLocal: c.heldReadTime(at: tq, frameDuration: fd) - c.start,
                                                               innerFrameDuration: inner.format.frameDuration)
                    var inners = inner.videoLayers(at: innerTime, sequences: sequences,
                                                   groups: groups + [g], visiting: visiting.union([seqID]),
                                                   variant: innerVariant, matte: matte)
                    for k in inners.indices {
                        if let pair, inners[k].pair == nil { inners[k].pair = pair }
                        if inTransition { inners[k].inTransition = true }
                    }
                    out += inners
                } else if c.isGraphics {
                    // GFX: the layers composite inside a group of the clip (nested-group path), so the clip's own Motion,
                    // opacity, effects and blend mode apply to the graphic as a whole.
                    guard let doc = c.graphics, doc.layers.contains(where: \.isVisible) else { continue }
                    let g = LayerGroup(clip: c.id, track: track.id, sequence: c.id, format: canvas, transform: tr,
                                       cornerRadius: fx.cornerRadius, effects: fx, blendMode: blend)
                    let local = t - c.start
                    let frame = Vec2(Double(canvas.displayWidth), Double(canvas.height))
                    // G11 Follow: pinned layers drawn at their resolved place (no work and no copy when nothing follows).
                    var layers = doc.layers
                    if doc.hasFollow {
                        layers = doc.resolvingFollow(atLocal: local, canvas: frame,
                                                     keyed: GraphicsTextBounds.measure(clip: c.id, clipDuration: c.duration, canvas: canvas.layoutFormat)).layers
                    }
                    for l in layers where l.isVisible && l.isShown(atLocal: local) {
                        let lc = c.graphicsLayerClip(l)
                        let lfx = lc.effects(at: t)
                        if lfx.isEmpty { continue }
                        var r = LayerRequest(clip: l.id, media: l.id, track: track.id, sourceTime: local,
                                             transform: lc.renderTransform(at: t, frame: frame), cornerRadius: lfx.cornerRadius,
                                             groups: groups + [g], generator: lc.generator, localTime: local,
                                             effects: lfx, blendMode: l.blendMode)
                        r.shape = l.shapeStyle(atLocal: local)
                        // Item lanes: a ranged item's generator (text In/Out) runs on its range, not on the clip. The same
                        // `textTime` feeds Follow's and the monitor's measure.
                        let textTime = l.textTime(atLocal: local)
                        r.localTime = textTime.local
                        r.clipDuration = textTime.duration ?? c.duration
                        r.pair = pair
                        r.inTransition = inTransition
                        out.append(r)
                    }
                } else {
                    let local = t - c.start
                    out.append(LayerRequest(clip: c.id, media: c.media, track: track.id,
                                            sourceTime: c.sourceTime(at: tq, frameDuration: fd),
                                            transform: tr, cornerRadius: fx.cornerRadius,
                                            groups: groups, generator: c.generator, localTime: local, color: c.renderColor(atLocal: local),
                                            effects: fx, blendMode: blend,
                                            interpolation: c.holdFrame == nil && tq == t ? c.timeInterpolation : .frameSampling,
                                            sourceEnd: c.source.end))
                    out[out.count - 1].sourceStart = c.source.start
                    out[out.count - 1].pair = pair
                    out[out.count - 1].inTransition = inTransition
                    out[out.count - 1].shape = c.shapeStyle(atLocal: local)
                    out[out.count - 1].motionBlur = c.motionBlur(at: t, frameDuration: fd, format: canvas, opacityFactor: factor)
                    out[out.count - 1].gyro = c.gyroflowOptions
                }
                if !c.isGraphics, let stamp = c.dateStampRequest(at: t, canvas: canvas.layoutFormat, transform: tr, groups: groups,
                                                                 track: track.id, inTransition: inTransition) {
                    out.append(stamp)
                }
            }
        }
        // C6: the tracks this level's live Picture masks read, each evaluated once at the same `t` and appended as matte
        // layers. A held transition side (and the stack under a transition layer, `below`) got its own mattes at its own
        // time from its evaluation; they carry the side's tag.
        guard !matte else { return out }
        let level = groups.count
        let live = liveRole.isEmpty ? out : out.filter { l in
            l.stackTransitions.allSatisfy { $0.depth != level || liveRole[$0.id] == $0.role }
        }
        for id in pictureMatteTracks(of: live, level: level) {
            let layers = videoLayers(at: t, sequences: sequences, groups: groups, visiting: visiting, variant: variant,
                                     onlyTrack: id, matte: true)
            out += Self.matteLayers(layers, track: id, level: groups.count)
        }
        return out
    }

    /// Audible clip pieces inside `range`. If any audio track is solo only solo tracks sound; muted tracks never.
    /// Nested audio clips are resolved through `sequences`; inner segments come back in top-sequence time.
    /// `b` continues `a` seamlessly: butted, same media (or same nested sequence), source continuous, normal forward speed on
    /// both (the pitch-keeping stretch restarts its grains at every clip, so a retimed cut is never seamless), and the clip
    /// volume (line, fades, Audio Gain) the same on both sides of the cut.
    static func isThroughEdit(_ a: Clip, _ b: Clip) -> Bool {
        guard a.isEnabled, b.isEnabled, a.sequence == b.sequence, a.sequence != nil || a.media == b.media, a.angle == b.angle,
              a.timeline.end == b.start, a.source.end == b.source.start,
              !a.isRetimed, !b.isRetimed, a.holdFrame == nil, b.holdFrame == nil else { return false }
        return a.volume(at: a.timeline.end) == b.volume(at: b.start)
    }

    public func audioSegments(in range: TimeRange, sequences: SequenceResolver = { _ in nil }) -> [AudioSegment] {
        audioSegments(in: range, sequences: sequences, nests: [], visiting: [id])
    }

    private func audioSegments(in range: TimeRange, sequences: SequenceResolver, nests: [AudioNest],
                               visiting: Set<Timeline.ID>) -> [AudioSegment] {
        let audio = tracks.filter { $0.kind == .audio }
        let anySolo = audio.contains { $0.isSolo }
        var out: [AudioSegment] = []
        for track in audio where !track.isMuted && (!anySolo || track.isSolo) {
            // Clips that can sound in `range`: those overlapping it plus one neighbor each side (handles reach into them).
            let first = max(0, track.clipIndex(endingAfter: range.start) - 1)
            var last = first
            while last < track.clips.count, track.clips[last].start < range.end { last += 1 }
            let candidates = track.clips[first..<min(track.clips.count, last + 1)]
            let info = track.audioTransitionInfo(frameDuration: format.frameDuration, for: Set(candidates.map(\.id)))
            for i in candidates.indices {
                let c = track.clips[i]
                let x = info[c.id]
                // A clip in a transition plays on into its handle: outgoing past its end, incoming before its start.
                let extended = TimeRange(start: c.start - (x?.head ?? .zero), end: c.timeline.end + (x?.tail ?? .zero))
                // Audible span for edge fades: a through edit into a neighbor continues the sound, so it is no edge there.
                var extent = extended
                // A chain of through edits is one sound: every piece keys on the whole chain.
                if x?.head == nil {
                    var j = i
                    while j > 0, Self.isThroughEdit(track.clips[j - 1], track.clips[j]) { j -= 1 }
                    extent = TimeRange(start: track.clips[j].start, end: extent.end)
                }
                if x?.tail == nil {
                    var j = i
                    while j + 1 < track.clips.count, Self.isThroughEdit(track.clips[j], track.clips[j + 1]) { j += 1 }
                    extent = TimeRange(start: extent.start, end: track.clips[j].timeline.end)
                }
                guard c.isEnabled, let r = extended.intersection(range), !r.isEmpty else { continue }
                let a = r.start - c.start
                let innerStart = c.sourceInstant(atLocal: a)
                let envelopes = x?.envelopes ?? []
                if let seqID = c.sequence {
                    guard !visiting.contains(seqID), let inner = sequences(seqID).map(c.angleView(of:)) else { continue }
                    let offset = c.start - c.source.start           // inner time + offset = outer time
                    if c.isRetimed {
                        // Retimed nested clip: query the inner range this piece plays, map each inner piece back through the
                        // clip's time mapping (both ends), and anchor the time-stretch grid at the nested clip's start.
                        let innerRange = c.sourceRange(fromLocal: a, toLocal: r.end - c.start)
                        guard !innerRange.isEmpty else { continue }
                        for var s in inner.audioSegments(in: innerRange, sequences: sequences,
                                                         nests: nests + [AudioNest(clip: c, track: track.id)],
                                                         visiting: visiting.union([seqID])) {
                            let x = c.start + c.localTime(forInstant: s.timeline.start)
                            let y = c.start + c.localTime(forInstant: s.timeline.end)
                            guard let piece = TimeRange(start: min(x, y), end: max(x, y)).intersection(r) else { continue }
                            s.timeline = piece
                            s.clipStart = c.start
                            let ex = c.start + c.localTime(forInstant: s.extent.start), ey = c.start + c.localTime(forInstant: s.extent.end)
                            s.extent = TimeRange(start: min(ex, ey), end: max(ex, ey)).intersection(extent) ?? piece
                            out.append(s)
                        }
                        continue
                    }
                    let innerRange = TimeRange(start: innerStart, duration: r.duration)
                    for var s in inner.audioSegments(in: innerRange, sequences: sequences,
                                                     nests: nests + [AudioNest(clip: c, track: track.id, envelopes: envelopes)],
                                                     visiting: visiting.union([seqID])) {
                        s.timeline = TimeRange(start: s.timeline.start + offset, duration: s.timeline.duration)
                        s.clipStart += offset
                        s.extent = TimeRange(start: s.extent.start + offset, duration: s.extent.duration).intersection(extent) ?? s.timeline
                        out.append(s)
                    }
                } else {
                    var source = c.source
                    if let x {
                        // Source time consumed before / after the range: at the speed and direction of the clip's own ends
                        // (a speed track runs on at its first / last speed).
                        let first = c.speedKeys?.segments.first, lastSeg = c.speedKeys?.segments.last
                        let h = (first?.from ?? c.speed).scale(x.head), tl = (lastSeg?.to ?? c.speed).scale(x.tail)
                        let headBack = first?.reversed ?? c.reversed, tailBack = lastSeg?.reversed ?? c.reversed
                        let lo = (headBack ? .zero : h) + (tailBack ? tl : .zero)
                        let hi = (headBack ? h : .zero) + (tailBack ? .zero : tl)
                        var start = max(.zero, source.start - lo), end = source.end + hi
                        if let m = c.mediaDuration { end = min(end, m) }
                        start = min(start, source.start); end = max(end, source.end)
                        source = TimeRange(start: start, end: end)
                    }
                    out.append(AudioSegment(clip: c.id, media: c.audioMediaID, track: track.id, timeline: r,
                                            sourceStart: innerStart, nests: nests, speed: c.speed, reversed: c.reversed,
                                            keepsPitch: c.keepsPitch, clipStart: c.start, source: source, envelopes: envelopes,
                                            extent: extent))
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
