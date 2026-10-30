import Foundation

// FB-B3 Color Match (Premiere Lumetri "Color Wheels & Match" > Apply Match). The reference is measured once ("Set
// Reference": the Program frame at the playhead, usually on another shot) and stored with the Color effect as statistics,
// so the match never needs the reference shot again and survives moving or deleting it. "Match" measures the clip's own
// frame and sets the Color Wheels (three wheels, their luma sliders, Wheels Saturation) so the clip's shadow, midtone and
// highlight color and its colorfulness come out like the reference's. Pure maths, display-free; ProjectFile v43.
// C2 (2026-10-07): the targets are planned in Oklab with skin protection and a hue-cast clamp (ColorMatchOklab.swift);
// stored stats and stored wheels are unchanged, so old projects render as before and only a new Match uses this.

/// Color statistics of one frame, on the display-encoded (BT.709 OETF) signal the Color Wheels work on.
public struct ColorMatchStats: Sendable, Hashable, Codable {
    /// Mean color of each tone band (soft luma masks: shadows, midtones, highlights).
    public var shadows: SIMD3<Float>
    public var midtones: SIMD3<Float>
    public var highlights: SIMD3<Float>
    /// Share of the picture in each band (x shadows, y midtones, z highlights; sums to 1).
    public var weights: SIMD3<Float>
    /// Mean distance of a pixel from its gray (how colorful the picture is).
    public var chroma: Float

    public init(shadows: SIMD3<Float>, midtones: SIMD3<Float>, highlights: SIMD3<Float>, weights: SIMD3<Float>, chroma: Float) {
        self.shadows = shadows; self.midtones = midtones; self.highlights = highlights; self.weights = weights; self.chroma = chroma
    }

    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Soft band masks of a display luma: shadows fall off by 0.5, highlights rise from 0.5, midtones are the rest.
    static func bandWeights(_ y: Float) -> SIMD3<Float> {
        let s = 1 - AutoToneSolver.smooth(0, 0.5, y), h = AutoToneSolver.smooth(0.5, 1, y)
        return SIMD3(s, max(1 - s - h, 0), h)
    }

    /// Statistics of display-encoded samples (non-finite samples are skipped). nil with fewer than 16 usable samples.
    public static func measure(_ display: [SIMD3<Float>]) -> ColorMatchStats? {
        var sum = [SIMD3<Float>](repeating: .zero, count: 3)
        var w = SIMD3<Float>.zero
        var chroma: Float = 0
        var n = 0
        for p in display where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            let c = simd_clamp3(p, 0, 1.5)
            let y = (luma * c).sum()
            let b = bandWeights(y)
            sum[0] += b.x * c; sum[1] += b.y * c; sum[2] += b.z * c
            w += b
            let d = c - SIMD3(repeating: y)
            chroma += (d * d).sum().squareRoot()
            n += 1
        }
        guard n >= 16 else { return nil }
        func mean(_ i: Int, _ wi: Float) -> SIMD3<Float> {
            wi > 1e-4 ? sum[i] / wi : SIMD3(repeating: [0.1, 0.45, 0.85][i])
        }
        return ColorMatchStats(shadows: mean(0, w.x), midtones: mean(1, w.y), highlights: mean(2, w.z),
                               weights: w / Float(n), chroma: chroma / Float(n))
    }

    var bands: [SIMD3<Float>] { [shadows, midtones, highlights] }
}

@inline(__always) func simd_clamp3(_ v: SIMD3<Float>, _ lo: Float, _ hi: Float) -> SIMD3<Float> {
    SIMD3(min(max(v.x, lo), hi), min(max(v.y, lo), hi), min(max(v.z, lo), hi))
}

/// The reference a Color effect matches to: where it was taken (for the label) and what it looked like.
public struct ColorMatchReference: Sendable, Hashable, Codable {
    /// The clip the reference frame showed (topmost picture at the playhead), nil when none could be named.
    public var clip: UUID?
    /// Sequence time of the reference frame.
    public var time: Time
    /// Name shown in Effect Controls ("A012 @ 00:00:04:12").
    public var label: String
    public var stats: ColorMatchStats

    public init(clip: UUID?, time: Time, label: String, stats: ColorMatchStats) {
        self.clip = clip; self.time = time; self.label = label; self.stats = stats
    }
}

/// Gray-axis-free model of the Color Wheels on the display signal: a copy of SQRender `PreparedWheels.apply(_, pre: false)`
/// (Rec.709 luma), kept in sync by a test there.
public enum ColorWheelsModel {
    static let luma = ColorMatchStats.luma

