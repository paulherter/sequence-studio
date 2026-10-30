import Foundation

/// Damped spring easing. Runtime-only (not stored in project files): applying it bakes plain linear keys,
/// so the file format is unchanged. `progress` goes 0 -> 1, may overshoot 1, and ends exactly on 1.
public struct SpringEasing: Sendable, Hashable {
    /// 0 = critically damped (no overshoot), 1 = very bouncy. Clamped to 0...1.
    public var bounce: Double

    public init(bounce: Double) { self.bounce = min(max(bounce, 0), 1) }

    /// Damping ratio derived from bounce (1 = critical).
    var dampingRatio: Double { 1 - 0.9 * bounce }

    /// Eased progress for normalized time `t` (clamped: 0 below 0, exactly 1 from 1 on).
    public func progress(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let z = dampingRatio
        // Envelope e^(-z*w) = 0.001 at t = 1, so the spring has settled by the end of the segment.
        let decay = log(1000.0)
        let w = decay / z
        let raw: (Double) -> Double
        if z >= 0.9999 {
            raw = { 1 - exp(-w * $0) * (1 + w * $0) }
        } else {
            let wd = w * (1 - z * z).squareRoot()
            raw = { 1 - exp(-z * w * $0) * (cos(wd * $0) + z * w / wd * sin(wd * $0)) }
        }
        // Distribute the tiny residual linearly so the end value is exact.
        return raw(t) + (1 - raw(1)) * t
    }


    /// Upper bound on baked segments (keeps keys sane for very long spans).
    static let maxBakedSegments = 600

    /// `start + (end - start) * i / n`, computed in Int128 so large values or timescales cannot overflow.
    /// Falls back to a 1/90000 s grid if the exact rational does not fit Int64.
    static func interpolatedTime(start: Time, end: Time, i: Int, n: Int) -> Time {
        let ts = Int128(start.timescale), te = Int128(end.timescale)
        // fractions over the common denominator ts*te*n
        let den = ts * te * Int128(n)
        let num = Int128(start.value) * te * Int128(n) * 1
            + (Int128(end.value) * ts - Int128(start.value) * te) * Int128(i)
        var g = gcd128(num.magnitude, den.magnitude)
        if g == 0 { g = 1 }
        let v = num / Int128(g), d = den / Int128(g)
        if let v64 = Int64(exactly: v), let d64 = Int64(exactly: d), d64 > 0 { return Time(v64, d64) }
        for grid in [Int128(90000), 1000, 1] {
            let q = num * grid / den
            if let q64 = Int64(exactly: q) { return Time(q64, Int64(grid)) }
        }
        return Time(Int64(clamping: num / den), 1)
    }

    private static func gcd128(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// Linear keys sampling the spring from `a` to `b`. First key is `a` at `start`, last is exactly `b` at `end`.
    public func bakedKeys<V: KeyframeValue>(from a: V, to b: V, start: Time, end: Time,
                                            samplesPerSecond: Int = 30) -> [Keyframe<V>] {
        if end < start { return [] }
        if end == start { return [Keyframe(time: start, value: b, interpolation: .linear)] }
        let span = end - start
        let secs = KeyframeMath.seconds(span)
        let n = min(max(2, Int((secs * Double(max(samplesPerSecond, 1))).rounded())), Self.maxBakedSegments)
        var keys: [Keyframe<V>] = []
        keys.reserveCapacity(n + 1)
        for i in 0...n {
            let time: Time
            let value: V
            if i == 0 { time = start; value = a }
            else if i == n { time = end; value = b }
            else {
                time = Self.interpolatedTime(start: start, end: end, i: i, n: n)
                value = V.lerp(a, b, progress(Double(i) / Double(n)))
            }
            keys.append(Keyframe(time: time, value: value, interpolation: .linear))
        }
        return keys
    }

    /// Progress sampled at `count` evenly spaced points, for the library preview.
    public func previewSamples(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        return (0..<count).map { progress(Double($0) / Double(count - 1)) }
    }
}

extension EasingCurve {
    /// Premiere's default bezier: 16.7 % influence on both handles, flat tangents.
    public static let premiereDefault = builtIn(11, "Classic", .bezier,
                                                out: EaseHandle(dx: 0.167, dy: 0), in: EaseHandle(dx: 0.167, dy: 0))
    /// Decelerating arrival with 100 % influence (fast start, long settle). Segment start stays linear.
    public static let easeOut100 = builtIn(9, "Ease-out 100%", .bezier,
                                           out: .linear, in: EaseHandle(dx: 1, dy: 0))
    /// Accelerating departure with 100 % influence (long build-up, fast arrival).
    public static let easeIn100 = builtIn(10, "Ease-in 100%", .bezier,
                                          out: EaseHandle(dx: 1, dy: 0), in: .linear)

    /// "Soft landing" (board menus.txt preset): leaves at a brisk pace and settles gently into the next key.
    public static let softLanding = builtIn(12, "Soft landing", .bezier,
                                            out: EaseHandle(dx: 0.2, dy: 0.5), in: EaseHandle(dx: 0.5, dy: 0))

    /// Eased progress at `count` evenly spaced points (0...1 in time), for library preview thumbnails.
    public func previewSamples(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            switch interpolation {
            case .linear: return t
            case .hold: return t >= 1 ? 1 : 0
            case .holdAhead: return t > 0 ? 1 : 0
            case .bezier: return KeyframeMath.bezierProgress(t, out: outHandle, in: inHandle)
            }
        }
    }
}

/// A named spring for the library list.
public struct SpringPreset: Sendable, Hashable, Identifiable {
    public var name: String
    public var spring: SpringEasing
    public var id: String { name }
    public init(name: String, spring: SpringEasing) { self.name = name; self.spring = spring }
}

extension EasingLibrary {
    public static let springPresets: [SpringPreset] = [
        SpringPreset(name: "Spring smooth", spring: SpringEasing(bounce: 0)),
        SpringPreset(name: "Spring soft", spring: SpringEasing(bounce: 0.4)),
        SpringPreset(name: "Spring bounce", spring: SpringEasing(bounce: 0.7)),
    ]
}
