import Foundation

/// Time remapping: a piecewise speed track over the clip's own timeline (project file v23).
///
/// ## Model
/// A keyed clip carries `SpeedKeys`: an ordered list of segments laid end to end from clip-local time 0. Each segment has a
/// timeline `duration` (whole frames, chosen by the editing functions), a speed `from` at its start, a speed `to` at its end
/// (`from == to` is a constant segment, otherwise a ramp: linear in timeline time, or a Bezier curve, see `SpeedKeysEase.swift`)
/// and a direction (`reversed`). Key points are the boundaries between segments; Premiere's "split key" (two halves with a ramp between them) is a ramp segment.
/// `origin` is the source time shown at clip-local 0 (forward: where reading starts; reversed: the end it reads backwards from).
/// `Clip.source` of a keyed clip is always the hull of every source time the track visits, so handles, trims and the media
/// limits keep working on one range.
///
/// ## Formula (the one mapping, exact)
/// Source displacement over a segment at local offset `tau` (0 ... T), with speeds `a = from`, `b = to` (ratios, source seconds
/// per timeline second):
///
///     D(tau) = a * tau + (b - a) * tau^2 / (2 T)         (constant: a * tau)
///     D(T)   = T * (a + b) / 2                            (the segment's whole span)
///
/// Source time at clip-local `x` = `origin + sum over earlier segments of sign * D(T_i) + sign * D(x - start_i)`, with
/// `sign = -1` for reversed segments. All of it is evaluated in exact integer rationals (128 bit). The only rounding is
/// `Rational.time`: a result whose reduced denominator is above `Rational.maxDenominator` (2^20) is rounded to the nearest
/// 1/2^20 s; this happens in that one place, deterministically, and keeps `Time` arithmetic downstream from overflowing.
/// A constant-speed clip never builds `SpeedKeys` (nil), so it keeps its original `ClipSpeed.scale` arithmetic bit for bit.
///
/// ## Frame convention
/// Forward: the frame shown at timeline frame `[x, x + fd)` starts at `position(x)`. Reversed: it is the source frame that
/// ends at `position(x)`, so it starts at `position(x + fd)`. This is exactly the constant-speed rule
/// (`source.end - speed * (local + fd)`), so a one-segment track equals the constant clip.
public struct SpeedSegment: Sendable, Hashable, Codable {
    public var duration: Time
    public var from: ClipSpeed
    public var to: ClipSpeed
    public var reversed: Bool
    /// Bezier shape of a ramp's speed curve (W4.4, see `SpeedKeysEase.swift`); nil = linear. Only a normalized bezier is
    /// stored (handles clamped to the unit box and quantized to 1/2^20), so equal curves compare equal and old files decode.
    public private(set) var ease: EaseShape?

    public init(duration: Time, from: ClipSpeed, to: ClipSpeed? = nil, reversed: Bool = false, ease: EaseShape? = nil) {
        self.duration = duration; self.from = from; self.to = to ?? from; self.reversed = reversed
        self.ease = ease.flatMap(SpeedEase.normalized)
    }

