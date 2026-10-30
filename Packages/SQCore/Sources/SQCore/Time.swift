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
        guard den != 0 else { return 0 }                   // zero frame duration: no frames (never a trap)
        return Int64(clamping: floorDiv(num, den))
    }

    /// Nearest whole multiple of `frameDuration` (ties round up).
    public func snapped(to frameDuration: Time) -> Time {
        // floor(x + 1/2) as floor(x) plus one when the remainder is at least half the divisor: no 2^127 intermediates.
        let num = Int128(value) * Int128(frameDuration.timescale)
        let den = Int128(timescale) * Int128(frameDuration.value)
        guard den > 0 else { return self }
        let q = floorDiv(num, den), r = num - q * den
        return frameDuration * Int64(clamping: r >= den - r ? q + 1 : q)
    }

    /// Smallest whole multiple of `frameDuration` at or after `self`.
    public func ceiled(to frameDuration: Time) -> Time {
        let num = Int128(value) * Int128(frameDuration.timescale)
        let den = Int128(timescale) * Int128(frameDuration.value)
        guard den != 0 else { return self }
        return frameDuration * Int64(clamping: -floorDiv(-num, den))
    }

    /// Overflow-safe: the exact sum when it fits in Int64 (after reducing), otherwise the nearest representable time
    /// (see `init(reducing:_:)`). Never traps.
    public static func + (a: Time, b: Time) -> Time {
        if a.timescale == b.timescale {
            let (s, o) = a.value.addingReportingOverflow(b.value)
            if !o { return Time(s, a.timescale) }
        }
        let g = Int128(gcd(UInt64(a.timescale), UInt64(b.timescale)))
        let sa = Int128(a.timescale), sb = Int128(b.timescale)
        let scale = sa / g * sb
        return Time(reducing: Int128(a.value) * (sb / g) + Int128(b.value) * (sa / g), scale)
    }

    public static prefix func - (a: Time) -> Time {
        a.value == .min ? Time(.max, a.timescale) : Time(-a.value, a.timescale)
    }
    public static func - (a: Time, b: Time) -> Time { a + (-b) }
    public static func * (a: Time, n: Int64) -> Time {
        let (p, o) = a.value.multipliedReportingOverflow(by: n)
        return o ? Time(reducing: Int128(a.value) * Int128(n), Int128(a.timescale)) : Time(p, a.timescale)
    }

    /// `t * num / den` for times, exact when the reduced result fits in Int64 (rescaling key times after a retime).
    /// Three Int64 factors can exceed Int128: then it rounds twice instead of trapping.
    public static func scaled(_ t: Time, by num: Time, over den: Time) -> Time {
        let (n, o1) = (Int128(t.value) * Int128(num.value)).multipliedReportingOverflow(by: Int128(den.timescale))
        let (d, o2) = (Int128(t.timescale) * Int128(num.timescale)).multipliedReportingOverflow(by: Int128(den.value))
        if !o1 && !o2 { return Time(reducing: n, d) }
        let tn = Time(reducing: Int128(t.value) * Int128(num.value), Int128(t.timescale) * Int128(num.timescale))
        return Time(reducing: Int128(tn.value) * Int128(den.timescale), Int128(tn.timescale) * Int128(den.value))
    }

    /// `t * n / d` for integers (`d > 0`), exact when the reduced result fits in Int64, never traps (fractions of a
    /// duration: sub-frame offsets, per-word or per-window splits).
    public static func scaled(_ t: Time, by n: Int64, over d: Int64) -> Time {
        precondition(d != 0, "denominator must not be zero")
        return Time(reducing: Int128(t.value) * Int128(n), Int128(t.timescale) * Int128(d))
    }

    /// Half of `self`, never traps.
    public var halved: Time { Time.scaled(self, by: 1, over: 2) }

    /// `n / d` from a wide intermediate. Reduced by the gcd; when that still does not fit in Int64, the closest fraction
    /// with Int64 numerator and denominator is used (continued fraction, relative error far below one part in 10^12
    /// for any value of at least a few nanoseconds); a value beyond the Int64 seconds range is clamped to ±`Int64.max`
    /// seconds. `d` must not be zero (a negative `d` flips the sign).
    public init(reducing n: Int128, _ d: Int128) {
        precondition(d != 0, "timescale must not be zero")
        let negative = (n < 0) != (d < 0)
        var a = n.magnitude, b = d.magnitude
        let g = gcd128(a, b)
        if g > 1 { a /= g; b /= g }
        let limit = UInt128(Int64.max)
        func signed(_ v: UInt128) -> Int64 { negative ? -Int64(v) : Int64(v) }
        if a <= limit, b <= limit { self.init(signed(a), Int64(b)); return }
        // Whole seconds beyond Int64: clamp.
        if a / b >= limit { self.init(signed(limit), 1); return }
        // Best approximation p/q of a/b with p, q <= Int64.max: walk the convergents, finish with the best semiconvergent.
        var (p0, q0, p1, q1): (UInt128, UInt128, UInt128, UInt128) = (0, 1, 1, 0)
        var (x, y) = (a, b)
        while y != 0 {
            let t = x / y
            let tp = p1 == 0 ? t : (limit - p0) / p1
            let tq = q1 == 0 ? t : (limit - q0) / q1
            let tMax = Swift.min(tp, tq)
            if t > tMax {
                // Semiconvergent with tMax, if it is closer than the last convergent.
                if tMax > 0 {
                    let ps = tMax * p1 + p0, qs = tMax * q1 + q0
                    let target = Double(a) / Double(b)
                    if abs(Double(ps) / Double(qs) - target) < abs(Double(p1) / Double(q1) - target) { (p1, q1) = (ps, qs) }
                }
                break
            }
            (p0, q0, p1, q1) = (p1, q1, t * p1 + p0, t * q1 + q0)
            (x, y) = (y, x - t * y)
        }
        if q1 == 0 { self.init(signed(limit), 1); return }
        self.init(signed(p1), Int64(q1))
    }
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

    /// Same shape as the synthesized coding; a negative duration is a corrupt file, not a crash later (H6).
    private enum CodingKeys: String, CodingKey { case start, duration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(Time.self, forKey: .start)
        let duration = try c.decode(Time.self, forKey: .duration)
        guard !duration.isNegative else {
            throw DecodingError.dataCorruptedError(forKey: .duration, in: c, debugDescription: "negative duration")
        }
        self.init(start: start, duration: duration)
    }

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

private func gcd128(_ a: UInt128, _ b: UInt128) -> UInt128 {
    var (a, b) = (a, b)
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

private func floorDiv(_ n: Int128, _ d: Int128) -> Int128 {
    let q = n / d
    return (n % d != 0 && (n < 0) != (d < 0)) ? q - 1 : q
}