    static func hueRGB(_ hueDegrees: Float) -> SIMD3<Float> {
        var h = hueDegrees / 360
        h -= floorf(h)
        func ch(_ o: Float) -> Float {
            var x = h + o
            x -= floorf(x)
            return min(max(fabsf(x * 6 - 3) - 1, 0), 1)
        }
        return SIMD3(ch(0), ch(2.0 / 3), ch(1.0 / 3))
    }

    static func offset(_ w: WheelValue) -> SIMD3<Float> {
        guard w.amount > 0 else { return .zero }
        let c = hueRGB(w.hue)
        return min(w.amount, 1) * (c - SIMD3(repeating: c.sum() / 3))
    }

    /// The wheel position whose offset is `v` (any vector; its gray part is ignored), amount clamped to 1.
    static func wheel(offset v: SIMD3<Float>) -> WheelValue {
        let z = v - SIMD3(repeating: v.sum() / 3)
        let mx = z.max(), mn = z.min()
        guard mx - mn > 1e-6 else { return WheelValue() }
        // HSV hue of z (adding gray does not change it).
        var h: Float
        if mx == z.x { h = (z.y - z.z) / (mx - mn) }
        else if mx == z.y { h = 2 + (z.z - z.x) / (mx - mn) }
        else { h = 4 + (z.x - z.y) / (mx - mn) }
        h *= 60
        if h < 0 { h += 360 }
        let c = hueRGB(h)
        let unit = c - SIMD3(repeating: c.sum() / 3)
        let len = (unit * unit).sum().squareRoot()
        let amount = min((z * z).sum().squareRoot() / max(len, 1e-6), 1)
        return WheelValue(hue: h, amount: amount)
    }

    struct Prepared {
        let lift: SIMD3<Float>, gammaExponent: SIMD3<Float>, hasGamma: Bool, gain: SIMD3<Float>, saturation: Float
        init(_ w: ColorWheels) {
            func n(_ v: Float) -> Float { min(max(v, -100), 100) / 100 }
            lift = 0.22 * offset(w.shadows) + SIMD3(repeating: 0.15 * n(w.shadowsLuma))
            let m = 0.5 * offset(w.midtones) + SIMD3(repeating: 0.45 * n(w.midtonesLuma))
            gammaExponent = SIMD3(exp2f(-m.x), exp2f(-m.y), exp2f(-m.z))
            hasGamma = !w.midtones.isNeutral || w.midtonesLuma != 0
            gain = 0.3 * offset(w.highlights) + SIMD3(repeating: 0.25 * n(w.highlightsLuma))
            saturation = min(max(w.saturation, 0), 200) / 100
        }
        func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
            typealias S = AutoToneSolver
            var t = c
            t += (1 - S.smooth(0, 0.5, (luma * t).sum())) * lift
            if hasGamma {
                let y = (luma * t).sum()
                let wm = S.smooth(0, 0.5, y) * (1 - S.smooth(0.5, 1, y))
                let p = SIMD3(powf(max(t.x, 0), gammaExponent.x), powf(max(t.y, 0), gammaExponent.y), powf(max(t.z, 0), gammaExponent.z))
                t += (p - t) * wm
            }
            t *= SIMD3<Float>(repeating: 1) + S.smooth(0.35, 1.15, (luma * t).sum()) * gain
            if saturation != 1 {
                let y = (luma * t).sum()
                t = SIMD3(repeating: y) + (t - SIMD3(repeating: y)) * saturation
            }
            return t
        }
    }

    /// A display-encoded color through the wheels.
    public static func apply(_ c: SIMD3<Float>, _ w: ColorWheels) -> SIMD3<Float> {
        w.isNeutral ? c : Prepared(w).apply(c)
    }

    /// The color before the wheels (numeric inverse; the wheels move a color only a little, so it converges fast).
    static func unapply(_ y: SIMD3<Float>, _ p: Prepared) -> SIMD3<Float> {
        var x = y
        for _ in 0..<24 {
            let d = y - p.apply(x)
            x += d
            if (d * d).sum() < 1e-10 { break }
        }
        return x
    }
}

/// Solves the Color Wheels that match a clip to a `ColorMatchStats` reference.
public enum ColorMatchSolver {
    /// Pull towards no change (keeps a weak match mild and the solve stable when a band is nearly empty).
    static let regularisation: Float = 0.02
    static let maxSamples = 1600
    /// Sample colors the wheels are fitted on (C2).
    static let fitSamples = 400
    /// Weight of the per-color Oklab targets against the band means.
    static let pixelWeight: Float = 0.5

