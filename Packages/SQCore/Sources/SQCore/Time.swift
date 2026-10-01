/// Rational time: `value / timescale` seconds. Never a Double.
/// Equality, hashing and ordering are by value, so 1/2 == 2/4.
public struct Time: Sendable, Comparable, Hashable, Codable {
    public private(set) var value: Int64
    public private(set) var timescale: Int64

    public static let zero = Time(0, 1)

    public init(_ value: Int64, _ timescale: Int64) {
        precondition(timescale > 0, "timescale must be positive")
        let g = gcd(value.magnitude, UInt64(timescale))
        if g > 1 {
            self.value = value / Int64(g)
            self.timescale = timescale / Int64(g)
        } else {
            self.value = value
            self.timescale = timescale
        }
    }

    /// Same shape as the synthesized coding (`value`, `timescale`), but decoded values go through the
    /// normalizing init so equality and hashing hold, and a non-positive timescale is rejected.
    private enum CodingKeys: String, CodingKey { case value, timescale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(Int64.self, forKey: .value)
        let timescale = try c.decode(Int64.self, forKey: .timescale)
        guard timescale > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: c,
                debugDescription: "timescale must be positive, got \(timescale)")
        }
        self.init(value, timescale)
    }

    public init(seconds: Int64) { self.init(seconds, 1) }

    public static func frames(_ n: Int64, frameDuration: Time) -> Time { frameDuration * n }

    public var isNegative: Bool { value < 0 }

    /// Floor of `self / frameDuration`.
    public func frameIndex(frameDuration: Time) -> Int64 {
        // self / fd = (v1 * s2) / (s1 * v2)
        let num = Int128(value) * Int128(frameDuration.timescale)
        let den = Int128(timescale) * Int128(frameDuration.value)
        return Int64(floorDiv(num, den))
    }

    /// Nearest whole multiple of `frameDuration` (ties round up).
    public func snapped(to frameDuration: Time) -> Time {
        let num = Int128(value) * Int128(frameDuration.timescale) * 2 + Int128(timescale) * Int128(frameDuration.value)
        let den = Int128(timescale) * Int128(frameDuration.value) * 2
        return frameDuration * Int64(floorDiv(num, den))
    }

    public static func + (a: Time, b: Time) -> Time {
        let g = Int64(gcd(UInt64(a.timescale), UInt64(b.timescale)))
        let scale = a.timescale / g * b.timescale
        return Time(a.value * (scale / a.timescale) + b.value * (scale / b.timescale), scale)
    }

    public static prefix func - (a: Time) -> Time { Time(-a.value, a.timescale) }
    public static func - (a: Time, b: Time) -> Time { a + (-b) }
    public static func * (a: Time, n: Int64) -> Time { Time(a.value * n, a.timescale) }
    public static func += (a: inout Time, b: Time) { a = a + b }
    public static func -= (a: inout Time, b: Time) { a = a - b }

    public static func < (a: Time, b: Time) -> Bool {
        Int128(a.value) * Int128(b.timescale) < Int128(b.value) * Int128(a.timescale)
    }
}

public struct TimeRange: Sendable, Hashable, Codable {
    public var start: Time
    public var duration: Time
    public var end: Time { start + duration }
    public var isEmpty: Bool { duration <= .zero }

    public init(start: Time, duration: Time) {
        precondition(!duration.isNegative, "negative duration")
        self.start = start
        self.duration = duration
    }

    public init(start: Time, end: Time) { self.init(start: start, duration: end - start) }

    /// Half-open: `start` is inside, `end` is not.
    public func contains(_ t: Time) -> Bool { t >= start && t < end }
    public func overlaps(_ o: TimeRange) -> Bool { start < o.end && o.start < end }

    public func intersection(_ o: TimeRange) -> TimeRange? {
        let s = max(start, o.start), e = min(end, o.end)
        return s < e ? TimeRange(start: s, end: e) : nil
    }
}

private func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    var (a, b) = (a, b)
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

private func floorDiv(_ n: Int128, _ d: Int128) -> Int128 {
    let q = n / d
    return (n % d != 0 && (n < 0) != (d < 0)) ? q - 1 : q
}
