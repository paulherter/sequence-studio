import Foundation

/// Constant clip speed as an exact ratio `num / den` (never a Double): 1/1 = 100 %, 2/1 = 200 %, 3333/10000 = 33.33 %.
/// Clamped to Premiere's range 1 % ... 10000 % (`minimum` ... `maximum`). Direction is not part of the speed:
/// `Clip.reversed` flips it (shown as "-100 %").
public struct ClipSpeed: Sendable, Hashable, Codable, Comparable {
    public let num: Int64
    public let den: Int64

    public static let normal = ClipSpeed(num: 1, den: 1)
    public static let minimum = ClipSpeed(unchecked: 1, 100)
    public static let maximum = ClipSpeed(unchecked: 100, 1)

    private init(unchecked n: Int64, _ d: Int64) { num = n; den = d }

    /// Reduces the ratio and clamps it to `minimum ... maximum`. Non-positive input gives `.normal`.
    public init(num: Int64, den: Int64) {
        guard num > 0, den > 0 else { self = .normal; return }
        var (a, b) = (num, den)
        while b != 0 { (a, b) = (b, a % b) }
        let n = num / a, d = den / a
        // n/d < 1/100  <=>  100 n < d ;  n/d > 100  <=>  n > 100 d
        if Int128(n) * 100 < Int128(d) { self = .minimum }
        else if Int128(n) > Int128(d) * 100 { self = .maximum }
        else { self = ClipSpeed(unchecked: n, d) }
    }

    /// From a typed percentage; rounded to 1/100 of a percent (33.33 -> 3333/10000).
    public init(percent: Double) {
        guard !percent.isNaN, percent > 0 else { self = .normal; return }
        // Out of range (and +infinity) clamps before the Int64 conversion; a tiny positive value is the slowest speed.
        if percent >= 10_000 { self = .maximum; return }
        if percent < 1 { self = .minimum; return }
        self.init(num: Int64((percent * 100).rounded()), den: 10_000)
    }

    private enum CodingKeys: String, CodingKey { case num, den }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int64.self, forKey: .num), d = try c.decode(Int64.self, forKey: .den)
        guard n > 0, d > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .num, in: c, debugDescription: "speed must be positive, got \(n)/\(d)")
        }
        self.init(num: n, den: d)
    }

    public var isNormal: Bool { num == den }
    /// For display only.
    public var percent: Double { Double(num) / Double(den) * 100 }

    /// `t * speed`: source time spanned by timeline time `t`.
    public func scale(_ t: Time) -> Time { Time(reducing: Int128(t.value) * Int128(num), Int128(t.timescale) * Int128(den)) }
    /// `t / speed`: timeline time needed to play source time `t`.
    public func unscale(_ t: Time) -> Time { Time(reducing: Int128(t.value) * Int128(den), Int128(t.timescale) * Int128(num)) }

    /// The speed that plays source span `source` in timeline time `timeline` (`source / timeline`), overflow-safe: the
    /// ratio is formed in Int128 and reduced; a ratio that still does not fit is rounded (then clamped as usual).
    public init(source: Time, over timeline: Time) {
        var n = Int128(source.value) * Int128(timeline.timescale)
        var d = Int128(source.timescale) * Int128(timeline.value)
        guard n > 0, d > 0 else { self = .normal; return }
        var (a, b) = (n, d)
        while b != 0 { (a, b) = (b, a % b) }
        n /= a; d /= a
        if Int64(exactly: n) == nil || Int64(exactly: d) == nil {
            let bits = Int128.bitWidth - Swift.max(n, d).leadingZeroBitCount
            let k = bits - 62
            let half = Int128(1) << (k - 1)
            n = Swift.max((n + half) >> k, 1); d = Swift.max((d + half) >> k, 1)
        }
        self.init(num: Int64(n), den: Int64(d))
    }

    public static func < (a: ClipSpeed, b: ClipSpeed) -> Bool { Int128(a.num) * Int128(b.den) < Int128(b.num) * Int128(a.den) }
}
