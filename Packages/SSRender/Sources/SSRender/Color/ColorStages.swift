import Foundation
import simd
import SSCore

/// Per-pixel maths of the Lumetri-like colour blocks (docs/DECISIONS.md 2026-10-01). Everything works on a *tone
/// signal* `t`: the Rec.709-encoded (gamma) picture signal, 0…1 for SDR, unclamped beyond. A block after the Input LUT
/// receives `t` directly (display-referred). A block before it receives source-linear light and is wrapped
/// (`t = OETF(linear)` -> maths -> `linear = OETF⁻¹(t)`), so the same controls feel the same in both positions.
/// Written per pixel on `SIMD3<Float>`; `ColorShaderSource` ports each function 1:1 to MSL (same constants).
enum ToneMath {
    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Full-saturation, full-value RGB of a hue in degrees.
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

    /// Zero-mean RGB offset for a wheel position (neutral on the grey axis, so it tints without changing brightness).
    static func wheelOffset(_ w: WheelValue) -> SIMD3<Float> {
        guard w.amount > 0 else { return .zero }
        let c = hueRGB(w.hue)
        return min(w.amount, 1) * (c - SIMD3(repeating: (c.x + c.y + c.z) / 3))
    }

    /// 0…1: how "skin-like" a colour is (hue between orange and yellow-orange, red-dominant).
    static func skinWeight(_ t: SIMD3<Float>) -> Float {
        guard t.x >= t.y, t.y >= t.z, t.x > t.z else { return 0 }
        let f = (t.y - t.z) / (t.x - t.z)
        return smooth(0.10, 0.30, f) * (1 - smooth(0.70, 0.95, f))
    }

    /// Saturation (1 = neutral) and vibrance (-1…1). Vibrance lifts low-saturation colours more than saturated ones
    /// and protects skin tones; negative vibrance mutes saturated colours first.
    static func satVib(_ t: SIMD3<Float>, sat: Float, vib: Float, luma: SIMD3<Float>) -> SIMD3<Float> {
        var s = sat
        if vib != 0 {
            let mx = max(t.x, max(t.y, t.z)), mn = min(t.x, min(t.y, t.z))
            let sv = mx > 1e-4 ? min(max((mx - mn) / mx, 0), 1) : 0
            if vib > 0 { s *= 1 + vib * (1 - sv) * (1 - 0.5 * skinWeight(t)) } else { s *= 1 + vib * (0.3 + 0.7 * sv) }
        }
        if s == 1 { return t }
        let y = simd_dot(luma, t)
        return SIMD3(repeating: y) + (t - SIMD3(repeating: y)) * s
    }

    static let contrastPivot: Float = 0.45
}

// MARK: Basic Correction

/// Lumetri Basic Correction: White Balance (Temperature, Tint) and Exposure act on linear light (like a real exposure
/// / white-balance change); Contrast, Highlights, Shadows, Whites, Blacks act on the tone signal with soft luminance
/// masks (Whites/Blacks move the white/black point); then Saturation and Vibrance.
public struct PreparedBasic: Sendable, Equatable {
    let wb: simd_float3x3
    let hasWB: Bool
    let exposureScale: Float
    let hasExposure: Bool
    let contrastK: Float
    let highlights: Float     // signed offset at full mask
    let shadows: Float
    let blackPoint: Float
    let whitePoint: Float
    let hasContrast: Bool
    let hasHighlights: Bool
    let hasShadows: Bool
    let hasLevels: Bool
    let saturation: Float
    let vibrance: Float
    let luma: SIMD3<Float>

    static let cctReference = 1e6 / 6504.0

