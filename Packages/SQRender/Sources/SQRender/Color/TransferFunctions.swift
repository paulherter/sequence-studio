import Foundation
import simd

/// Transfer functions (CPU reference for the later Metal shaders). Scalar forms plus SIMD3 wrappers.
public enum TransferFunctions {
    // MARK: S-Log3

    static let slog3CutEncoded: Float = 171.2102946929 / 1023
    static let slog3CutLinear: Float = 0.01125

    /// Sony S-Log3 decode. `x` = CV / 1023 (full-range code value fraction). Returns scene linear (18 % grey = 0.18).
    public static func slog3Decode(_ x: Float) -> Float {
        if x >= slog3CutEncoded {
            return powf(10, (x * 1023 - 420) / 261.5) * (0.18 + 0.01) - 0.01
        }
        return (x * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
    }

    /// Sony S-Log3 encode. Returns CV / 1023.
    public static func slog3Encode(_ y: Float) -> Float {
        if y >= slog3CutLinear {
            return (420 + log10f((y + 0.01) / (0.18 + 0.01)) * 261.5) / 1023
        }
        return (y * (171.2102946929 - 95) / 0.01125 + 95) / 1023
    }

    /// Legal-range (64…940 of 10 bit) range-expanded value `v` (0…1) -> full-range code fraction CV/1023.
    @inline(__always) public static func legalToCodeFraction(_ v: Float) -> Float { (v * 876 + 64) / 1023 }
    /// Inverse of `legalToCodeFraction`.
    @inline(__always) public static func codeFractionToLegal(_ x: Float) -> Float { (x * 1023 - 64) / 876 }

    /// Range-expanded S-Log3 (as delivered by the compositor) -> scene linear.
    public static func slog3DecodeLegal(_ v: Float) -> Float { slog3Decode(legalToCodeFraction(v)) }
    /// Scene linear -> range-expanded S-Log3.
    public static func slog3EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(slog3Encode(y)) }

    // MARK: HLG (BT.2100)

    static let hlgA: Float = 0.17883277
    static let hlgB: Float = 0.28466892  // 1 - 4a
    static let hlgC: Float = 0.55991073  // 0.5 - a ln(4a)

    /// BT.2100 system gamma for a 1000 nit display.
    static let hlgGamma: Float = 1.2
    /// BT.2100 luminance weights (BT.2020 primaries).
    static let hlgLuma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
    /// Normalisation so HLG reference white (signal 0.75, display 203/1000 ≈ 0.2027 after the OOTF) maps to 1.0. Derived, not hardcoded.
    public static let hlgScale: Float = {
        let e = hlgInverseOETF(0.75)
        return 1 / (e * powf(e, hlgGamma - 1))
    }()

    /// BT.2100 inverse OETF: signal 0…1 -> scene light 0…1 (unscaled).
    public static func hlgInverseOETF(_ e: Float) -> Float {
        let e = max(e, 0)
        if e <= 0.5 { return e * e / 3 }
        return (expf((e - hlgC) / hlgA) + hlgB) / 12
    }

    /// BT.2100 OETF: scene light 0…1 (unscaled) -> signal.
    public static func hlgOETF(_ s: Float) -> Float {
        let s = max(s, 0)
        if s <= 1.0 / 12 { return sqrtf(3 * s) }
        return hlgA * logf(12 * s - hlgB) + hlgC
    }

    /// HLG signal (BT.2020 R'G'B') -> display-referred linear, reference white = 1.0 (peak ≈ 4.93).
    /// BT.2100 inverse OETF per channel (scene E), then the luminance-based OOTF `Fd = Ys^(γ−1)·E`
    /// (γ = 1.2, Ys = 0.2627R + 0.6780G + 0.0593B of E), times `hlgScale`. Non-separable: needs all three channels.
    public static func hlgDecode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let e = SIMD3(hlgInverseOETF(v.x), hlgInverseOETF(v.y), hlgInverseOETF(v.z))
        let ys = simd_dot(hlgLuma, e)
        let gain = ys > 0 ? powf(ys, hlgGamma - 1) : 0
        return e * gain * hlgScale
    }

    /// Exact inverse of `hlgDecode`: undo the scale, `Ys = Yd^(1/γ)`, `E = Fd / Ys^(γ−1)`, then the OETF.
    public static func hlgEncode(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let fd = v / hlgScale
        let yd = simd_dot(hlgLuma, fd)
        guard yd > 0 else { return SIMD3(hlgOETF(0), hlgOETF(0), hlgOETF(0)) }
        let ys = powf(yd, 1 / hlgGamma)
        let e = fd / powf(ys, hlgGamma - 1)
        return SIMD3(hlgOETF(e.x), hlgOETF(e.y), hlgOETF(e.z))
    }

    // MARK: BT.709

    public static let bt709Alpha: Float = 1.09929682680944
    public static let bt709Beta: Float = 0.018053968510807

    public static func bt709OETF(_ l: Float) -> Float {
        if l < bt709Beta { return 4.5 * l }
        return bt709Alpha * powf(l, 0.45) - (bt709Alpha - 1)
    }

    public static func bt709InverseOETF(_ v: Float) -> Float {
        if v < 4.5 * bt709Beta { return v / 4.5 }
        return powf((v + bt709Alpha - 1) / bt709Alpha, 1 / 0.45)
    }

    // MARK: SIMD3 wrappers

    @inline(__always) static func map(_ v: SIMD3<Float>, _ f: (Float) -> Float) -> SIMD3<Float> {
        SIMD3<Float>(f(v.x), f(v.y), f(v.z))
    }
    public static func slog3DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, slog3DecodeLegal) }
    public static func slog3EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, slog3EncodeLegal) }
    public static func bt709OETF(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, bt709OETF) }
    public static func bt709InverseOETF(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, bt709InverseOETF) }
}
