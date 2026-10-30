#if canImport(simd)
import simd
#endif

// The portable part of `PixelFormats` (the Core Video format table stays in PixelFormats.swift): matrix tags, the
// Y'CbCr -> R'G'B' matrix and the range parameters the layer draw reads.

public enum MatrixCoefficients: Sendable, Equatable { case bt601, bt709, bt2020 }

public enum PixelFormats {
    /// Accepts AVFoundation names (`ITU_R_709_2`, `ITU_R_601_4`, `SMPTE_C`, `ITU_R_2020`), ffprobe names
    /// (`bt709`, `smpte170m`, `bt470bg`, `bt2020nc`) and ISO numbers. Untagged / unknown = 709.
    public static func matrix(tag: String?) -> MatrixCoefficients {
        guard let t = tag?.lowercased(), !t.isEmpty else { return .bt709 }
        if t.contains("2020") || t == "9" || t == "10" { return .bt2020 }
        if t.contains("601") || t.contains("470") || t.contains("170") || t.contains("smpte_c") || t == "5" || t == "6" {
            return .bt601
        }
        return .bt709
    }

    /// Y'CbCr (Y in 0...1, Cb/Cr centered on 0) -> R'G'B', as columns for `M * (Y, Cb, Cr)`.
    public static func ycbcrToRGB(_ m: MatrixCoefficients) -> simd_float3x3 {
        let kr: Float, kb: Float
        switch m {
        case .bt601: kr = 0.299; kb = 0.114
        case .bt709: kr = 0.2126; kb = 0.0722
        case .bt2020: kr = 0.2627; kb = 0.0593
        }
        let kg = 1 - kr - kb
        return simd_float3x3(columns: (SIMD3(1, 1, 1),
                                       SIMD3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)),
                                       SIMD3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)))
    }

    /// Sampled unorm planes of `bitDepth` (10 bit: MSB-aligned in 16) in full or video range.
    public static func rangeParams(bitDepth: Int, fullRange: Bool) -> SIMD4<Float> {
        let s = Float(1 << (bitDepth - 8))
        let maxCode = Float((1 << bitDepth) - 1)
        // Sampled unorm -> integer code: 8-bit = v*255, 10-bit MSB-aligned in 16 bit = v*65535/64, 16-bit = v*65535.
        let k: Float = bitDepth == 8 ? 255 : bitDepth == 16 ? 65535 : 65535 / 64
        if fullRange {
            return SIMD4(k / maxCode, 0, k / maxCode, -(128 * s) / maxCode)
        }
        return SIMD4(k / (219 * s), -(16 * s) / (219 * s), k / (224 * s), -(128 * s) / (224 * s))
    }
}