    /// `gamut`: the primaries the block's linear signal is in (the source gamut before the Input LUT, Rec.709 after it).
    init(_ c: BasicCorrection, gamut: Gamut) {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
        let temp = clamp(c.temperature, -100, 100), tint = clamp(c.tint, -100, 100)
        hasWB = temp != 0 || tint != 0
        if hasWB {
            let mired = Self.cctReference - Double(temp)
            // Positive tint -> magenta image: the assumed scene white is greenish (Duv > 0).
            let scene = WhitePoint.xy(cct: 1e6 / mired, duv: Double(tint) * 0.0002)
            let ref = WhitePoint.xy(cct: 1e6 / Self.cctReference, duv: 0)
            let a = WhitePoint.bradford(from: WhitePoint.xyz(scene), to: WhitePoint.xyz(ref))
            wb = (gamut.rgbToXYZDouble.inverse * a * gamut.rgbToXYZDouble).toFloat
        } else {
            wb = matrix_identity_float3x3
        }
        let ev = clamp(c.exposure, -5, 5)
        hasExposure = ev != 0
        exposureScale = exp2f(ev)
        let con = clamp(c.contrast, -100, 100) / 100
        hasContrast = con != 0
        contrastK = con >= 0 ? 1 + 0.8 * con : 1 + 0.7 * con
        let h = clamp(c.highlights, -100, 100) / 100, s = clamp(c.shadows, -100, 100) / 100
        highlights = 0.3 * h
        shadows = s > 0 ? 1.4 * s : s
        hasHighlights = h != 0
        hasShadows = s != 0
        let w = clamp(c.whites, -100, 100) / 100, b = clamp(c.blacks, -100, 100) / 100
        whitePoint = 1 - 0.2 * w
        blackPoint = -0.1 * b
        hasLevels = w != 0 || b != 0
        saturation = clamp(c.saturation, 0, 200) / 100
        vibrance = clamp(c.vibrance, -100, 100) / 100
        luma = gamut.lumaRow
    }

    var hasLinear: Bool { hasWB || hasExposure }
    var hasToneStage: Bool { hasContrast || hasShadows || hasHighlights || hasLevels || saturation != 1 || vibrance != 0 }

    /// `pre`: the signal is source-linear light (block before the Input LUT); otherwise it is the tone signal.
    public func apply(_ c: SIMD3<Float>, pre: Bool) -> SIMD3<Float> {
        var x = c
        if hasLinear {
            var lin = pre ? x : TransferFunctions.bt709InverseOETF(x)
            if hasWB { lin = wb * lin }
            if hasExposure { lin *= exposureScale }
            x = pre ? lin : TransferFunctions.bt709OETF(lin)
        }
        if hasToneStage {
            var t = pre ? TransferFunctions.bt709OETF(x) : x
            if hasContrast { t = SIMD3(repeating: ToneMath.contrastPivot) + (t - SIMD3(repeating: ToneMath.contrastPivot)) * contrastK }
            // Shadows scale the dark end multiplicatively (black stays black); Highlights add a soft-masked offset.
            // Each stage is monotone on its own (and masks come from the running signal), so the tone curve never folds.
            if hasShadows {
                let y = simd_dot(luma, t)
                t *= 1 + shadows * (1 - ToneMath.smooth(0, 0.6, y))
            }
            if hasHighlights {
                let y = simd_dot(luma, t)
                t += SIMD3(repeating: highlights * ToneMath.smooth(0.3, 1.0, y))
            }
            if hasLevels { t = (t - SIMD3(repeating: blackPoint)) / (whitePoint - blackPoint) }
            t = ToneMath.satVib(t, sat: saturation, vib: vibrance, luma: luma)
            x = pre ? TransferFunctions.bt709InverseOETF(t) : t
        }
        return x
    }
}

// MARK: Creative (tone part; the look LUT is a separate op)

public struct PreparedCreative: Sendable, Equatable {
    let fade: Float
    let saturation: Float
    let vibrance: Float
    let shadowTint: SIMD3<Float>
    let highlightTint: SIMD3<Float>
    let balance: Float
    let hasTint: Bool
    let luma: SIMD3<Float>

    init(_ c: CreativeLook, gamut: Gamut) {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
        fade = 0.16 * clamp(c.fadedFilm, 0, 100) / 100
        saturation = clamp(c.saturation, 0, 200) / 100
        vibrance = clamp(c.vibrance, -100, 100) / 100
        shadowTint = 0.25 * ToneMath.wheelOffset(c.shadowTint)
        highlightTint = 0.25 * ToneMath.wheelOffset(c.highlightTint)
        balance = clamp(c.tintBalance, -100, 100) / 100
        hasTint = !c.shadowTint.isNeutral || !c.highlightTint.isNeutral
        luma = gamut.lumaRow
    }

