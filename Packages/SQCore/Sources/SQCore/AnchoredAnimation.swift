import Foundation

// W7.3 AnimationStackUnify: the one animation model. Clip keyframes (`AnimatedProperty`, `ClipEffect` parameters) and
// anchored in/out animations (text clips, Caption Looks, text templates) are both `KeyframeTrack`s evaluated by
// `KeyframeTrack.value(at:)`; this file adds the anchoring (in = clip start, out = clip end, never scaled) and the
// `AnimationSample` every renderer folds into its layer (TextGenerator in the monitor, CaptionBurnIn in the export).
// Moved from SQText unchanged in behavior and on-disk shape (text payloads, `.sqtext` templates, Caption Look presets):
// project files v26-v28 decode to the same values and render the same pixels (SQText LegacyAnimationGoldenTests).

/// Shape of one keyframe segment, expressed as SQCore interpolation plus bezier handles.
/// Overshoot is a bezier whose handle leaves 0...1 (`dy > 1`); hold is `Interpolation.hold`.
public enum SegmentShape: String, Sendable, Hashable, Codable {
    case linear, easeIn, easeOut, easeInOut
    /// Ease-out that passes the end value and settles back (back-out, cubic-bezier 0.34, 1.56, 0.64, 1).
    case overshoot
    /// Keeps the start value until the next key.
    case hold

    public var interpolation: Interpolation {
        switch self {
        case .linear: .linear
        case .hold: .hold
        default: .bezier
        }
    }

    /// (outgoing handle of the segment's first key, incoming handle of its second key).
    public var handles: (out: EaseHandle, in: EaseHandle) {
        switch self {
        case .linear, .hold: (.linear, .linear)
        case .easeIn: (EaseHandle(dx: 1.0 / 3, dy: 0), EaseHandle(dx: 1.0 / 3, dy: 1))
        case .easeOut: (EaseHandle(dx: 1.0 / 3, dy: 1), EaseHandle(dx: 1.0 / 3, dy: 0))
        case .easeInOut: (EaseHandle(dx: 1.0 / 3, dy: 0), EaseHandle(dx: 1.0 / 3, dy: 0))
        case .overshoot: (EaseHandle(dx: 0.34, dy: 1.56), EaseHandle(dx: 0.36, dy: 0))
        }
    }
}

/// One animated property (e.g. "scale", "opacity", "positionX", "positionY", "rotation") as an SQCore track.
/// Key times are template-local: 0 = start of the animation, `KeyframeTemplate.duration` = its end.
/// A Hold Ahead key is stored as Hold: these tracks are saved inside text payloads, templates and Caption Looks, which
/// the project version gate (ProjectFile+V77.swift) does not see.
public struct AnimationTrack: Sendable, Hashable, Codable {
    public var property: String
    public var track: KeyframeTrack<Double> { didSet { Self.plainHolds(&track) } }

    public init(property: String, track: KeyframeTrack<Double>) {
        self.property = property; self.track = track
        Self.plainHolds(&self.track)
    }

    private enum CodingKeys: String, CodingKey { case property, track }

    /// Through the init above: an old payload's leader and helper pair folds to a Hold Ahead while decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(property: try c.decode(String.self, forKey: .property), track: try c.decode(KeyframeTrack<Double>.self, forKey: .track))
    }

    private static func plainHolds(_ t: inout KeyframeTrack<Double>) {
        for i in t.keys.indices where t.keys[i].interpolation == .holdAhead { t.keys[i].interpolation = .hold }
    }

    /// Builds a track from (time, value, shape of the segment starting at that key). Key ids are deterministic
    /// (by index) so built-in templates compare and encode stably.
    public init(property: String, keys: [(time: Time, value: Double, shape: SegmentShape)]) {
        var ks: [Keyframe<Double>] = keys.enumerated().map { i, k in
            Keyframe(id: Self.keyID(i), time: k.time, value: k.value, interpolation: k.shape.interpolation,
                     inHandle: .linear, outHandle: k.shape.handles.out)
        }
        for i in ks.indices.dropFirst() { ks[i].inHandle = keys[i - 1].shape.handles.in }
        self.init(property: property, track: KeyframeTrack(keys: ks))
    }

    static func keyID(_ i: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i + 1))! }

    /// nil for an empty track; clamped to the first/last value outside the keyed range.
    public func value(at t: Time) -> Double? { track.value(at: t) }
}

/// What a template's local time 0 is measured from when it is played on a clip.
public enum AnimationAnchor: String, Sendable, Hashable, Codable {
    /// In-animation: template-local time t plays at clip time t.
    case start
    /// Out-animation: template-local 0...duration plays at clip time (clipDuration - duration)...clipDuration.
    case end
}