    /// Why Match cannot run on this Color effect (nil = it can). The wheels model is the display signal of a Rec.709 picture
    /// with nothing after the wheels; the Program frame is measured as shown.
    public static func blockReason(effect e: ColorEffect, source: ColorSpaceID, reference: ColorMatchReference?) -> String? {
        if source != .rec709 {
            return "Match works on Rec. 709 footage. This clip is interpreted as \(source.displayName); grade it by hand."
        }
        if !e.isEnabled(.wheels) { return "Turn on Wheels & Match to use Match." }
        if e.isEnabled(.vignette) && !e.isNeutral(.vignette) {
            return "Match would measure the Vignette too. Reset or switch off Vignette first."
        }
        if reference == nil { return "Set a reference frame first: park the playhead on the shot to match and press Set Reference." }
        return nil
    }

    /// Parameters: shadows (luma, a, b), midtones (luma, a, b), highlights (luma, a, b), saturation; a/b span the plane of
    /// zero-mean color offsets.
    static let u1 = SIMD3<Float>(2, -1, -1) / Float(6).squareRoot()
    static let u2 = SIMD3<Float>(0, 1, -1) / Float(2).squareRoot()

    static func wheels(_ p: [Float], base: ColorWheels) -> ColorWheels {
        var w = base
        w.shadowsLuma = min(max(p[0] * 100, -100), 100)
        w.shadows = ColorWheelsModel.wheel(offset: p[1] * u1 + p[2] * u2)
        w.midtonesLuma = min(max(p[3] * 100, -100), 100)
        w.midtones = ColorWheelsModel.wheel(offset: p[4] * u1 + p[5] * u2)
        w.highlightsLuma = min(max(p[6] * 100, -100), 100)
        w.highlights = ColorWheelsModel.wheel(offset: p[7] * u1 + p[8] * u2)
        w.saturation = min(max(100 * (1 + p[9]), 0), 200)
        return w
    }

    /// Rounded like the sliders (hue 0.1 degree, amount 0.01, luma and saturation 0.1).
    static func rounded(_ w: ColorWheels) -> ColorWheels {
        func r(_ v: Float, _ s: Float) -> Float { (v * s).rounded() / s }
        func r(_ v: WheelValue) -> WheelValue {
            let a = r(v.amount, 100)
            return a <= 0 ? WheelValue() : WheelValue(hue: r(v.hue, 10).truncatingRemainder(dividingBy: 360), amount: a)
        }
        var o = w
        o.shadows = r(w.shadows); o.midtones = r(w.midtones); o.highlights = r(w.highlights)
        o.shadowsLuma = r(w.shadowsLuma, 10); o.midtonesLuma = r(w.midtonesLuma, 10); o.highlightsLuma = r(w.highlightsLuma, 10)
        o.saturation = r(w.saturation, 10)
        return o
    }

