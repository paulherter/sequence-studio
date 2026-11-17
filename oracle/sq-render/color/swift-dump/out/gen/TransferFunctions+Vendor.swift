import Foundation
#if canImport(simd)
import simd
#endif

// Vendor log curves for the input color spaces added with the "SQ Wide" work (docs/research/color/C-resolve-color-and-nodes.md).
// Every constant is a published vendor constant; the principles of the research note were followed, no vendor code was
// copied. Each curve has a round-trip test and an 18 % gray reference code value (VendorLogCurvesTests). Constants were
// cross-checked against colour-science (BSD-3-Clause, docs/THIRD_PARTY.md) and the vendor documents it cites.
// "Legal" wrappers apply to 10-bit camera codes (the compositor delivers range-expanded values, as for Sony/Canon);
// curves defined on floating-point signals (Log3G10, ACEScct, SQ Intermediate) take the value directly like Apple Log.

extension TransferFunctions {
    // MARK: SQ Intermediate (our own name; the published DaVinci Intermediate constants)

    static let sqLogA: Float = 0.0075, sqLogB: Float = 7.0, sqLogC: Float = 0.07329248, sqLogM: Float = 10.44426855
    static let sqLogLinCut: Float = 0.00262409, sqLogLogCut: Float = 0.02740668

    /// SQ Intermediate decode (encoded -> scene linear, 18 % gray = 0.18 encodes to ≈ 0.336). The linear toe is
    /// unbounded, so negative values survive.
    public static func sqLogDecode(_ y: Float) -> Float {
        y > sqLogLogCut ? powf(2, y / sqLogC - sqLogB) - sqLogA : y / sqLogM
    }
    /// SQ Intermediate encode.
    public static func sqLogEncode(_ x: Float) -> Float {
        x > sqLogLinCut ? (log2f(x + sqLogA) + sqLogB) * sqLogC : x * sqLogM
    }

    // MARK: ARRI LogC3, EI 800 (ARRI "LogC Curve - Usage in Cameras and Processing")

    static let logC3Cut: Float = 0.010591, logC3A: Float = 5.555556, logC3B: Float = 0.052272, logC3C: Float = 0.247190
    static let logC3D: Float = 0.385537, logC3E: Float = 5.367655, logC3F: Float = 0.092809

    /// LogC3 EI 800 decode. `x` = CV / 1023 (18 % gray = 0.391007).
    public static func logC3Decode(_ x: Float) -> Float {
        x > logC3E * logC3Cut + logC3F ? (powf(10, (x - logC3D) / logC3C) - logC3B) / logC3A : (x - logC3F) / logC3E
    }
    public static func logC3Encode(_ y: Float) -> Float {
        y > logC3Cut ? logC3C * log10f(logC3A * y + logC3B) + logC3D : logC3E * y + logC3F
    }

    // MARK: ARRI LogC4 (ARRI "LogC4 Logarithmic Color Space Specification")

    static let logC4A: Double = (262144 - 16) / 117.45
    static let logC4B: Double = (1023 - 95) / 1023
    static let logC4C: Double = 95.0 / 1023
    static let logC4S: Double = (7 * log(2.0) * pow(2, 7 - 14 * logC4C / logC4B)) / (logC4A * logC4B)
    static let logC4T: Double = (pow(2, 14 * (-logC4C / logC4B) + 6) - 64) / logC4A

    /// LogC4 decode. `x` = signal 0…1 (18 % gray = 0.278396). Below signal 0 the curve continues linearly.
    public static func logC4Decode(_ x: Float) -> Float {
        let v = Double(x)
        if v >= 0 { return Float((pow(2, 14 * (v - logC4C) / logC4B + 6) - 64) / logC4A) }
        return Float(v * logC4S + logC4T)
    }
    public static func logC4Encode(_ y: Float) -> Float {
        let v = Double(y)
        if v >= logC4T { return Float((log2(logC4A * v + 64) - 6) / 14 * logC4B + logC4C) }
        return Float((v - logC4T) / logC4S)
    }

    // MARK: RED Log3G10 (RED "REDWideGamutRGB and Log3G10" white paper)

    static let log3G10A: Float = 0.224282, log3G10B: Float = 155.975327, log3G10C: Float = 0.01, log3G10G: Float = 15.1927

    /// Log3G10 decode (18 % gray = 1/3). Negative signals continue linearly (slope 15.1927).
    public static func log3G10Decode(_ y: Float) -> Float {
        y < 0 ? y / log3G10G - log3G10C : (powf(10, y / log3G10A) - 1) / log3G10B - log3G10C
    }
    public static func log3G10Encode(_ x: Float) -> Float {
        let s = x + log3G10C
        return s < 0 ? s * log3G10G : log3G10A * log10f(s * log3G10B + 1)
    }

    // MARK: Blackmagic Film Generation 5 ("Blackmagic Generation 5 Color Science", 2021)

    static let bmdA: Float = 0.08692876065491224, bmdB: Float = 0.005494072432257808, bmdC: Float = 0.5300133392291939
    static let bmdD: Float = 8.283605932402494, bmdE: Float = 0.09246575342465753, bmdLinCut: Float = 0.005
    static let bmdLogCut: Float = bmdD * bmdLinCut + bmdE