    public func apply(_ c: SIMD3<Float>, pre: Bool) -> SIMD3<Float> {
        var t = pre ? TransferFunctions.bt709OETF(c) : c
        if fade != 0 { t = t * (1 - fade) + SIMD3(repeating: fade * 0.85) }
        if hasTint {
            let y = simd_dot(luma, t)
            let ms = 1 - ToneMath.smooth(0.15 + 0.25 * balance, 0.65 + 0.25 * balance, y)
            let mh = ToneMath.smooth(0.35 + 0.25 * balance, 0.85 + 0.25 * balance, y)
            t += ms * shadowTint + mh * highlightTint
        }
        t = ToneMath.satVib(t, sat: saturation, vib: vibrance, luma: luma)
        return pre ? TransferFunctions.bt709InverseOETF(t) : t
    }
}

// MARK: Wheels

/// Three-way colour wheels: lift (shadows, additive), gamma (midtones, power) and gain (highlights, multiplicative),
/// weighted by soft luminance masks. Each wheel is a zero-mean colour offset plus a luminance slider.
public struct PreparedWheels: Sendable, Equatable {
    let lift: SIMD3<Float>
    let gammaExponent: SIMD3<Float>
    let hasGamma: Bool
    let gain: SIMD3<Float>
    let saturation: Float
    let luma: SIMD3<Float>

    init(_ w: ColorWheels, gamut: Gamut) {
        func n(_ v: Float) -> Float { min(max(v, -100), 100) / 100 }
        lift = 0.22 * ToneMath.wheelOffset(w.shadows) + SIMD3(repeating: 0.15 * n(w.shadowsLuma))
        let m = 0.5 * ToneMath.wheelOffset(w.midtones) + SIMD3(repeating: 0.45 * n(w.midtonesLuma))
        gammaExponent = SIMD3(exp2f(-m.x), exp2f(-m.y), exp2f(-m.z))
        hasGamma = !w.midtones.isNeutral || w.midtonesLuma != 0
        gain = 0.3 * ToneMath.wheelOffset(w.highlights) + SIMD3(repeating: 0.25 * n(w.highlightsLuma))
        saturation = min(max(w.saturation, 0), 200) / 100
        luma = gamut.lumaRow
    }

    public func apply(_ c: SIMD3<Float>, pre: Bool) -> SIMD3<Float> {
        // Each stage takes its luminance mask from the running signal, so the chain is a composition of monotone
        // maps: at the slider limits the grey ramp never folds.
        var t = pre ? TransferFunctions.bt709OETF(c) : c
        t += (1 - ToneMath.smooth(0, 0.5, simd_dot(luma, t))) * lift
        if hasGamma {
            let y = simd_dot(luma, t)
            let wm = ToneMath.smooth(0, 0.5, y) * (1 - ToneMath.smooth(0.5, 1, y))
            let p = SIMD3(powf(max(t.x, 0), gammaExponent.x), powf(max(t.y, 0), gammaExponent.y), powf(max(t.z, 0), gammaExponent.z))
            t += (p - t) * wm
        }
        t *= SIMD3<Float>(repeating: 1) + ToneMath.smooth(0.35, 1.15, simd_dot(luma, t)) * gain
        t = ToneMath.satVib(t, sat: saturation, vib: 0, luma: luma)
        return pre ? TransferFunctions.bt709InverseOETF(t) : t
    }
}

// MARK: Vignette

public struct PreparedVignette: Sendable, Equatable {
    let amount: Float
    let start: Float
    let feather: Float
    let exponent: Float
    let aspectMix: Float

    init(_ v: Vignette) {
        amount = min(max(v.amount, -5), 5)
        let mid = min(max(v.midpoint, 0), 100) / 100
        start = 1.3 - 1.1 * mid
        feather = 0.1 + 1.4 * min(max(v.feather, 0), 100) / 100
        let r = min(max(v.roundness, -100), 100) / 100
        exponent = 2 + 2 * max(-r, 0)
        aspectMix = max(r, 0)
    }