    private enum CodingKeys: String, CodingKey { case duration, from, to, reversed, ease }
    /// Decodes like the synthesized form, but the curve goes through `setEase` (a hand-edited or older file cannot store an
    /// unclamped or linear curve).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(duration: try c.decode(Time.self, forKey: .duration), from: try c.decode(ClipSpeed.self, forKey: .from),
                  to: try c.decode(ClipSpeed.self, forKey: .to), reversed: try c.decode(Bool.self, forKey: .reversed),
                  ease: try c.decodeIfPresent(EaseShape.self, forKey: .ease))
    }

    public var isRamp: Bool { from != to }

    /// The ramp's curve (`.linear` when none is set).
    public var easeShape: EaseShape { ease ?? .linear }

    /// Sets the speed curve; linear or hold clears it.
    public mutating func setEase(_ shape: EaseShape?) { ease = shape.flatMap(SpeedEase.normalized) }

    /// The eased curve of a ramp, nil for constant segments and linear ramps.
    var curve: SpeedEase? { isRamp ? ease.map(SpeedEase.init) : nil }

    /// Unsigned source span at timeline offset `tau` (clamped to `0 ... duration`), exact.
    func span(at tau: Time) -> Rational {
        let t = Rational(min(max(tau, .zero), duration))
        let a = Rational(from)
        if !isRamp { return a * t }
        let b = Rational(to)
        if let c = curve { return c.span(at: t, duration: Rational(duration), from: a, to: b) }
        return a * t + (b - a) * t * t / (Rational(duration) * Rational(2))
    }

    /// Unsigned source span of the whole segment: `T * (a + b) / 2` (linear), `T * (a + (b - a) * A)` (eased).
    public var span: Time { span(at: duration).time }

    /// Speed at offset `tau` as an exact rational (a ratio, not a duration).
    func speed(at tau: Time) -> Rational {
        let a = Rational(from)
        if !isRamp { return a }
        let t = Rational(min(max(tau, .zero), duration))
        if let c = curve { return a + (Rational(to) - a) * c.progress(at: t / Rational(duration)) }
        return a + (Rational(to) - a) * t / Rational(duration)
    }

    /// Speed at `tau` for display and audio (Double is fine: nothing is accumulated from it).
    public func speedValue(at tau: Time) -> Double {
        guard let c = curve else { return speed(at: tau).double }
        let a = Rational(from).double, b = Rational(to).double
        let s = min(max(Rational(tau).double / Rational(duration).double, 0), 1)
        return a + (b - a) * c.by(c.u(forS: s))
    }

    /// Unsigned span at `tau` seconds as a Double (planning, display inverse).
    func spanApprox(atSeconds tau: Double) -> Double {
        let a = Double(from.num) / Double(from.den), b = Double(to.num) / Double(to.den)
        let T = Rational(duration).double
        let t = min(max(tau, 0), T)
        if !isRamp { return a * t }
        if let c = curve { return a * t + (b - a) * T * c.g(c.u(forS: t / T)) }
        return a * t + (b - a) * t * t / (2 * T)
    }
}

public struct SpeedKeys: Sendable, Hashable, Codable {
    public var segments: [SpeedSegment] { didSet { rebuild() } }
    /// Source time at clip-local 0. When it is the rounding of an exact value (a slice or head trim of a ramp), `originExact`
    /// carries the exact rational so the mapping stays frame-for-frame identical; assigning `origin` resets it.
    public var origin: Time { didSet { originExact = nil; rebuild() } }
    var originExact: Rational?
    /// Built once per value (segments / origin changes): segment starts and exact source positions at the boundaries, so
    /// `position(at:)` is a binary search plus one span, with no repeated gcd chains. Not part of equality or the file.
    private var table = Table()

    private struct Table: Sendable {
        var starts: [Time] = [.zero]
        var startsD: [Double] = [0]
        var pos: [Rational] = []
        var posT: [Time] = []
        var posD: [Double] = []
    }

    public init(segments: [SpeedSegment], origin: Time) {
        precondition(!segments.isEmpty)
        self.segments = segments; self.origin = origin
        rebuild()
    }

    init(segments: [SpeedSegment], exactOrigin: Rational) {
        precondition(!segments.isEmpty)
        self.segments = segments; origin = exactOrigin.time
        originExact = exactOrigin
        rebuild()
    }

    /// One constant segment: what a constant-speed clip of `duration` looks like as a track.
    public init(constant speed: ClipSpeed, reversed: Bool, duration: Time, origin: Time) {
        self.init(segments: [SpeedSegment(duration: duration, from: speed, reversed: reversed)], origin: origin)
    }

    var originQ: Rational { originExact ?? Rational(origin) }