    /// New Color Wheels for the clip, or nil when there is nothing to do (too few samples, or the wheels already are the
    /// match). `display`: the clip's frame as shown (display-encoded, with the `current` wheels applied). The current wheels
    /// are taken out first and the result is solved absolutely, so pressing Match twice changes nothing.
    public static func solve(display: [SIMD3<Float>], current: ColorWheels, reference: ColorMatchStats) -> ColorWheels? {
        let finite = display.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard finite.count >= 16 else { return nil }
        let stride = max(1, finite.count / maxSamples)
        var px: [SIMD3<Float>] = []
        px.reserveCapacity(finite.count / stride + 1)
        var i = 0
        while i < finite.count { px.append(finite[i]); i += stride }
        if !current.isNeutral {
            let prep = ColorWheelsModel.Prepared(current)
            px = px.map { ColorWheelsModel.unapply($0, prep) }
        }
        guard let clipStats = ColorMatchStats.measure(px) else { return nil }

        // C2: per-color Oklab targets (band shifts, chroma, hue-cast clamp, skin protection), fitted by running the wheels
        // model on a few hundred samples. Each band counts by the reference's share of it, not by the clip's pixel count.
        let fitStride = max(1, px.count / fitSamples)
        let samples = Swift.stride(from: 0, to: px.count, by: fitStride).map { px[$0] }
        let plan = ColorMatchTargets(clip: clipStats, reference: reference, calibrateOn: samples)
        let targets = samples.map { plan.target(Oklab.fromDisplay($0), display: $0) }
        let bandShare = SIMD3<Float>(reference.weights.x / max(clipStats.weights.x, 0.02),
                                     reference.weights.y / max(clipStats.weights.y, 0.02),
                                     reference.weights.z / max(clipStats.weights.z, 0.02))
        var sampleWeight = samples.map { c -> Float in
            (ColorMatchStats.bandWeights((ColorMatchStats.luma * simd_clamp3(c, 0, 1.5)).sum()) * bandShare).sum()
        }
        let total = max(sampleWeight.reduce(0, +), 1e-6)
        sampleWeight = sampleWeight.map { pixelWeight * ($0 / total).squareRoot() }
        // The band means and colorfulness the targets add up to (the reference's, less what skin and the hue clamp hold
        // back): matched directly as well, so the wheels land the bands even where they cannot follow every color.
        guard let goal = ColorMatchStats.measure(targets.map(Oklab.toDisplay)) else { return nil }
        let goalBands = goal.bands
        let bandScale = SIMD3<Float>(reference.weights.x.squareRoot(), reference.weights.y.squareRoot(),
                                     reference.weights.z.squareRoot())
        let count = samples.count * 3 + 20

        func residual(_ p: [Float]) -> [Float] {
            let prep = ColorWheelsModel.Prepared(wheels(p, base: current))
            var r: [Float] = []
            r.reserveCapacity(count)
            let shown = samples.map(prep.apply)
            for i in samples.indices {
                let d = (Oklab.fromDisplay(shown[i]) - targets[i]) * sampleWeight[i]
                r += [d.x, d.y, d.z]
            }
            if let s = ColorMatchStats.measure(shown) {
                for (b, band) in s.bands.enumerated() {
                    let d = (band - goalBands[b]) * bandScale[b]
                    r += [d.x, d.y, d.z]
                }
                r.append(s.chroma - goal.chroma)
            } else {
                r += [Float](repeating: 0, count: 10)
            }
            for v in p { r.append(regularisation * v) }
            return r
        }
        func cost(_ r: [Float]) -> Float { r.reduce(0) { $0 + $1 * $1 } }

        let n = 10
        var p = [Float](repeating: 0, count: n)
        var r = residual(p)
        var c = cost(r)
        var mu: Float = 1e-3
        for _ in 0..<30 {
            // Numeric Jacobian (forward differences).
            let h: Float = 1e-3
            var J = [[Float]](repeating: [Float](repeating: 0, count: n), count: r.count)
            for j in 0..<n {
                var q = p; q[j] += h
                let rq = residual(q)
                for k in 0..<r.count { J[k][j] = (rq[k] - r[k]) / h }
            }
            var A = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
            var g = [Float](repeating: 0, count: n)
            for k in 0..<r.count {
                for a in 0..<n {
                    g[a] += J[k][a] * r[k]
                    for b in 0..<n { A[a][b] += J[k][a] * J[k][b] }
                }
            }
            var improved = false
            for _ in 0..<8 {
                var M = A
                for a in 0..<n { M[a][a] += mu * max(A[a][a], 1e-6) + 1e-9 }
                guard let step = Self.solveLinear(M, g.map { -$0 }) else { mu *= 10; continue }
                let q = zip(p, step).map { min(max($0 + $1, -1), 1) }
                let rq = residual(q)
                let cq = cost(rq)
                if cq < c {
                    let gain = c - cq
                    p = q; r = rq; c = cq; mu = max(mu / 3, 1e-6); improved = true
                    if gain < 1e-9 { improved = false }
                    break
                }
                mu *= 10
            }
            if !improved { break }
        }
        let out = rounded(wheels(p, base: current))
        return out == rounded(current) ? nil : out
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solveLinear(_ m: [[Float]], _ b: [Float]) -> [Float]? {
        let n = b.count
        var a = m, x = b
        for col in 0..<n {
            var piv = col
            for row in col + 1..<n where abs(a[row][col]) > abs(a[piv][col]) { piv = row }
            guard abs(a[piv][col]) > 1e-12 else { return nil }
            if piv != col { a.swapAt(piv, col); x.swapAt(piv, col) }
            for row in col + 1..<n {
                let f = a[row][col] / a[col][col]
                guard f != 0 else { continue }
                for k in col..<n { a[row][k] -= f * a[col][k] }
                x[row] -= f * x[col]
            }
        }
        var out = [Float](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = x[row]
            for k in row + 1..<n { s -= a[row][k] * out[k] }
            out[row] = s / a[row][row]
        }
        return out
    }
}

extension Project {
    /// Any Color effect with a stored match reference (gates ProjectFile v43).
    public var containsColorMatch: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains { $0.effects.contains { $0.grade?.match != nil } } } }
    }
}
