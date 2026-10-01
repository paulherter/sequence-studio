import Foundation
import SQCore

/// Shape of one keyframe segment, expressed as SQCore interpolation plus bezier handles.
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

/// One animated property (e.g. "scale", "opacity", "positionX", "positionY", "rotation") as an SQCore track.
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
    public init(tracks: [AnimationTrack], duration: Time, anchor: AnimationAnchor = .start) {
        self.tracks = tracks; self.duration = duration; self.anchor = anchor
    }
    public static let none = KeyframeTemplate(tracks: [], duration: .zero)
    public func track(for property: String) -> AnimationTrack? { tracks.first { $0.property == property } }
    /// Value of `property` at template-local time `t`; nil if the property has no keys.
    public func value(of property: String, at t: Time) -> Double? { track(for: property)?.value(at: t) }

    private enum CodingKeys: String, CodingKey { case tracks, duration, anchor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dur = try c.decode(Time.self, forKey: .duration)
        duration = dur
        anchor = try c.decodeIfPresent(AnimationAnchor.self, forKey: .anchor) ?? .start
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
