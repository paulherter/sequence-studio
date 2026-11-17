import Foundation
#if canImport(simd)
import simd
#endif

/// Transfer functions (CPU reference for the later Metal shaders). Scalar forms plus SIMD3 wrappers.
public enum TransferFunctions {
    // MARK: S-Log3

    static let slog3CutEncoded: Float = 171.2102946929 / 1023
    static let slog3CutLinear: Float = 0.01125

    /// Sony S-Log3 decode. `x` = CV / 1023 (full-range code value fraction). Returns scene linear (18 % gray = 0.18).
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
    /// Normalization so HLG reference white (signal 0.75, display 203/1000 ≈ 0.2027 after the OOTF) maps to 1.0. Derived, not hardcoded.
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

    // MARK: Panasonic V-Log (V-Log/V-Gamut reference manual)

    static let vlogCut1: Float = 0.01, vlogCut2: Float = 0.181
    static let vlogB: Float = 0.00873, vlogC: Float = 0.241514, vlogD: Float = 0.598206

    /// V-Log decode. `x` = CV / 1023 (full-range code fraction, 18 % gray = 433). Returns scene linear.
    public static func vlogDecode(_ x: Float) -> Float {
        x < vlogCut2 ? (x - 0.125) / 5.6 : powf(10, (x - vlogD) / vlogC) - vlogB
    }
    /// V-Log encode. Returns CV / 1023.
    public static func vlogEncode(_ y: Float) -> Float {
        y < vlogCut1 ? 5.6 * y + 0.125 : vlogC * log10f(y + vlogB) + vlogD
    }
    public static func vlogDecodeLegal(_ v: Float) -> Float { vlogDecode(legalToCodeFraction(v)) }
    public static func vlogEncodeLegal(_ y: Float) -> Float { codeFractionToLegal(vlogEncode(y)) }

    // MARK: DJI D-Log (D-Log/D-Gamut white paper)

    /// D-Log decode. `x` = CV / 1023 (full-range code fraction, as Sony/Panasonic). Returns scene linear.
    public static func dlogDecode(_ x: Float) -> Float {
        x <= 0.14 ? (x - 0.0929) / 6.025 : (powf(10, 3.89616 * x - 2.27752) - 0.0108) / 0.9892
    }
    /// D-Log encode. Returns CV / 1023.
    public static func dlogEncode(_ y: Float) -> Float {
        y <= 0.0078 ? 6.025 * y + 0.0929 : log10f(y * 0.9892 + 0.0108) * 0.256663 + 0.584555
    }
    public static func dlogDecodeLegal(_ v: Float) -> Float { dlogDecode(legalToCodeFraction(v)) }
    public static func dlogEncodeLegal(_ y: Float) -> Float { codeFractionToLegal(dlogEncode(y)) }

    // MARK: Canon Log, Canon Log 2, Canon Log 3
    // Canon white paper "Canon Log Gamma Curves: Description of the Canon Log, Canon Log 2 and Canon Log 3 Gamma
    // Curves" (Canon Inc., 2020), the code-value form: the encoded value is CV / 1023 of the 10-bit signal (0 % black
    // sits at CV 128 for Canon Log and Canon Log 3, CV 95 for Canon Log 2) and the linear input is the scene
    // reflection divided by 0.9 (90 % white = 1.0). All three curves continue below black (mirrored log, or the
    // linear toe of Canon Log 3). Constants cross-checked against colour-science (BSD-3-Clause, docs/THIRD_PARTY.md).

