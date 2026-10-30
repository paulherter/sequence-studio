import Foundation

// Rolling shutter correction without gyro data (F7.15): an option of the Standard Stabilizer.
//
// A rolling sensor reads its rows one after the other: the row at scan position v (-0.5 = first row read ... +0.5 = last,
// 0 = the picture center) is exposed `readout * v` later than the center row. While the picture moves with velocity `vel`
// (px/s) that row is displaced by `vel * readout * v`: a pan leans verticals, a tilt stretches or squeezes the picture.
//   shown(p) = ideal(p) + shear * v(p),   shear = vel * readout   (px across the whole scan extent)
// A constant velocity shears every frame alike, so two frames show no difference; only a change of velocity does:
// between frame i-1 and i the measured shift grows along the scan axis by slope_i = readout * (vel_i - vel_i-1).
// The analysis (SQAnalysis `RollingShutterMeasure`) stores shift and slope per frame pair; the readout time is the
// least-squares fit of slope against the velocity change over the whole shot, and each frame's shear follows from it.
// The effect stores the shear per clip frame (fraction of the scan extent, decimated keys like the stage keys); the
// render pass (`ImageFilter.rollingShutter`) shifts every row back before the Stabilizer's own correction moves the clip.

/// What the analysis measured between two analyzed frames, source px.
public struct RollingShutterSample: Sendable, Hashable, Codable {
    /// Picture shift previous -> current at the picture center.
    public var shiftX: Double, shiftY: Double
    /// Extra shift of the last scan row against the first one (rotation and zoom taken out).
    public var slopeX: Double, slopeY: Double
    public init(shiftX: Double, shiftY: Double, slopeX: Double, slopeY: Double) {
        self.shiftX = shiftX; self.shiftY = shiftY; self.slopeX = slopeX; self.slopeY = slopeY
    }
}

public enum RollingShutter {
    /// The readout time of a shot, seconds from the first to the last row along the positive scan axis of the upright
    /// picture (negative: the sensor reads the other way round, as in footage stored upside down).
    public struct Estimate: Sendable, Hashable {
        public var readout: Double
        /// False: the shot did not let it be measured (`readout` is then the typical value).
        public var measured: Bool
        /// Observations the fit used and its standard error, seconds.
        public var observations: Int
        public var error: Double
    }