    /// Film Gen 5 decode (18 % gray = 0.383581).
    public static func bmdFilmGen5Decode(_ y: Float) -> Float {
        y < bmdLogCut ? (y - bmdE) / bmdD : expf((y - bmdC) / bmdA) - bmdB
    }
    public static func bmdFilmGen5Encode(_ x: Float) -> Float {
        x < bmdLinCut ? bmdD * x + bmdE : bmdA * logf(x + bmdB) + bmdC
    }

    // MARK: Nikon N-Log (Nikon "N-Log Specification Document")

    static let nLogCut: Float = 0.328

    /// N-Log decode. `x` = CV / 1023 (18 % gray = CV 363). Cube-root toe below linear 0.328, natural log above.
    public static func nLogDecode(_ x: Float) -> Float {
        let cv = x * 1023
        let split = 150 * logf(nLogCut) + 619      // the log branch at the cut; the cube root branch is within 0.5 CV of it
        if cv < split { return powf(cv / 650, 3) - 0.0075 }
        return expf((cv - 619) / 150)
    }
    public static func nLogEncode(_ y: Float) -> Float {
        if y < nLogCut { return 650 * cbrtf(max(y + 0.0075, 0)) / 1023 }
        return (150 * logf(y) + 619) / 1023
    }

    // MARK: Fujifilm F-Log2 (Fujifilm "F-Log2 Data Sheet")

    static let fLog2Cut1: Float = 0.000889, fLog2Cut2: Float = 0.100686685370811
    static let fLog2A: Float = 5.555556, fLog2B: Float = 0.064829, fLog2C: Float = 0.245281
    static let fLog2D: Float = 0.384316, fLog2E: Float = 8.799461, fLog2F: Float = 0.092864

    /// F-Log2 decode. `x` = CV / 1023 (18 % gray = 0.391; same shape as LogC3 with other constants).
    public static func fLog2Decode(_ x: Float) -> Float {
        x >= fLog2Cut2 ? (powf(10, (x - fLog2D) / fLog2C) - fLog2B) / fLog2A : (x - fLog2F) / fLog2E
    }
    public static func fLog2Encode(_ y: Float) -> Float {
        y >= fLog2Cut1 ? fLog2C * log10f(fLog2A * y + fLog2B) + fLog2D : fLog2E * y + fLog2F
    }

    // MARK: ACEScct (S-2016-001, AMPAS)

    static let acesCCTA: Float = 10.5402377416545, acesCCTB: Float = 0.0729055341958355
    static let acesCCTLinCut: Float = 0.0078125, acesCCTLogCut: Float = 0.155251141552511

    public static func acesCCTDecode(_ y: Float) -> Float {
        y <= acesCCTLogCut ? (y - acesCCTB) / acesCCTA : powf(2, y * 17.52 - 9.72)
    }
    public static func acesCCTEncode(_ x: Float) -> Float {
        x <= acesCCTLinCut ? acesCCTA * x + acesCCTB : (log2f(x) + 9.72) / 17.52
    }

    // MARK: Legal-range wrappers and SIMD3 forms

    public static func logC3DecodeLegal(_ v: Float) -> Float { logC3Decode(legalToCodeFraction(v)) }
    public static func logC3EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(logC3Encode(y)) }
    public static func logC4DecodeLegal(_ v: Float) -> Float { logC4Decode(legalToCodeFraction(v)) }
    public static func logC4EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(logC4Encode(y)) }
    public static func bmdFilmGen5DecodeLegal(_ v: Float) -> Float { bmdFilmGen5Decode(legalToCodeFraction(v)) }
    public static func bmdFilmGen5EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(bmdFilmGen5Encode(y)) }
    public static func nLogDecodeLegal(_ v: Float) -> Float { nLogDecode(legalToCodeFraction(v)) }
    public static func nLogEncodeLegal(_ y: Float) -> Float { codeFractionToLegal(nLogEncode(y)) }
    public static func fLog2DecodeLegal(_ v: Float) -> Float { fLog2Decode(legalToCodeFraction(v)) }
    public static func fLog2EncodeLegal(_ y: Float) -> Float { codeFractionToLegal(fLog2Encode(y)) }

    public static func logC3DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, logC3DecodeLegal) }
    public static func logC3EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, logC3EncodeLegal) }
    public static func logC4DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, logC4DecodeLegal) }
    public static func logC4EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, logC4EncodeLegal) }
    public static func log3G10Decode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, log3G10Decode) }
    public static func log3G10Encode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, log3G10Encode) }
    public static func bmdFilmGen5DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, bmdFilmGen5DecodeLegal) }
    public static func bmdFilmGen5EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, bmdFilmGen5EncodeLegal) }
    public static func nLogDecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, nLogDecodeLegal) }
    public static func nLogEncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, nLogEncodeLegal) }
    public static func fLog2DecodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, fLog2DecodeLegal) }
    public static func fLog2EncodeLegal(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, fLog2EncodeLegal) }
    public static func acesCCTDecode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, acesCCTDecode) }
    public static func acesCCTEncode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, acesCCTEncode) }
    public static func sqLogDecode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, sqLogDecode) }
    public static func sqLogEncode(_ v: SIMD3<Float>) -> SIMD3<Float> { map(v, sqLogEncode) }
}