    private mutating func rebuild() {
        var t = Table()
        var pos = originQ, start = Time.zero
        t.pos.append(pos)
        for s in segments {
            pos = pos + (s.reversed ? Rational(-1) : Rational(1)) * s.span(at: s.duration)
            start += s.duration
            t.pos.append(pos)
            t.starts.append(start)
        }
        t.startsD = t.starts.map { Double($0.value) / Double($0.timescale) }
        t.posT = t.pos.map(\.time)
        t.posD = t.pos.map(\.double)
        table = t
    }

    public static func == (a: SpeedKeys, b: SpeedKeys) -> Bool {
        a.segments == b.segments && a.origin == b.origin && a.originExact == b.originExact
    }
    public func hash(into h: inout Hasher) { h.combine(segments); h.combine(origin); h.combine(originExact) }

    private enum CodingKeys: String, CodingKey { case segments, origin, originNum, originDen }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let segs = try c.decode([SpeedSegment].self, forKey: .segments)
        guard !segs.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .segments, in: c, debugDescription: "empty speed track")
        }
        let o = try c.decode(Time.self, forKey: .origin)
        if let n = try c.decodeIfPresent(Int64.self, forKey: .originNum), let den = try c.decodeIfPresent(Int64.self, forKey: .originDen), den > 0 {
            self.init(segments: segs, exactOrigin: Rational(Int128(n), Int128(den)))
        } else {
            self.init(segments: segs, origin: o)
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(segments, forKey: .segments)
        try c.encode(origin, forKey: .origin)
        if let x = originExact {
            let q = x.reducedToFit
            try c.encode(Int64(q.n), forKey: .originNum); try c.encode(Int64(q.d), forKey: .originDen)
        }
    }

    /// Timeline length of the clip.
    public var duration: Time { table.starts[table.starts.count - 1] }

    /// Clip-local start of each segment, plus the end as the last element (count + 1 entries).
    public var boundaries: [Time] { table.starts }

    /// Index of the segment shown at `local` (the last one for `local >= duration`): binary search.
    private func index(containing local: Time) -> Int {
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if table.starts[mid] <= local { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func positionQ(at local: Time) -> Rational {
        let x = max(local, .zero)
        if x >= duration { return table.pos[segments.count] }
        let i = index(containing: x)
        let s = segments[i]
        return table.pos[i] + (s.reversed ? Rational(-1) : Rational(1)) * s.span(at: x - table.starts[i])
    }

    /// Source position in seconds as a Double, for planning and eviction (not for the presented frame): no rationals.
    public func positionApprox(atSeconds x: Double) -> Double {
        let n = segments.count
        if x <= 0 { return table.posD[0] }
        if x >= table.startsD[n] { return table.posD[n] }
        var lo = 0, hi = n - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if table.startsD[mid] <= x { lo = mid } else { hi = mid - 1 } }
        let s = segments[lo]
        let d = s.spanApprox(atSeconds: x - table.startsD[lo])
        return table.posD[lo] + (s.reversed ? -d : d)
    }

    /// Source time at clip-local `local` (the instant, not a frame). Clamped to `0 ... duration`.
    public func position(at local: Time) -> Time { positionQ(at: local).time }

    /// Source time at every boundary (`segments.count + 1` entries).
    public var boundaryPositions: [Time] { table.posT }

    /// Source range the track visits (within a segment the path is monotone, so the extremes sit on boundaries).
    public var hull: TimeRange {
        let p = boundaryPositions
        return TimeRange(start: p.min()!, end: p.max()!)
    }

    /// Source time at the end of the track.
    public var endPosition: Time { table.posT[segments.count] }

    /// Direction of the segment shown at `local`.
    public func isReversed(at local: Time) -> Bool { segments[index(containing: local)].reversed }

    /// Speed at `local` (source seconds per second, unsigned), for display.
    public func speedValue(at local: Time) -> Double {
        let i = index(containing: local)
        let start = boundaries[i]
        return segments[i].speedValue(at: local - start)
    }

    /// The source time of the frame shown at clip-local `local` (see "Frame convention").
    /// Outside `0 ... duration` (a transition reading a handle before the head or after the tail) the track runs on at its end
    /// speed and direction: see `positionExtended`.
    public func sourceTime(at local: Time, frameDuration fd: Time) -> Time {
        let reversed = local < .zero ? segments[0].reversed : (local >= duration ? segments[segments.count - 1].reversed
                                                                                 : segments[index(containing: local)].reversed)
        return positionExtended(at: reversed ? local + fd : local)
    }

    /// `position(at:)` that continues linearly past both ends: before 0 at the first segment's start speed and direction, after
    /// `duration` at the last segment's end speed and direction (the media beyond a clip's edges, for transitions and audio).
    public func positionExtended(at local: Time) -> Time {
        if local < .zero {
            let s = segments[0]
            return (originQ + (s.reversed ? Rational(-1) : Rational(1)) * Rational(s.from) * Rational(local)).time
        }
        if local > duration {
            let s = segments[segments.count - 1]
            return (table.pos[segments.count] + (s.reversed ? Rational(-1) : Rational(1)) * Rational(s.to) * Rational(local - duration)).time
        }
        return position(at: local)
    }

    /// Clip-local time at which source time `s` is shown: the inverse of `position` (first visit when the track revisits
    /// a source time). A source time the track never reaches maps to the nearest end. Ramps are solved with a Double
    /// quadratic and rounded to 1/2^20 s; constant segments are exact. Used for display mappings only.
    public func localTime(forSource s: Time) -> Time {
        if let first = localTimes(forSource: s).first { return first }
        let pos = boundaryPositions, starts = boundaries
        return s < hull.start ? (pos.firstIndex(of: hull.start).map { starts[$0] } ?? .zero)
                              : (pos.lastIndex(of: hull.end).map { starts[$0] } ?? duration)
    }

    /// Every clip-local time at which the track passes source time `s`, in time order (one per segment that contains it).
    public func localTimes(forSource s: Time) -> [Time] {
        let pos = boundaryPositions, starts = boundaries
        var out: [Time] = []
        for (i, seg) in segments.enumerated() {
            let p0 = pos[i], p1 = pos[i + 1]
            let lo = min(p0, p1), hi = max(p0, p1)
            guard s >= lo && s <= hi else { continue }
            let d = Rational(seg.reversed ? p0 - s : s - p0)          // unsigned distance into the segment
            if !seg.isRamp { out.append(starts[i] + (d / Rational(seg.from)).time); continue }
            let a = Rational(seg.from).double, b = Rational(seg.to).double, T = Rational(seg.duration).double
            let dd = d.double
            var tau = 2 * dd / (a + (a * a + 2 * (b - a) * dd / T).squareRoot())
            if seg.curve != nil {                                    // eased: the span is monotone in tau, bisect it
                var lo = 0.0, hi = T
                for _ in 0..<60 { let m = (lo + hi) / 2; if seg.spanApprox(atSeconds: m) < dd { lo = m } else { hi = m } }
                tau = (lo + hi) / 2
            }
            let scale: Int64 = 1 << 20
            out.append(starts[i] + Time(Int64((min(max(tau, 0), T) * Double(scale)).rounded()), scale))
        }
        return out
    }

    /// The part of the track in `[a, b)` (clip-local, `0 <= a < b <= duration`), re-based so `a` becomes 0.
    /// A cut ramp keeps its slope: the sub-ramp runs between the speeds the ramp has at the cut points (an eased ramp keeps
    /// the matching piece of its curve, see `SpeedSegment.subSegment`).
    public func sliced(from a: Time, to b: Time) -> SpeedKeys {
        let a = max(a, .zero), b = min(b, duration)
        precondition(a < b, "empty slice")
        var out: [SpeedSegment] = []
        var t = Time.zero
        for s in segments {
            let s0 = t, s1 = t + s.duration
            t = s1
            guard s1 > a, s0 < b else { continue }
            let lo = max(s0, a), hi = min(s1, b)
            out.append(s.subSegment(from: lo - s0, to: hi - s0))
        }
        return SpeedKeys(segments: out, exactOrigin: positionQ(at: a))
    }

    /// Appends / prepends nothing: grows the track by `g` at the tail with a constant segment at the end speed and direction.
    public func extendedTail(by g: Time) -> SpeedKeys {
        if g == .zero { return self }
        if g < .zero { return sliced(from: .zero, to: duration + g) }
        var k = self
        let last = k.segments[k.segments.count - 1]
        if !last.isRamp {
            k.segments[k.segments.count - 1].duration += g
        } else {
            k.segments.append(SpeedSegment(duration: g, from: last.to, reversed: last.reversed))
        }
        return k
    }

    /// Grows the track by `g` at the head (negative = cuts `-g` off the head). The new head plays at the first speed/direction.
    public func extendedHead(by g: Time) -> SpeedKeys {
        if g == .zero { return self }
        if g < .zero { return sliced(from: .zero - g, to: duration) }
        var k = self
        let first = k.segments[0]
        let sign = first.reversed ? Rational(-1) : Rational(1)
        let lead = SpeedSegment(duration: g, from: first.from, reversed: first.reversed)
        let newOrigin = originQ - sign * lead.span(at: g)
        if !first.isRamp { k.segments[0].duration += g } else { k.segments.insert(lead, at: 0) }
        return SpeedKeys(segments: k.segments, exactOrigin: newOrigin)
    }

    /// Total path length through the source (sum of segment spans, direction ignored). The average speed is this / duration.
    public var pathLength: Time {
        var r = Rational(0)
        for s in segments { r = r + s.span(at: s.duration) }
        return r.time
    }

    /// True when every segment is constant at one speed and direction (the track plays like a constant clip, keys or not).
    public var isUniform: Bool {
        guard let f = segments.first else { return true }
        return segments.allSatisfy { !$0.isRamp && $0.from == f.from && $0.reversed == f.reversed }
    }

    /// Drops empty segments. A uniform track collapses to one segment (`collapsingUniform`, the default: it equals a constant
    /// clip). Any other key stays, also one between two equal speeds (a key the user placed: Premiere keeps those, and the
    /// Effect Controls diamond adds one without changing the speed). See the design notes "Speed keys without a change".
    public func normalized(collapsingUniform: Bool = true) -> SpeedKeys {
        let out = segments.filter { $0.duration > .zero }
        guard !out.isEmpty else { return self }
        if collapsingUniform, out.count > 1, SpeedKeys(segments: out, exactOrigin: originQ).isUniform {
            var one = out[0]
            one.duration = out.reduce(.zero) { $0 + $1.duration }
            return SpeedKeys(segments: [one], exactOrigin: originQ)
        }
        return SpeedKeys(segments: out, exactOrigin: originQ)
    }
}