    /// Readout assumed when a shot cannot be measured: 16 ms (phones and mirrorless cameras read 4K in 8-30 ms),
    /// at most 60 % of the source's frame interval (60 fps: 10 ms, 120 fps: 5 ms).
    public static let typicalReadout = 0.016
    /// A fit counts as measured from this many observations and below this standard error (seconds).
    public static let minObservations = 12, maxError = 0.004
    /// ... and only when the velocity changes by at least this much from frame to frame (RMS, source px/s).
    public static let minVelocityChange = 5.0

    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(1, t.timescale)) }

    /// Picture velocity (source px/s) over each frame pair: `[i]` is frame i-1 -> i; nil where it was not measured, at
    /// index 0 and across a cut.
    static func pairVelocities(_ a: StabilizationAnalysis) -> [Vec2?] {
        let n = min(a.frameTimes.count, a.rolling.count)
        var out = [Vec2?](repeating: nil, count: n)
        let cuts = Set(a.cuts)
        for i in stride(from: 1, to: n, by: 1) where !cuts.contains(i) {
            guard let s = a.rolling[i] else { continue }
            let dt = seconds(a.frameTimes[i] - a.frameTimes[i - 1])
            guard dt > 0, s.shiftX.isFinite, s.shiftY.isFinite else { continue }
            out[i] = Vec2(s.shiftX / dt, s.shiftY / dt)
        }
        return out
    }

    /// Median interval between analyzed frames, seconds (0 when there are fewer than two).
    static func frameInterval(_ a: StabilizationAnalysis) -> Double {
        let d = zip(a.frameTimes.dropFirst(), a.frameTimes).map { seconds($0 - $1) }.filter { $0 > 0 }.sorted()
        return d.isEmpty ? 0 : d[d.count / 2]
    }

    /// The longest a sensor can take to read one frame: the source's own frame interval. The analyzed frames are
    /// coarser on a high frame rate (the analyzer skips frames closer than 24 ms), so their interval only stands in
    /// when the source's is not known; 1/24 s when there is neither.
    static func readoutCap(_ a: StabilizationAnalysis) -> Double {
        let analyzed = frameInterval(a)
        if a.sourceFrameInterval > 0 { return analyzed > 0 ? min(a.sourceFrameInterval, analyzed) : a.sourceFrameInterval }
        return analyzed > 0 ? analyzed : 1.0 / 24
    }

    /// The shot's readout time: least squares of the measured slopes against the velocity changes, both axes pooled,
    /// observations far off the fit dropped once. Falls back to `typicalReadout` (signed by the scan direction) when
    /// the camera's speed never changes enough to tell.
    public static func estimate(_ a: StabilizationAnalysis) -> Estimate {
        let vel = pairVelocities(a), n = vel.count
        var obs: [(s: Double, dv: Double)] = []
        for i in stride(from: 2, to: n - 1, by: 1) {
            guard let before = vel[i - 1], vel[i] != nil, let after = vel[i + 1], let s = a.rolling[i],
                  s.slopeX.isFinite, s.slopeY.isFinite else { continue }
            // vel at frame i minus vel at frame i-1, each the mean of the two pairs around it.
            obs.append((s.slopeX, (after.x - before.x) / 2))
            obs.append((s.slopeY, (after.y - before.y) / 2))
        }
        func fit(_ o: [(s: Double, dv: Double)]) -> (t: Double, error: Double)? {
            let den = o.reduce(0) { $0 + $1.dv * $1.dv }
            guard o.count >= 2, den > 0 else { return nil }
            let t = o.reduce(0) { $0 + $1.s * $1.dv } / den
            let rss = o.reduce(0) { $0 + ($1.s - t * $1.dv) * ($1.s - t * $1.dv) }
            return (t, (rss / Double(o.count - 1) / den).squareRoot())
        }
        var result = fit(obs)
        if let first = result, obs.count >= minObservations {
            let res = obs.map { abs($0.s - first.t * $0.dv) }
            let limit = 3 * res.sorted()[res.count / 2] + 1e-9
            let kept = zip(obs, res).filter { $0.1 <= limit }.map(\.0)
            if kept.count >= minObservations, let again = fit(kept) { result = again; obs = kept }
        }
        let cap = readoutCap(a)
        // A camera whose speed never changes shows no slope at all, whatever its sensor: that is not a measurement.
        let change = obs.isEmpty ? 0 : (obs.reduce(0) { $0 + $1.dv * $1.dv } / Double(obs.count)).squareRoot()
        if let r = result, obs.count >= minObservations, change >= minVelocityChange, r.t.isFinite, r.error.isFinite,
           r.error <= maxError {
            return Estimate(readout: min(max(r.t, -cap), cap), measured: true, observations: obs.count, error: r.error)
        }
        // Scan direction of the upright picture (see `StabilizationAnalysis.rollingScan`): 1 and 2 read against the axis.
        let sign: Double = a.rollingScan == 1 || a.rollingScan == 2 ? -1 : 1
        return Estimate(readout: sign * min(typicalReadout, 0.6 * cap), measured: false, observations: obs.count,
                        error: result?.error ?? .infinity)
    }

    /// The shear of every analyzed frame as a fraction of the scan extent (picture height, or width when the sensor rows
    /// stand upright): `readout` times the frame's velocity, the mean of the two pairs around it inside a shot.
    public static func shears(_ a: StabilizationAnalysis, readout: Double) -> [Vec2] {
        let vel = pairVelocities(a), n = a.frameTimes.count
        let extent = Double(a.rollingScansAlongX ? a.pictureWidth : a.pictureHeight)
        guard extent > 0, readout.isFinite else { return [Vec2](repeating: .zero, count: n) }
        return (0..<n).map { i in
            let into = i < vel.count ? vel[i] : nil                    // pair i-1 -> i
            let out = i + 1 < vel.count ? vel[i + 1] : nil             // pair i -> i+1 (nil across a cut)
            let v: Vec2
            switch (into, out) {
            case let (p?, q?): v = Vec2((p.x + q.x) / 2, (p.y + q.y) / 2)
            case let (p?, nil): v = p
            case let (nil, q?): v = q
            default: v = .zero
            }
            return Vec2(v.x * readout / extent, v.y * readout / extent)
        }
    }

    /// The shear at source time `t`: linear between analyzed frames, held before the first, after the last and up to a cut.
    public static func shear(_ shears: [Vec2], _ a: StabilizationAnalysis, at t: Time) -> Vec2 {
        let ts = a.frameTimes, n = min(shears.count, ts.count)
        guard n > 0 else { return .zero }
        var lo = 0, hi = n          // first index with ts[i] > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return shears[0] }
        let i = lo - 1
        if i == n - 1 || ts[i] == t || a.cuts.contains(i + 1) { return shears[i] }
        let f = seconds(t - ts[i]) / seconds(ts[i + 1] - ts[i])
        guard f.isFinite, f > 0 else { return shears[i] }
        return Vec2.lerp(shears[i], shears[i + 1], f)
    }
}

