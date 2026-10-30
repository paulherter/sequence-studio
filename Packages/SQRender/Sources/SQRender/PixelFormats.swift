#if canImport(Metal)
import CoreVideo
import Metal
import SQCore
import simd

/// `ayuv16`: packed 4:4:4:4 'y416' (A, Y', Cb, Cr, 16 bit little-endian each; video-range Y'CbCr, full-range alpha), the
/// decode format of transparent video (ProRes 4444 / HEVC with alpha), read as one rgba16Unorm texture (r = A).
public enum PixelLayout: Sendable, Equatable { case biplanarYCbCr, bgra8, ayuv16 }

/// How the compositor reads one CVPixelBuffer format. Opaque YCbCr formats are bi-planar (Y + interleaved CbCr);
/// chroma subsampling (420/422/444) needs no special casing because planes are sampled with normalized coordinates.
/// Single-plane formats (`bgra8`, `ayuv16`) use `yFormat` only.
public struct PixelFormatInfo: Sendable, Equatable {
    public var layout: PixelLayout
    public var bitDepth: Int
    public var fullRange: Bool
    public var yFormat: MTLPixelFormat
    public var cbcrFormat: MTLPixelFormat
    /// Apple lossless-compressed variant (`&8v0` ...): sampled through the same plane formats; Metal decompresses.
    public var compressed: Bool

    /// One texture (plane 0) holds the whole picture.
    public var singlePlane: Bool { layout != .biplanarYCbCr }
    /// The picture can carry alpha (straight or premultiplied: `kCVImageBufferAlphaChannelModeKey` on the buffer).
    public var hasAlpha: Bool { layout != .biplanarYCbCr }
}

extension PixelFormats {
    public static func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    /// Supported formats. 10-bit planes are MSB-aligned in 16 bit (r16Unorm / rg16Unorm).
    public static func info(for f: OSType) -> PixelFormatInfo? {
        func bi(_ bits: Int, _ full: Bool, _ c: Bool = false) -> PixelFormatInfo {
            PixelFormatInfo(layout: .biplanarYCbCr, bitDepth: bits, fullRange: full,
                            yFormat: bits == 8 ? .r8Unorm : .r16Unorm,
                            cbcrFormat: bits == 8 ? .rg8Unorm : .rg16Unorm, compressed: c)
        }
        switch f {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: return bi(8, false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: return bi(8, true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,   // x420
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,   // x422
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return bi(10, false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: return bi(10, true)
        case kCVPixelFormatType_32BGRA:
            return PixelFormatInfo(layout: .bgra8, bitDepth: 8, fullRange: true, yFormat: .bgra8Unorm,
                                   cbcrFormat: .rg8Unorm, compressed: false)
        case kCVPixelFormatType_4444AYpCbCr16:
            return PixelFormatInfo(layout: .ayuv16, bitDepth: 16, fullRange: false, yFormat: .rgba16Unorm,
                                   cbcrFormat: .rgba16Unorm, compressed: false)
        case fourCC("&8v0"): return bi(8, false, true)
        case fourCC("&8f0"): return bi(8, true, true)
        default: return nil
        }
    }

    /// Plain bi-planar equivalent of a lossless variant that cannot be sampled (packed 10-bit), same range
    /// (`&xv*` = video, `&xf*` = full; CVPixelBuffer.h). The decoder requests the native uncompressed format up front
    /// (`SQMedia.DecodePixelFormat`), so this is for diagnostics / other producers.
    public static func uncompressedEquivalent(of f: OSType) -> OSType? {
        switch f {
        case fourCC("&8v0"): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case fourCC("&8f0"): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case fourCC("&xv0"): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case fourCC("&xf0"): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case fourCC("&xv2"): return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case fourCC("&xf2"): return kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        default: return nil
        }
    }

    /// (yScale, yBias, cScale, cBias): `Y' = sampledY * yScale + yBias`, `Cb' = sampledCb * cScale + cBias`.
    public static func rangeParams(_ i: PixelFormatInfo) -> SIMD4<Float> { rangeParams(bitDepth: i.bitDepth, fullRange: i.fullRange) }
}
#endif