    /// `uv`: 0…1 position in the frame (y down); `aspect`: frame width / height.
    public func apply(_ c: SIMD3<Float>, uv: SIMD2<Float>, aspect: Float, pre: Bool) -> SIMD3<Float> {
        let px = (uv.x - 0.5) * 2 * (1 + (aspect - 1) * aspectMix), py = (uv.y - 0.5) * 2
        let e = exponent > 2.0001
            ? powf(powf(fabsf(px), exponent) + powf(fabsf(py), exponent), 1 / exponent)
            : sqrtf(px * px + py * py)
        let m = ToneMath.smooth(start, start + feather, e)
        // A gain of 2^(amount·m) stops on linear light is 2^(0.45·amount·m) on the gamma-encoded signal.
        return pre ? c * exp2f(amount * m) : c * exp2f(0.45 * amount * m)
    }
}

// MARK: Hue Saturation Curves

/// Lumetri Hue Saturation Curves. Five curves (Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat) all sample
/// the colour that enters the block (they run in parallel, as in Premiere), then adjust it together: hue shift
/// (up to +-60 degrees, rotation about the grey axis), saturation (x0…x2 around the luma) and luma (+-1 stop). The
/// hue-keyed adjustments fade out towards grey, where hue is undefined. y = 0.5 is "no change".
public struct PreparedHueCurves: Sendable, Equatable {
    public static let count = 64
    /// Rows 0…63 hold (hueVsSat, hueVsHue, hueVsLuma, lumaVsSat), rows 64…127 hold (satVsSat, 0, 0, 0).
    let table: [SIMD4<Float>]
    let luma: SIMD3<Float>
    static let maxHueShift: Float = Float.pi / 3

    init(_ h: HueCurves, gamut: Gamut) {
        let n = Self.count
        var rows = [SIMD4<Float>](repeating: .zero, count: 2 * n)
        let hs = Self.periodic(h.hueVsSat, n), hh = Self.periodic(h.hueVsHue, n), hl = Self.periodic(h.hueVsLuma, n)
        let ls = CurveMath.sample(h.lumaVsSat, n), ss = CurveMath.sample(h.satVsSat, n)
        for k in 0..<n {
            rows[k] = SIMD4(hs[k], hh[k], hl[k], ls[k])
            rows[n + k] = SIMD4(ss[k], 0, 0, 0)
        }
        table = rows
        luma = gamut.lumaRow
    }

    /// n samples at x = k/n of a curve that wraps around (hue): the points are repeated one period to each side.
    static func periodic(_ pts: [CurvePoint], _ n: Int) -> [Float] {
        let p = CurveMath.normalized(pts)
        let ext = p.map { CurvePoint($0.x / 3, $0.y) } + p.map { CurvePoint(($0.x + 1) / 3, $0.y) }
            + p.map { CurvePoint(($0.x + 2) / 3, $0.y) }
        return (0..<n).map { CurveMath.evaluate(ext, (Float($0) / Float(n) + 1) / 3) }
    }

    @inline(__always) func hueSample(_ column: Int, _ h: Float) -> Float {
        let n = Self.count
        let p = h * Float(n)
        let i = min(Int(p), n - 1)
        let f = p - Float(i)
        let a = table[i][column], b = table[(i + 1) % n][column]
        return a + (b - a) * f
    }

    @inline(__always) func linearSample(_ row0: Int, _ column: Int, _ x: Float) -> Float {
        let n = Self.count
        let p = min(max(x, 0), 1) * Float(n - 1)
        let i = min(Int(p), n - 2)
        let f = p - Float(i)
        let a = table[row0 + i][column], b = table[row0 + i + 1][column]
        return a + (b - a) * f
    }

