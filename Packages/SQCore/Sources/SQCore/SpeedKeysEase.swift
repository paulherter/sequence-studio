import Foundation

/// Eased speed transitions (W4.4): a ramp's speed follows the same cubic Bezier the keyframe curve popover edits
/// (`EaseShape`), instead of a straight line in timeline time.
///
/// ## Curve
/// In the ramp's unit box (normalized time `s = tau / T` across, normalized speed `E = (v - a) / (b - a)` up) the curve runs
/// from (0, 0) to (1, 1) through the control points `(x1, y1) = out` and `(x2, y2) = (1 - in.dx, 1 - in.dy)`, exactly like
/// `KeyframeTrack.bezierProgress`. Handles are clamped to the unit box (so the speed never leaves `a ... b` and never passes
/// through zero: the source mapping stays strictly monotone) and quantized to 1/2^20 (so they are exact rationals).
///
/// ## Integral (what keeps the source map consistent)
/// With the curve's parameter `u` (`s = Bx(u)`, `E = By(u)`), the source displacement is
///
///     D(tau) = a * tau + (b - a) * T * G(u),        G(u) = integral_0^u By(w) * Bx'(w) dw   (a degree-6 polynomial)
///     D(T)   = T * (a + (b - a) * A),               A = G(1)
///
/// `A` is computed in exact rationals and then rounded once to a 1/2^32 grid (keeps the 128-bit sums of boundary positions
/// small); that one number is the span everywhere, so the boundary table stays consistent (a symmetric curve has A = 1/2
/// exactly: the same source as the linear ramp). Inside the ramp `u` has to be solved from `s` (a cubic): that is done in
/// Double by bisection (monotone, deterministic) and `G(u)` is quantized to 1/2^24 before it enters the exact sum, so the
/// interior positions are deterministic, monotone and within ~1e-7 of the true integral, and still meet the exact
/// boundary at both ends. The clip keeps its timeline length when a curve is set: the span follows the curve.
struct SpeedEase: Sendable {
    static let grid = 1_048_576.0
    private static let gScale: Int128 = 1 << 24

    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ shape: EaseShape) {
        x1 = Self.q(shape.out.dx); y1 = Self.q(shape.out.dy)
        x2 = 1 - Self.q(shape.in.dx); y2 = 1 - Self.q(shape.in.dy)
    }

    private static func q(_ v: Double) -> Double { (min(max(v.isFinite ? v : 0, 0), 1) * grid).rounded() / grid }

    /// The stored form of a speed curve: nil for linear or hold, else a bezier with handles clamped and quantized.
    static func normalized(_ shape: EaseShape) -> EaseShape? {
        guard shape.effective.interpolation == .bezier else { return nil }
        let out = EaseHandle(dx: q(shape.out.dx), dy: q(shape.out.dy)), inH = EaseHandle(dx: q(shape.in.dx), dy: q(shape.in.dy))
        // Both control points on the diagonal: By == Bx, the speed is a straight ramp.
        if out.dx == out.dy, inH.dx == inH.dy { return nil }
        return EaseShape(interpolation: .bezier, out: out, in: inH)
    }

    // MARK: Double evaluation

    private static func cubic(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let m = 1 - u
        return 3 * m * m * u * p1 + 3 * m * u * u * p2 + u * u * u
    }
    func bx(_ u: Double) -> Double { Self.cubic(u, x1, x2) }
    func by(_ u: Double) -> Double { Self.cubic(u, y1, y2) }

    /// Curve parameter for normalized time `s` (bisection: monotone in `s`, deterministic).
    func u(forS s: Double) -> Double {
        if s <= 0 { return 0 }
        if s >= 1 { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<52 {
            let m = (lo + hi) / 2
            if bx(m) < s { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    /// Power-basis coefficients of G (index = power, 0 ... 6), in Double.
    private var gCoefficients: [Double] {
        let X = [0, 3 * x1, 3 * x2 - 6 * x1, 1 + 3 * x1 - 3 * x2]
        let Y = [0, 3 * y1, 3 * y2 - 6 * y1, 1 + 3 * y1 - 3 * y2]
        let dX = [X[1], 2 * X[2], 3 * X[3]]
        var p = [Double](repeating: 0, count: 6)
        for i in 1...3 { for j in 0...2 { p[i + j] += Y[i] * dX[j] } }
        var g = [Double](repeating: 0, count: 7)
        for k in 0..<6 { g[k + 1] = p[k] / Double(k + 1) }
        return g
    }

    /// G(u) in Double (Horner).
    func g(_ u: Double) -> Double {
        let c = gCoefficients
        var r = 0.0
        for k in stride(from: 6, through: 0, by: -1) { r = r * u + c[k] }
        return r
    }

    // MARK: Exact

    private static func r(_ v: Double) -> Rational { Rational(Int128((v * grid).rounded()), Int128(grid)) }

    /// A = G(1), exact up to the one rounding to 1/2^32.
    var area: Rational {
        let x1 = Self.r(x1), x2 = Self.r(x2), y1 = Self.r(y1), y2 = Self.r(y2)
        let three = Rational(3), six = Rational(6), one = Rational(1)
        let X = [Rational(0), three * x1, three * x2 - six * x1, one + three * x1 - three * x2]
        let Y = [Rational(0), three * y1, three * y2 - six * y1, one + three * y1 - three * y2]
        let dX = [X[1], Rational(2) * X[2], three * X[3]]
        var p = [Rational](repeating: Rational(0), count: 6)
        for i in 1...3 { for j in 0...2 { p[i + j] = p[i + j] + Y[i] * dX[j] } }
        var a = Rational(0)
        for k in 1..<6 { a = a + p[k] / Rational(Int128(k + 1)) }
        // One rounding to 1/2^32 (nearest), so spans built from A keep small denominators.
        let m: Int128 = 1 << 32
        guard a.d > m else { return a }
        let num = a.n * m * 2 + a.d, den = a.d * 2
        return Rational(num / den, m)
    }

    private static func quantised(_ v: Double) -> Rational { Rational(Int128((v * Double(gScale)).rounded()), gScale) }

    /// Unsigned span at offset `t` of a ramp of length `T` from speed `a` to `b` (see the type comment).
    func span(at t: Rational, duration T: Rational, from a: Rational, to b: Rational) -> Rational {
        if t.n <= 0 { return Rational(0) }
        let A = area
        if (t - T).n >= 0 { return T * (a + (b - a) * A) }
        var gq = Self.quantised(g(u(forS: (t / T).double)))
        if gq.n < 0 { gq = Rational(0) }
        if (gq - A).n > 0 { gq = A }
        return a * t + (b - a) * T * gq
    }

    /// Normalized speed `By(u(s))` as a rational on the 1/2^24 grid, 0 and 1 exactly at the ends.
    func progress(at s: Rational) -> Rational {
        if s.n <= 0 { return Rational(0) }
        if s.n >= s.d { return Rational(1) }
        let v = Self.quantised(by(u(forS: s.double)))
        return v.n < 0 ? Rational(0) : (v.n > v.d ? Rational(1) : v)
    }

    // MARK: Subdivision

    /// Blossom of the cubic with control points (0, p1, p2, 1).
    private static func blossom(_ p1: Double, _ p2: Double, _ a: Double, _ b: Double, _ c: Double) -> Double {
        func lerp(_ x: Double, _ y: Double, _ t: Double) -> Double { x + (y - x) * t }
        let l0 = lerp(0, p1, a), l1 = lerp(p1, p2, a), l2 = lerp(p2, 1, a)
        let m0 = lerp(l0, l1, b), m1 = lerp(l1, l2, b)
        return lerp(m0, m1, c)
    }

    /// The piece of the curve between normalized times `s0 < s1`, renormalised to its own unit box. nil when that piece is
    /// flat (constant speed) or degenerate.
    func piece(from s0: Double, to s1: Double) -> EaseShape? {
        let u0 = u(forS: s0), u1 = u(forS: s1)
        func pts(_ p1: Double, _ p2: Double) -> [Double] {
            [Self.blossom(p1, p2, u0, u0, u0), Self.blossom(p1, p2, u0, u0, u1), Self.blossom(p1, p2, u0, u1, u1),
             Self.blossom(p1, p2, u1, u1, u1)]
        }
        let X = pts(x1, x2), Y = pts(y1, y2)
        let dx = X[3] - X[0], dy = Y[3] - Y[0]
        guard dx > 1e-12, dy > 1e-12 else { return nil }
        return EaseShape(interpolation: .bezier,
                         out: EaseHandle(dx: (X[1] - X[0]) / dx, dy: (Y[1] - Y[0]) / dy),
                         in: EaseHandle(dx: (X[3] - X[2]) / dx, dy: (Y[3] - Y[2]) / dy))
    }
}

extension SpeedSegment {
    /// The part of this segment between offsets `lo < hi`, as its own segment. A constant segment just gets shorter; a ramp
    /// runs between the speeds it has at the cuts; an eased ramp keeps the matching piece of its curve.
    func subSegment(from lo: Time, to hi: Time) -> SpeedSegment {
        var n = self
        n.duration = hi - lo
        guard isRamp, lo > .zero || hi < duration else { return n }
        if lo > .zero { n.from = ClipSpeed(rational: speed(at: lo)) }
        if hi < duration { n.to = ClipSpeed(rational: speed(at: hi)) }
        if let c = curve, n.isRamp {
            let T = Rational(duration)
            n.setEase(c.piece(from: (Rational(lo) / T).double, to: (Rational(hi) / T).double))
        } else {
            n.setEase(nil)
        }
        return n
    }
}

extension SpeedKeys {
    /// The speed curve of segment `i` (`.linear` for a linear ramp or a constant segment).
    public func ease(ofSegment i: Int) -> EaseShape {
        segments.indices.contains(i) ? segments[i].easeShape : .linear
    }

    /// Sets the speed curve of ramp `i` (linear / hold = straight ramp). The ramp keeps its timeline length and its end
    /// speeds; the source it covers follows the curve (a symmetric curve covers the same source). nil when `i` is no ramp.
    public func settingEase(_ shape: EaseShape, ofSegment i: Int) -> SpeedKeys? {
        guard segments.indices.contains(i), segments[i].isRamp else { return nil }
        var k = self
        k.segments[i].setEase(shape)
        return k
    }
}