extension ClipSpeed {
    /// From an exact ratio of speeds; clamped like `init(num:den:)`. The ratio is reduced to fit 63 bits first.
    init(rational r: Rational) {
        let q = r.reducedToFit
        self.init(num: Int64(q.n), den: Int64(q.d))
    }
}

/// Exact rational in 128 bit, internal to the speed maths. Operations that would overflow shed low bits of the operands
/// first (deterministic, only reachable with absurd inputs).
struct Rational: Sendable, Hashable {
    var n: Int128
    var d: Int128

    static let maxDenominator: Int128 = 1 << 20

    init(_ n: Int128, _ d: Int128 = 1) {
        var (n, d) = (n, d)
        if d < 0 { n = -n; d = -d }
        let g = Self.gcd(n < 0 ? -n : n, d)
        if g > 1 { n /= g; d /= g }
        self.n = n; self.d = d
    }
    init(_ t: Time) { self.init(Int128(t.value), Int128(t.timescale)) }
    init(_ s: ClipSpeed) { self.init(Int128(s.num), Int128(s.den)) }

    var double: Double { Double(n) / Double(d) }

    private static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// `n / d` with both parts reduced together (by dropping low bits) until they fit in 62 bits: exact for every ordinary
    /// value, a relative error below 2^-60 for the huge fractions a long chain of off-frame edits can build. Products and
    /// sums of fitted parts stay below 2^125, so the arithmetic below never overflows Int128.
    private static func fit(_ n: Int128, _ d: Int128) -> (n: Int128, d: Int128) {
        var (n, d) = (n, d)
        let lim: Int128 = 1 << 62
        while (n < 0 ? -n : n) >= lim || d >= lim { n >>= 1; d >>= 1 }
        return (n, max(d, 1))
    }

