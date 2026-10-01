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
        guard percent.isFinite, percent > 0 else { self = .normal; return }
        self.init(num: Int64((percent * 100).rounded()), den: 10_000)
    }

    private enum CodingKeys: String, CodingKey { case num, den }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(num: try c.decode(Int64.self, forKey: .num), den: try c.decode(Int64.self, forKey: .den))
    }

    public var isNormal: Bool { num == den }
    /// For display only.
    public var percent: Double { Double(num) / Double(den) * 100 }

    /// `t * speed`: source time spanned by timeline time `t`.
    public func scale(_ t: Time) -> Time { Time(t.value * num, t.timescale * den) }
    /// `t / speed`: timeline time needed to play source time `t`.
    public func unscale(_ t: Time) -> Time { Time(t.value * den, t.timescale * num) }

    public static func < (a: ClipSpeed, b: ClipSpeed) -> Bool { Int128(a.num) * Int128(b.den) < Int128(b.num) * Int128(a.den) }
}