/// Reusable animation: property tracks over template-local time plus a default playback length.
///
/// `anchor` decides how the template is placed on a clip (see `AnimationAnchor`, `resolved(clipDuration:)`);
/// durations are never scaled to the clip.
///
/// On-disk shape (TextTemplate format v3): `{"anchor": "start"|"end", "duration": Time, "tracks": [{"property", "track": {"keys": [...]}}]}`.
/// `anchor` is absent in v1/v2 files and then reads as `.start`.
/// Decoding also reads the v1 shape (normalized `Fraction` times, `easing` enum), converting key times to
/// `duration * fraction` and easings to SQCore handles.
public struct KeyframeTemplate: Sendable, Hashable, Codable {
    public var tracks: [AnimationTrack]
    /// Default playback length of the animation (rational timeline time).
    public var duration: Time
    public var anchor: AnimationAnchor
    /// Per character/word/line animation (TextAnimator.swift); plays alongside the property tracks, which move the whole
    /// block. Absent in older files; written only when set, so templates without one encode as before.
    public var textAnimator: TextAnimator?
    /// True: after `duration` the animation starts over for as long as the clip plays (wave, hop, pulse). The last key
    /// should equal the first so the cycle is seamless. Only meaningful for `.start` templates. Absent in older files;
    /// written only when true.
    public var loops: Bool
    public init(tracks: [AnimationTrack], duration: Time, anchor: AnimationAnchor = .start, textAnimator: TextAnimator? = nil,
                loops: Bool = false) {
        self.tracks = tracks; self.duration = duration; self.anchor = anchor; self.textAnimator = textAnimator; self.loops = loops
    }
    public static let none = KeyframeTemplate(tracks: [], duration: .zero)
    public func track(for property: String) -> AnimationTrack? { tracks.first { $0.property == property } }
    /// Value of `property` at template-local time `t`; nil if the property has no keys.
    /// A looping template repeats every `duration` from template time 0 on (earlier times clamp as usual).
    public func value(of property: String, at t: Time) -> Double? {
        track(for: property)?.value(at: loops ? Self.wrap(t, period: duration) : t)
    }

    /// `t` modulo `period` as an exact rational. Negative `t` and a non-positive period are returned unchanged.
    public static func wrap(_ t: Time, period: Time) -> Time {
        guard period > .zero, t >= period else { return t }
        // t = a/b, period = c/d  ->  (a*d mod c*b) / (b*d)
        let a = Int128(t.value), b = Int128(t.timescale), c = Int128(period.value), d = Int128(period.timescale)
        var num = (a * d) % (c * b)
        var den = b * d
        var x = num.magnitude, y = den.magnitude
        while y != 0 { (x, y) = (y, x % y) }
        if x > 1 { num /= Int128(x); den /= Int128(x) }
        if let n = Int64(exactly: num), let m = Int64(exactly: den) { return Time(n, m) }
        let r = (Double(t.value) / Double(t.timescale)).truncatingRemainder(dividingBy: Double(period.value) / Double(period.timescale))
        return Time(Int64((r * 1e9).rounded()), 1_000_000_000)
    }

    private enum CodingKeys: String, CodingKey { case tracks, duration, anchor, textAnimator, loops }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dur = try c.decode(Time.self, forKey: .duration)
        duration = dur
        anchor = try c.decodeIfPresent(AnimationAnchor.self, forKey: .anchor) ?? .start
        textAnimator = try c.decodeIfPresent(TextAnimator.self, forKey: .textAnimator)
        loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? false
        if let v2 = try? c.decode([AnimationTrack].self, forKey: .tracks) {
            tracks = v2
        } else {
            let legacy = try c.decode([LegacyTrack].self, forKey: .tracks)
            tracks = try legacy.map { try $0.migrated(duration: dur) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(duration, forKey: .duration)
        try c.encode(anchor, forKey: .anchor)
        try c.encodeIfPresent(textAnimator, forKey: .textAnimator)
        if loops { try c.encode(true, forKey: .loops) }
    }
}

/// Errors from decoding old template formats.
public enum KeyframeTemplateError: Error, Equatable, Sendable {
    /// A v1 key time (duration * fraction) does not fit the Int64 rational.
    case timeOverflow
}

// MARK: - Format v1 (normalized Fraction times + Easing enum)

private struct LegacyTrack: Decodable {
    struct Fraction: Decodable { let numerator: Int64; let denominator: Int64 }
    struct Key: Decodable {
        let time: Fraction
        let value: Double
        let easing: SegmentShape
    }
    let property: String
    let keyframes: [Key]

