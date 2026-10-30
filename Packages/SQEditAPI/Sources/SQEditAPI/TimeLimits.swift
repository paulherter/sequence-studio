import Foundation
import SQCore

/// Bounds for agent-supplied times, checked on the raw integers before a `Time` exists. `Time.+` scales both values to
/// the common timescale in Int64; with the agent's timescale <= 2^20 and |time| <= 2^22 s, the agent value is <= 2^42,
/// so adding it to a project time (timescales up to ~2^17 in practice) stays far below 2^63.
public enum TimeLimits {
    public static let maxTimescale: Int64 = 1 << 20
    public static let maxSeconds: Int64 = 1 << 22

    public static func isValid(value: Int64, timescale: Int64) -> Bool {
        guard timescale > 0, timescale <= maxTimescale, value != .min else { return false }
        return value.magnitude <= UInt64(timescale) * UInt64(maxSeconds)
    }

    public static func isValid(_ t: Time) -> Bool { isValid(value: t.value, timescale: t.timescale) }

    static var message: String { "time out of range: timescale 1...\(maxTimescale), at most \(maxSeconds) s either way" }
}

/// `{"value", "timescale"}` validated against `TimeLimits` before `Time` is built.
struct WireTime: Decodable {
    let time: Time
    private enum K: String, CodingKey { case value, timescale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let v = try c.decode(Int64.self, forKey: .value), s = try c.decode(Int64.self, forKey: .timescale)
        guard TimeLimits.isValid(value: v, timescale: s) else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: c, debugDescription: TimeLimits.message)
        }
        time = Time(v, s)
    }
}

struct WireRange: Decodable {
    let range: TimeRange
    private enum K: String, CodingKey { case start, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let s = try c.decode(WireTime.self, forKey: .start).time, d = try c.decode(WireTime.self, forKey: .duration).time
        guard !d.isNegative else {
            throw DecodingError.dataCorruptedError(forKey: .duration, in: c, debugDescription: "negative duration")
        }
        range = TimeRange(start: s, duration: d)
    }
}