    /// Reflection that Canon's formulas call 1.0.
    static let canonWhite: Float = 0.9
    static let canonLogA: Float = 0.45310179, canonLogK: Float = 10.1596, canonLogC: Float = 0.12512248
    static let canonLog2A: Float = 0.24136077, canonLog2K: Float = 87.09937546, canonLog2C: Float = 0.092864125
    static let canonLog3A: Float = 0.36726845, canonLog3K: Float = 14.98325
    static let canonLog3CNeg: Float = 0.12783901, canonLog3CPos: Float = 0.12240537
    static let canonLog3Slope: Float = 1.9754798, canonLog3Offset: Float = 0.12512219
    /// Encoded ends of the Canon Log 3 linear toe (linear -0.014 … 0.014 in Canon's scale).
    static let canonLog3CutLow: Float = 0.097465473, canonLog3CutHigh: Float = 0.15277891, canonLog3CutLinear: Float = 0.014

    /// Canon Log and Canon Log 2 share one shape: `a * log10(k * x + 1) + c`, point-mirrored at black (x = 0, c).
    @inline(__always) static func canonMirroredDecode(_ x: Float, a: Float, k: Float, c: Float) -> Float {
        (x < c ? -(powf(10, (c - x) / a) - 1) / k : (powf(10, (x - c) / a) - 1) / k) * canonWhite
    }
    @inline(__always) static func canonMirroredEncode(_ y: Float, a: Float, k: Float, c: Float) -> Float {
        let l = y / canonWhite
        return l < 0 ? -(a * log10f(-l * k + 1) - c) : a * log10f(l * k + 1) + c
    }