    static func * (x: Rational, y: Rational) -> Rational {
        // Cross-reduce first to keep numbers small (xn/xd and yn/yd keep the product).
        let g1 = gcd(x.n < 0 ? -x.n : x.n, y.d), g2 = gcd(y.n < 0 ? -y.n : y.n, x.d)
        let (xn, yd) = g1 > 1 ? (x.n / g1, y.d / g1) : (x.n, y.d)
        let (yn, xd) = g2 > 1 ? (y.n / g2, x.d / g2) : (y.n, x.d)
        let a = fit(xn, xd), b = fit(yn, yd)
        return Rational(a.n * b.n, max(a.d * b.d, 1))
    }
    static func / (x: Rational, y: Rational) -> Rational { x * Rational(y.d, y.n == 0 ? 1 : y.n) }
    static func + (x: Rational, y: Rational) -> Rational {
        let a = fit(x.n, x.d), b = fit(y.n, y.d)
        let g = gcd(a.d, b.d)
        let xs = b.d / g, ys = a.d / g
        return Rational(a.n * xs + b.n * ys, max(a.d * xs, 1))
    }
    static func - (x: Rational, y: Rational) -> Rational { x + Rational(-y.n, y.d) }

    /// The fraction with numerator and denominator reduced (by dropping low bits) until both fit in 62 bits.
    var reducedToFit: (n: Int128, d: Int128) { Self.fit(n, d) }