    public func apply(_ c: SIMD3<Float>, pre: Bool) -> SIMD3<Float> {
        var t = pre ? TransferFunctions.bt709OETF(c) : c
        let mx = max(t.x, max(t.y, t.z)), mn = min(t.x, min(t.y, t.z))
        let d = mx - mn
        var hue: Float = 0
        if d > 1e-6 {
            var h: Float
            if mx == t.x { h = (t.y - t.z) / d } else if mx == t.y { h = (t.z - t.x) / d + 2 } else { h = (t.x - t.y) / d + 4 }
            h /= 6
            hue = h - floorf(h)
        }
        let w = ToneMath.smooth(0.005, 0.05, d)
        let sv = mx > 1e-4 ? min(max(d / mx, 0), 1) : 0
        let y0 = simd_dot(luma, t)
        let vs = hueSample(0, hue), vh = hueSample(1, hue), vl = hueSample(2, hue)
        let ls = linearSample(0, 3, y0), ss = linearSample(Self.count, 0, sv)
        // Hue: rotate the chroma about the grey axis (Rodrigues, axis (1,1,1)/sqrt(3)).
        let theta = (vh - 0.5) * 2 * Self.maxHueShift * w
        if theta != 0 {
            let m = (t.x + t.y + t.z) / 3
            let dv = t - SIMD3(repeating: m)
            let cr = SIMD3(dv.z - dv.y, dv.x - dv.z, dv.y - dv.x) * 0.57735027   // n x dv
            t = SIMD3(repeating: m) + dv * cosf(theta) + cr * sinf(theta)
        }
        let s = (1 + (2 * vs - 1) * w) * (2 * ls) * (2 * ss)
        if s != 1 {
            let y = simd_dot(luma, t)
            t = SIMD3(repeating: y) + (t - SIMD3(repeating: y)) * max(s, 0)
        }
        let g = exp2f((vl - 0.5) * 2 * w)
        if g != 1 { t *= g }
        return pre ? TransferFunctions.bt709InverseOETF(t) : t
    }
}

// MARK: Curves

/// Monotone cubic (Fritsch-Carlson) through control points, sampled into a table (master composed with each channel).
public struct CurveTable: Sendable, Equatable {
    public static let count = 64
    public let table: [SIMD3<Float>]
    public let isIdentity: Bool

    public init(_ curves: RGBCurves) {
        let master = CurveMath.sample(curves.master, Self.count)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(Self.count)
        for m in master {
            out.append(SIMD3(CurveMath.evaluate(curves.red, m), CurveMath.evaluate(curves.green, m), CurveMath.evaluate(curves.blue, m)))
        }
        table = out
        isIdentity = curves.isNeutral
    }

    public func apply(_ c: SIMD3<Float>, pre: Bool) -> SIMD3<Float> {
        let t = pre ? TransferFunctions.bt709OETF(c) : c
        var o = t
        for ch in 0..<3 {
            let x = min(max(t[ch], 0), 1)
            let p = x * Float(Self.count - 1)
            let i = min(Int(p), Self.count - 2)
            let f = p - Float(i)
            let v = table[i][ch] + (table[i + 1][ch] - table[i][ch]) * f
            o[ch] = v + (t[ch] - x)
        }
        return pre ? TransferFunctions.bt709InverseOETF(o) : o
    }
}

public enum CurveMath {
    /// Sorted, deduplicated control points clamped to 0…1; fewer than 2 points = the diagonal.
    static func normalized(_ pts: [CurvePoint]) -> [CurvePoint] {
        var p = pts.map { CurvePoint(min(max($0.x, 0), 1), min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for q in p { if let l = out.last, q.x - l.x < 1e-4 { out[out.count - 1] = q } else { out.append(q) } }
        p = out
        return p.count < 2 ? RGBCurves.diagonal : p
    }

    /// Monotone cubic Hermite value at `x` (flat beyond the end points).
    public static func evaluate(_ points: [CurvePoint], _ x: Float) -> Float {
        let p = normalized(points)
        let n = p.count
        if x <= p[0].x { return p[0].y }
        if x >= p[n - 1].x { return p[n - 1].y }
        var d = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x) }
        var m = [Float](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let k = 3 / sqrtf(s); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x
        let t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let v = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return min(max(v, 0), 1)
    }

    static func sample(_ points: [CurvePoint], _ count: Int) -> [Float] {
        (0..<count).map { evaluate(points, Float($0) / Float(count - 1)) }
    }
}