extension ClipEffect {
    // Stored parameter keys of the Stabilizer's rolling shutter option (never rename). The shear keys are generated data
    // like the stage keys: fraction of the scan extent per clip frame, written by `Stabilizer.effect`.
    public static let rollingShutterKey = "rollingShutter", rollingShutterStrengthKey = "rollingShutterStrength"
    public static let rollingShearXKey = "rollingShearX", rollingShearYKey = "rollingShearY"
    /// 1: the sensor rows stand upright in the picture (footage stored turned by a quarter), the scan axis is x.
    public static let rollingScanAxisKey = "rollingScanAxis"

    /// The row shift a Standard Stabilizer with Rolling Shutter on applies at clip-local `t`; nil when the option is
    /// off, nothing was measured or the picture stands still (no pass is planned then).
    public func rollingShutterFilter(atLocal t: Time) -> ImageFilter? {
        guard kind == Self.stabilizeKind, stabilizeMethod == .standard else { return nil }
        let alongX = (parameters[Self.rollingScanAxisKey]?.value ?? 0) >= 0.5
        var shear: Vec2?
        if flag(Self.rollingShutterKey, atLocal: t), let x = parameters[Self.rollingShearXKey], let y = parameters[Self.rollingShearYKey] {
            let k = min(max(scalar(Self.rollingShutterStrengthKey, atLocal: t), 0), 200) / 100
            let s = Vec2(x.value(atLocal: t) * k, y.value(atLocal: t) * k)
            if s.x.isFinite, s.y.isFinite, abs(s.x) > 2e-5 || abs(s.y) > 2e-5 { shear = s }
        }
        // The residual perspective rides in the same warp pass (one resampling for both).
        let keys = Self.stabilizePerspectiveKeys
        var h: [Double] = []
        if keys.contains(where: { parameters[$0] != nil }) {
            h = keys.map { parameters[$0]?.value(atLocal: t) ?? 0 }
            if !h.allSatisfy(\.isFinite) || h.allSatisfy({ abs($0) <= Stabilizer.perspectiveFloor }) { h = [] }
        }
        if h.isEmpty { return shear.map { .rollingShutter(shear: $0, alongX: alongX) } }
        return .stabilizeWarp(shear: shear ?? .zero, alongX: alongX, perspective: h)
    }
}
