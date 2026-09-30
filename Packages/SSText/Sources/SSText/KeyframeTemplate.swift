import Foundation
import SSCore

/// Shape of one keyframe segment, expressed as SSCore interpolation plus bezier handles.
/// Overshoot is a bezier whose handle leaves 0...1 (`dy > 1`); hold is `Interpolation.hold`.
public enum SegmentShape: String, Sendable, Hashable, Codable {
    case linear, easeIn, easeOut, easeInOut
    /// Ease-out that passes the end value and settles back (back-out, cubic-bezier 0.34, 1.56, 0.64, 1).
    case overshoot
    /// Keeps the start value until the next key.
    case hold

    var interpolation: Interpolation {
        switch self {
        case .linear: .linear
        case .hold: .hold
        default: .bezier
        }
    }

    /// (outgoing handle of the segment's first key, incoming handle of its second key).
    var handles: (out: EaseHandle, in: EaseHandle) {
        switch self {
        case .linear, .hold: (.linear, .linear)
        case .easeIn: (EaseHandle(dx: 1.0 / 3, dy: 0), EaseHandle(dx: 1.0 / 3, dy: 1))
        case .easeOut: (EaseHandle(dx: 1.0 / 3, dy: 1), EaseHandle(dx: 1.0 / 3, dy: 0))
        case .easeInOut: (EaseHandle(dx: 1.0 / 3, dy: 0), EaseHandle(dx: 1.0 / 3, dy: 0))
        case .overshoot: (EaseHandle(dx: 0.34, dy: 1.56), EaseHandle(dx: 0.36, dy: 0))
        }
    }
}

/// One animated property (e.g. "scale", "opacity", "positionX", "positionY", "rotation") as an SSCore track.
/// Key times are template-local: 0 = start of the animation, `KeyframeTemplate.duration` = its end.
public struct AnimationTrack: Sendable, Hashable, Codable {
    public var property: String
    public var track: KeyframeTrack<Double>

    public init(property: String, track: KeyframeTrack<Double>) { self.property = property; self.track = track }

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

/// Reusable animation: property tracks over template-local time plus a default playback length.
///
/// On-disk shape (TextTemplate format v2): `{"duration": Time, "tracks": [{"property", "track": {"keys": [...]}}]}`.
/// Decoding also reads the v1 shape (normalized `Fraction` times, `easing` enum), converting key times to
/// `duration * fraction` and easings to SSCore handles.
public struct KeyframeTemplate: Sendable, Hashable, Codable {
    public var tracks: [AnimationTrack]
    /// Default playback length of the animation (rational timeline time).
    public var duration: Time
    public init(tracks: [AnimationTrack], duration: Time) { self.tracks = tracks; self.duration = duration }
    public static let none = KeyframeTemplate(tracks: [], duration: .zero)
    public func track(for property: String) -> AnimationTrack? { tracks.first { $0.property == property } }
    /// Value of `property` at template-local time `t`; nil if the property has no keys.
    public func value(of property: String, at t: Time) -> Double? { track(for: property)?.value(at: t) }

    private enum CodingKeys: String, CodingKey { case tracks, duration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dur = try c.decode(Time.self, forKey: .duration)
        duration = dur
        if let v2 = try? c.decode([AnimationTrack].self, forKey: .tracks) {
            tracks = v2
        } else {
            let legacy = try c.decode([LegacyTrack].self, forKey: .tracks)
            tracks = legacy.map { $0.migrated(duration: dur) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(duration, forKey: .duration)
    }
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
    func migrated(duration: Time) -> AnimationTrack {
        let keys = keyframes.map { k -> (time: Time, value: Double, shape: SegmentShape) in
            let d = max(k.time.denominator, 1)
            let t = duration == .zero
                ? Time(k.time.numerator, d)
                : Time(duration.value * k.time.numerator, duration.timescale * d)
            return (t, k.value, k.easing)
        }
        return AnimationTrack(property: property, keys: keys)
    }
}