    /// time = duration * fraction; with a zero duration the fraction is read as seconds (nothing else is meaningful).
    /// Throws `KeyframeTemplateError.timeOverflow` if a key time does not fit Int64 after the multiplication.
    func migrated(duration: Time) throws -> AnimationTrack {
        let keys = try keyframes.map { k -> (time: Time, value: Double, shape: SegmentShape) in
            let d = max(k.time.denominator, 1)
            if duration == .zero { return (Time(k.time.numerator, d), k.value, k.easing) }
            let (v, o1) = duration.value.multipliedReportingOverflow(by: k.time.numerator)
            let (s, o2) = duration.timescale.multipliedReportingOverflow(by: d)
            guard !o1, !o2 else { throw KeyframeTemplateError.timeOverflow }
            return (Time(v, s), k.value, k.easing)
        }
        return AnimationTrack(property: property, keys: keys)
    }
}

// Playback of anchored templates on a clip. Durations are never scaled: an in-animation starts at clip
// start, an out-animation ends at clip end. Clip-local `Time` everywhere in this file.

extension KeyframeTemplate {
    /// Clip time at which template-local time 0 plays (may be negative when the clip is shorter than an
    /// end-anchored animation: the first part of the animation is then simply never seen).
    public func startOffset(clipDuration: Time) -> Time {
        anchor == .start ? .zero : clipDuration - duration
    }

    /// Value of `property` at clip time `clipTime`. Exact (no key rewriting). Before the animation it holds
    /// the first key's value, after it the last key's value; nil if the property has no keys.
    public func value(of property: String, clipTime: Time, clipDuration: Time) -> Double? {
        value(of: property, at: clipTime - startOffset(clipDuration: clipDuration))
    }

    /// The tracks with key times moved to clip-local time (`startOffset` added).
    ///
    /// Clamping: keys are kept inside `0...clipDuration`. When the animation does not fit (clip shorter than
    /// the animation, or a non-positive clip), keys outside the range are dropped and replaced by boundary keys
    /// at 0 / `clipDuration` carrying the exact value there; curve handles of a cut bezier segment are then only
    /// approximated. For a non-positive clip duration each track collapses to one key at 0 (value at clip time 0).
    /// Use `value(of:clipTime:clipDuration:)` for exact evaluation.
    public func resolved(clipDuration: Time) -> [AnimationTrack] {
        let offset = startOffset(clipDuration: clipDuration)
        let lo = Time.zero, hi = max(clipDuration, .zero)
        return tracks.map { AnimationTrack(property: $0.property, track: Self.place($0.track, offset: offset, lo: lo, hi: hi)) }
    }

    static func place(_ track: KeyframeTrack<Double>, offset: Time, lo: Time, hi: Time) -> KeyframeTrack<Double> {
        guard let first = track.keys.first, let last = track.keys.last else { return track }
        func shifted(_ k: Keyframe<Double>) -> Keyframe<Double> { var c = k; c.time = k.time + offset; return c }
        func boundary(_ t: Time, _ like: Keyframe<Double>) -> Keyframe<Double> {
            Keyframe(id: like.id, time: t, value: track.value(at: t - offset) ?? like.value, interpolation: .linear,
                     inHandle: .linear, outHandle: .linear)
        }
        var out: [Keyframe<Double>] = []
        // Later wins on identical times, so the order makes the lower boundary win for an empty range.
        if last.time + offset > hi { out.append(boundary(hi, last)) }
        out += track.keys.map(shifted).filter { $0.time >= lo && $0.time <= hi }
        if first.time + offset < lo { out.append(boundary(lo, first)) }
        return KeyframeTrack(keys: out)
    }
}

/// An in-animation (start-anchored) plus an out-animation (end-anchored) on one clip.
///
/// Both sides are optional. The anchors of the passed templates are overridden (`in` -> `.start`, `out` -> `.end`).
/// Crossing policy: the in-animation has priority. The out-animation starts at `clipDuration - out.duration`,
/// but never before the in-animation ended; if that leaves no room (in-animation as long as the clip or longer)
/// the out-animation does not play at all. When it is pushed later it is cut by the clip end (not scaled).
/// Per property, while the out-animation plays its value wins if it animates that property, else the
/// in-animation's (clamped) value applies.
public struct AnimationSet: Sendable, Hashable, Codable {
    public var animationIn: KeyframeTemplate?
    public var animationOut: KeyframeTemplate?

    public init(in animationIn: KeyframeTemplate?, out animationOut: KeyframeTemplate?) {
        self.animationIn = animationIn.map { var a = $0; a.anchor = .start; return a }
        self.animationOut = animationOut.map { var a = $0; a.anchor = .end; return a }
    }

    /// Clip time where the out-animation starts; nil if there is none or it does not play (see type docs).
    public func outStart(clipDuration: Time) -> Time? {
        guard let out = animationOut else { return nil }
        let start = max(clipDuration - out.duration, animationIn?.duration ?? .zero, .zero)
        return start < clipDuration ? start : nil
    }