    /// The single rounding point. Exact when the reduced denominator is at most `maxDenominator`; otherwise rounded to the
    /// nearest multiple of 1/maxDenominator (ties up).
    var time: Time {
        if d <= Self.maxDenominator {
            let q = reducedToFit
            return Time(Int64(q.n), Int64(q.d))
        }
        let m = Self.maxDenominator
        // nearest integer of n * m / d, floor((2 n m + d) / (2 d)). Both parts below 2^62 first (a chain of off-frame edits
        // can grow them to the Int128 limit), so 2 n m + d stays below 2^84; a result beyond Int64 is clamped (never traps).
        let r = reducedToFit
        let num = r.n * m * 2 + r.d, den = r.d * 2
        var q = num / den
        if num % den != 0 && (num < 0) != (den < 0) { q -= 1 }
        return Time(Int64(clamping: q), Int64(m))
    }
}

/// How a slowed-down clip fills the frames between two source frames (Premiere: Time Interpolation; Resolve: Retime
/// Process). Separate from the speed itself (constant speed or the speed curve): one choice per clip.
public enum TimeInterpolation: String, Sendable, Hashable, Codable, CaseIterable {
    /// Repeat the source frame that covers the instant (nearest frame).
    case frameSampling
    /// Mix the two source frames around the instant by the fractional source position.
    case frameBlend
    /// Move the pixels of both source frames along their measured motion to the instant (GPU optical flow in SQRender),
    /// falling back to the plain mix where the motion cannot be trusted.
    case opticalFlow

    public var title: String {
        switch self {
        case .frameSampling: "Repeat frames"
        case .frameBlend: "Blend frames"
        case .opticalFlow: "Optical flow"
        }
    }

    /// Whether a source time between two frames needs the next source frame too (blend and optical flow).
    public var mixesFrames: Bool { self != .frameSampling }
}
