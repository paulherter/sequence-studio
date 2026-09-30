import CoreVideo
import Metal
import SSCore
import simd

public enum PixelLayout: Sendable, Equatable { case biplanarYCbCr, bgra8 }

/// How the compositor reads one CVPixelBuffer format. All YCbCr formats are bi-planar (Y + interleaved CbCr);
/// chroma subsampling (420/422/444) needs no special casing because planes are sampled with normalized coordinates.
public struct PixelFormatInfo: Sendable, Equatable {
    public var layout: PixelLayout
    public var bitDepth: Int
    public var fullRange: Bool
    public var yFormat: MTLPixelFormat
    public var cbcrFormat: MTLPixelFormat
    /// Apple lossless-compressed variant (`&8v0` ...): sampled through the same plane formats; Metal decompresses.
    public var compressed: Bool
}

public enum MatrixCoefficients: Sendable, Equatable { case bt601, bt709, bt2020 }

public enum PixelFormats {
    public static func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    /// Supported formats. 10-bit planes are MSB-aligned in 16 bit (r16Unorm / rg16Unorm).
    public static func info(for f: OSType) -> PixelFormatInfo? {
        func bi(_ bits: Int, _ full: Bool, _ c: Bool = false) -> PixelFormatInfo {
            PixelFormatInfo(layout: .biplanarYCbCr, bitDepth: bits, fullRange: full,
                            yFormat: bits == 8 ? .r8Unorm : .r16Unorm,
                            cbcrFormat: bits == 8 ? .rg8Unorm : .rg16Unorm, compressed: c)
        }
        switch f {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return bi(8, false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return bi(8, true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,   // x420
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,   // x422
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return bi(10, false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: return bi(10, true)
        case kCVPixelFormatType_32BGRA:
            return PixelFormatInfo(layout: .bgra8, bitDepth: 8, fullRange: true, yFormat: .bgra8Unorm,
                                   cbcrFormat: .rg8Unorm, compressed: false)
        case fourCC("&8v0"): return bi(8, false, true)
        case fourCC("&8f0"): return bi(8, true, true)
        default: return nil
        }
    }

    /// Format to request from VideoToolbox (destination attributes) when `f` cannot be sampled (packed 10-bit
    /// lossless variants): the plain bi-planar equivalent, costing memory bandwidth (ARCHITECTURE §5 risk).
    public static func uncompressedEquivalent(of f: OSType) -> OSType? {
        switch f {
        case fourCC("&8v0"): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case fourCC("&8f0"): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case fourCC("&xv0"): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case fourCC("&xf0"): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case fourCC("&xv2"), fourCC("&xf2"): return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        default: return nil
        }
    }

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

    /// Y'CbCr (Y in 0...1, Cb/Cr centred on 0) -> R'G'B', as columns for `M * (Y, Cb, Cr)`.
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

    /// (yScale, yBias, cScale, cBias): `Y' = sampledY * yScale + yBias`, `Cb' = sampledCb * cScale + cBias`.
    public static func rangeParams(_ i: PixelFormatInfo) -> SIMD4<Float> {
        let s = Float(1 << (i.bitDepth - 8))
        let maxCode = Float((1 << i.bitDepth) - 1)
        // Sampled unorm -> integer code: 8-bit = v*255, 10-bit MSB-aligned in 16 bit = v*65535/64.
        let k: Float = i.bitDepth == 8 ? 255 : 65535 / 64
        if i.fullRange {
            return SIMD4(k / maxCode, 0, k / maxCode, -(128 * s) / maxCode)
        }
        return SIMD4(k / (219 * s), -(16 * s) / (219 * s), k / (224 * s), -(128 * s) / (224 * s))
    }
}