    public func value(of property: String, clipTime: Time, clipDuration: Time) -> Double? {
        let inValue = animationIn?.value(of: property, at: clipTime)
        guard let out = animationOut else { return inValue }
        guard let start = outStart(clipDuration: clipDuration) else { return inValue }
        let outValue = out.value(of: property, at: clipTime - start)
        return clipTime >= start ? (outValue ?? inValue) : (inValue ?? outValue)
    }

    /// One template played by its own anchor (start = in, end = out), as text templates and Caption Looks carry it.
    /// Nil for nil or `.none` (nothing to play).
    public init?(single template: KeyframeTemplate?) {
        guard let template, template != .none else { return nil }
        self = template.anchor == .start ? AnimationSet(in: template, out: nil) : AnimationSet(in: nil, out: template)
    }

    /// The block-level animation at clip time `clipTime`: the properties "opacity" (clamped to 0...1), "scale",
    /// "positionX"/"positionY" (sequence px, y down) and "rotation" (degrees), each at rest where no side animates it.
    public func sample(clipTime: Time, clipDuration: Time) -> AnimationSample {
        func v(_ p: String, _ d: Double) -> Double { value(of: p, clipTime: clipTime, clipDuration: clipDuration) ?? d }
        return AnimationSample(opacity: min(1, max(0, v("opacity", 1))), scale: v("scale", 1),
                               offset: Vec2(v("positionX", 0), v("positionY", 0)), rotation: v("rotation", 0))
    }
}

/// An anchored animation evaluated at one instant (`AnimationSet.sample`). The renderer folds it into its layer: opacity
/// multiplies, scale and rotation act about the block center, `offset` moves it.
public struct AnimationSample: Sendable, Hashable {
    public var opacity: Double
    /// Linear, not clamped (an overshoot may pass 1; consumers clamp at 0 where they need to).
    public var scale: Double
    public var offset: Vec2
    /// Degrees, clockwise on screen.
    public var rotation: Double
    public init(opacity: Double = 1, scale: Double = 1, offset: Vec2 = .zero, rotation: Double = 0) {
        self.opacity = opacity; self.scale = scale; self.offset = offset; self.rotation = rotation
    }
    public static let rest = AnimationSample()
    public var isRest: Bool { self == .rest }
}

// MARK: - Retiming (authoring only)

extension KeyframeTemplate {
    /// Copy with template-local key times scaled by `newDuration / duration` (exact rational arithmetic; results beyond Int64 are approximated/clamped, never trap; key ids,
    /// values, shapes and anchor unchanged). For authoring/editing ("make this animation longer"), never used
    /// by anchored playback: playing a template on a clip does not scale it (see `resolved(clipDuration:)`).
    ///
    /// Degenerate cases: a negative `newDuration` is treated as zero; with zero target all keys collapse to time 0
    /// (per track the last key wins); a zero source duration has no scale, so key times stay as they are.
    public func retimed(toDuration newDuration: Time) -> KeyframeTemplate {
        let target = max(newDuration, .zero)
        var copy = self
        copy.duration = target
        guard duration > .zero, target != duration else { return copy }
        copy.tracks = tracks.map { track in
            let scaled = KeyframeTrack(keys: track.track.keys.map { k -> Keyframe<Double> in
                var c = k
                c.time = Self.scale(k.time, from: duration, to: target)
                return c
            })
            return AnimationTrack(property: track.property, track: scaled)
        }
        return copy
    }

    /// t * to / from as a reduced rational, exact whenever the Int128 intermediates do not overflow and the reduced
    /// result fits Int64. Otherwise (pathological inputs only) it falls back to a Double ratio at nanosecond
    /// resolution, and a value beyond +-Int64.max seconds is clamped. Never traps.
    static func scale(_ t: Time, from: Time, to: Time) -> Time {
        let n1 = Int128(t.value) * Int128(to.value)                        // < 2^126
        let d1 = Int128(t.timescale) * Int128(to.timescale)
        let (n2, o1) = n1.multipliedReportingOverflow(by: Int128(from.timescale))
        let (d2, o2) = d1.multipliedReportingOverflow(by: Int128(from.value))
        if !o1 && !o2 {
            var num = n2, den = d2
            var a = num.magnitude, b = den.magnitude
            while b != 0 { (a, b) = (b, a % b) }
            if a > 1 { num /= Int128(a); den /= Int128(a) }
            if let n = Int64(exactly: num), let d = Int64(exactly: den) { return Time(n, d) }
        }
        let r = Double(t.value) / Double(t.timescale) * (Double(to.value) / Double(to.timescale))
            / (Double(from.value) / Double(from.timescale))
        let limit = Double(Int64.max) / 2
        if !(abs(r) < limit) { return Time(r < 0 ? -Int64.max : Int64.max, 1) }
        if abs(r) < limit / 1e9 { return Time(Int64((r * 1e9).rounded()), 1_000_000_000) }
        return Time(Int64(r.rounded()), 1)
    }
}