    /// Canon Log decode. `x` = CV / 1023 (18 % gray = 351, 90 % white = 614). Returns scene linear.
    public static func canonLogDecode(_ x: Float) -> Float { canonMirroredDecode(x, a: canonLogA, k: canonLogK, c: canonLogC) }
    /// Canon Log encode. Returns CV / 1023.
    public static func canonLogEncode(_ y: Float) -> Float { canonMirroredEncode(y, a: canonLogA, k: canonLogK, c: canonLogC) }
    /// Canon Log 2 decode. `x` = CV / 1023 (18 % gray = 407, 90 % white = 575). Returns scene linear.
    public static func canonLog2Decode(_ x: Float) -> Float { canonMirroredDecode(x, a: canonLog2A, k: canonLog2K, c: canonLog2C) }
    /// Canon Log 2 encode. Returns CV / 1023.
    public static func canonLog2Encode(_ y: Float) -> Float { canonMirroredEncode(y, a: canonLog2A, k: canonLog2K, c: canonLog2C) }
    /// Canon Log 3 decode. `x` = CV / 1023 (18 % gray = 351, 90 % white = 577). Returns scene linear.
    public static func canonLog3Decode(_ x: Float) -> Float {
        let l: Float
        if x < canonLog3CutLow { l = -(powf(10, (canonLog3CNeg - x) / canonLog3A) - 1) / canonLog3K }
        else if x <= canonLog3CutHigh { l = (x - canonLog3Offset) / canonLog3Slope }
        else { l = (powf(10, (x - canonLog3CPos) / canonLog3A) - 1) / canonLog3K }
        return l * canonWhite
    }
    /// Canon Log 3 encode. Returns CV / 1023.
    public static func canonLog3Encode(_ y: Float) -> Float {
        let l = y / canonWhite
        if l < -canonLog3CutLinear { return -canonLog3A * log10f(-l * canonLog3K + 1) + canonLog3CNeg }
        if l <= canonLog3CutLinear { return canonLog3Slope * l + canonLog3Offset }
        return canonLog3A * log10f(l * canonLog3K + 1) + canonLog3CPos
    }
    public static func canonLogDecodeLegal(_ v: Float) -> Float { canonLogDecode(legalToCodeFraction(v)) }
    public static func canonLogEncodeLegal(_ y: Float) -> Float { codeFractionToLegal(canonLogEncode(y)) }
    public static func canonLog2DecodeLegal(_ v: Float) -> Float { canonLog2Decode(legalToCodeFraction(v)) }
    public static func canonLog2EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(canonLog2Encode(y)) }
    public static func canonLog3DecodeLegal(_ v: Float) -> Float { canonLog3Decode(legalToCodeFraction(v)) }
    public static func canonLog3EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(canonLog3Encode(y)) }

    // MARK: Apple Log (Apple Log profile white paper)

    static let appleR0: Float = -0.05641088, appleRt: Float = 0.01, appleC: Float = 47.28711236
    static let appleBeta: Float = 0.00964052, appleGamma: Float = 0.08550479, appleDelta: Float = 0.69336945
    /// Encoded value at `appleRt` (where the quadratic toe meets the log part).
    static let applePt: Float = appleC * (appleRt - appleR0) * (appleRt - appleR0)

    /// Apple Log decode. `p` = the normalized signal; the file stores it video range, so the range-expanded value is
    /// used directly. Returns scene linear (18 % gray 0.18 is encoded as ≈ 0.488).
    public static func appleLogDecode(_ p: Float) -> Float {
        if p >= applePt { return powf(2, (p - appleDelta) / appleGamma) - appleBeta }
        if p >= 0 { return sqrtf(p / appleC) + appleR0 }
        return appleR0
    }
    /// Apple Log encode.
    public static func appleLogEncode(_ x: Float) -> Float {
        if x >= appleRt { return appleGamma * log2f(x + appleBeta) + appleDelta }
        if x >= appleR0 { return appleC * (x - appleR0) * (x - appleR0) }
        return 0
    }

    // MARK: PQ (SMPTE ST 2084)

    static let pqM1: Float = 2610.0 / 16384, pqM2: Float = 2523.0 / 4096 * 128
    static let pqC1: Float = 3424.0 / 4096, pqC2: Float = 2413.0 / 4096 * 32, pqC3: Float = 2392.0 / 4096 * 32
    /// Nits that map to 1.0 (BT.2408 HDR reference white, same normalization as HLG).
    public static let pqReferenceWhite: Float = 203

    /// PQ signal (range-expanded) -> display linear, reference white (203 nits) = 1.0, peak 10000 nits ≈ 49.3.
    public static func pqDecode(_ e: Float) -> Float {
        let p = powf(max(e, 0), 1 / pqM2)
        let y = powf(max(p - pqC1, 0) / (pqC2 - pqC3 * p), 1 / pqM1)
        return y * 10000 / pqReferenceWhite
    }
    /// Display linear (1.0 = 203 nits) -> PQ signal.
    public static func pqEncode(_ l: Float) -> Float {
        let y = powf(max(l, 0) * pqReferenceWhite / 10000, pqM1)
        return powf((pqC1 + pqC2 * y) / (1 + pqC3 * y), pqM2)
    }

    // MARK: SIMD3 wrappers

    @inline(__always) static func map(_ v: SIMD3<Float>, _ f: (Float) -> Float) -> SIMD3<Float> {
        SIMD3<Float>(f(v.x), f(v.y), f(v.z))
    }
    public static func slog3DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, slog3DecodeLegal) }
    public static func slog3EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, slog3EncodeLegal) }
    public static func vlogDecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, vlogDecodeLegal) }
    public static func vlogEncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, vlogEncodeLegal) }
    public static func dlogDecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, dlogDecodeLegal) }
    public static func dlogEncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, dlogEncodeLegal) }
    public static func canonLogDecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, canonLogDecodeLegal) }
    public static func canonLogEncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, canonLogEncodeLegal) }
    public static func canonLog2DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, canonLog2DecodeLegal) }
    public static func canonLog2EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, canonLog2EncodeLegal) }
    public static func canonLog3DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, canonLog3DecodeLegal) }
    public static func canonLog3EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, canonLog3EncodeLegal) }
    public static func appleLogDecode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, appleLogDecode) }
    public static func appleLogEncode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, appleLogEncode) }
    public static func pqDecode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, pqDecode) }
    public static func pqEncode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, pqEncode) }
    public static func bt709OETF(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, bt709OETF) }
    public static func bt709InverseOETF(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, bt709InverseOETF) }
}
