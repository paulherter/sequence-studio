import Foundation

/// Basic Correction tone maths of the Lumetri-matched model (`BasicToneModel.lumetri`), per channel on the Rec.709
/// signal `x` (0...1 = 0...100 IRE; values outside are continued so the curve never folds). Exposure works on linear
/// light. Amounts are the sliders / 100 (-1...1), exposure in stops. Evidence and what is inferred:
/// docs/research/COLOR-CORRECTION-MATH.md. SQRender (`PreparedBasic`, `ColorShaderSource`) uses the same constants.
public enum BasicToneCurves {
    // Strengths (inferred; calibrate against the Premiere reference set, docs/research/COLOR-REFERENCE-HOWTO.md).
    /// Contrast pivot on the Rec.709 signal (Premiere: 50 IRE).
    public static let contrastPivot: Float = 0.5
    /// Contrast slope at the pivot is `1 + k`: k = amount x this for positive, x `contrastDown` for negative.
    public static let contrastUp: Float = 1.0, contrastDown: Float = 0.5
    /// Largest move of the Highlights / Shadows bump at +-100 (signal units, 0.14 = 14 IRE).
    public static let highlightsReach: Float = 0.14, shadowsReach: Float = 0.14
    /// Whites gain at +-100, in stops.
    public static let whitesStops: Float = 0.35
    /// Blacks lift of the black point at +100 (0.2 = 20 IRE); the hinge falls off as (1 - x)^2.
    public static let blacksReach: Float = 0.2
    /// Exposure up: linear light below this knee is a plain gain, above it a shoulder rolls into white.
    public static let exposureKnee: Float = 0.18

    /// Exposure on linear light `l`: down = gain; up = gain below the knee, then a rational shoulder that maps linear 1
    /// to exactly 1 (C1 at the knee). Source superwhites (linear > 1) continue with slope 1 from there:
    /// `1 + g (l - 1)`, so they never come out darker than the input and rise with ev.
    public static func exposure(_ l: Float, _ ev: Float) -> Float {
        guard ev != 0 else { return l }
        let g = exp2f(ev)
        let m = l * g
        guard ev > 0, m > exposureKnee else { return m }
        let s = exposureKnee, w = g
        let a = (w - 1) / (1 - s)
        let u = (m - s) / (w - s)
        if u <= 1 { return s + (1 - s) * u * (1 + a) / (1 + a * u) }
        return 1 + (m - w)
    }

    /// Schlick bias: 0 -> 0, 1 -> 1, slope 1/(1+k) at 0 and 1+k at 1.
    @inline(__always) static func bias(_ u: Float, _ k: Float) -> Float { u / (k * (1 - u) + 1) }

    /// S-curve about the pivot: pivot, 0 and 1 stay; positive steepens the middle, negative flattens it.
    public static func contrast(_ x: Float, _ c: Float) -> Float {
        guard c != 0 else { return x }
        let k = c >= 0 ? c * contrastUp : c * contrastDown
        let p = contrastPivot
        if x < 0 { return x / (1 + k) }
        if x > 1 { return 1 + (x - 1) / (1 + k) }
        if x <= p { return p * bias(x / p, k) }
        return 1 - (1 - p) * bias((1 - x) / (1 - p), k)
    }

    /// Bump on the upper tones (peak at 2/3), black and white fixed; +100 compresses the very top.
    public static func highlights(_ x: Float, _ h: Float) -> Float {
        guard h != 0, x > 0, x < 1 else { return x }
        return x + highlightsReach * h * 6.75 * x * x * (1 - x)
    }

    /// Bump on the lower tones (peak at 1/3), black and white fixed.
    public static func shadows(_ x: Float, _ s: Float) -> Float {
        guard s != 0, x > 0, x < 1 else { return x }
        return x + shadowsReach * s * 6.75 * x * (1 - x) * (1 - x)
    }

    /// Gain about black.
    public static func whites(_ x: Float, _ w: Float) -> Float {
        w == 0 ? x : x * exp2f(whitesStops * w)
    }

    /// Black point move hinged low: `x + d (1 - x)^2` with d = 0.2 x amount; white and everything near it stay. Below 0
    /// it continues with its slope at 0; negative amounts push the darkest tones below 0 (the display clips them).
    public static func blacks(_ x: Float, _ b: Float) -> Float {
        guard b != 0, x < 1 else { return x }
        let d = blacksReach * b
        if x < 0 { return d + x * (1 - 2 * d) }
        return x + d * (1 - x) * (1 - x)
    }

    // BT.709 OETF (same constants as SQRender `TransferFunctions`).
    static let alpha: Float = 1.09929682680944, beta: Float = 0.018053968510807
    static func oetf(_ l: Float) -> Float { l < beta ? 4.5 * l : alpha * powf(l, 0.45) - (alpha - 1) }
    static func inverseOETF(_ v: Float) -> Float { v < 4.5 * beta ? v / 4.5 : powf((v + alpha - 1) / alpha, 1 / 0.45) }

    /// The tone part after Exposure (Contrast, Highlights, Shadows, Whites, Blacks) on one channel of the signal.
    public static func toneAfterExposure(_ x: Float, _ b: BasicCorrection) -> Float {
        func n(_ v: Float) -> Float { min(max(v, -100), 100) / 100 }
        var t = contrast(x, n(b.contrast))
        t = highlights(t, n(b.highlights))
        t = shadows(t, n(b.shadows))
        t = whites(t, n(b.whites))
        return blacks(t, n(b.blacks))
    }

    /// A gray of display value `y` through the whole tone part (Exposure on its linear light, then the curves).
    public static func tone(_ y: Float, _ b: BasicCorrection) -> Float {
        let ev = min(max(b.exposure, -5), 5)
        let t = ev == 0 ? y : oetf(exposure(inverseOETF(y), ev))
        return toneAfterExposure(t, b)
    }
}
