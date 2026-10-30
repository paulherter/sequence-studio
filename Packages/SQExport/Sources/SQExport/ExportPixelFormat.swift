#if canImport(CoreVideo)
import CoreVideo
#endif
import Foundation

/// Output pixel format of the export render: BGRA 8-bit, 4:2:0 8-bit ('420v'), 4:2:0 10-bit ('x420', HEVC Main 10),
/// 4:2:2 10-bit ('x422', ProRes 422) or 4:4:4:4 AYpCbCr 16-bit ('y416', ProRes 4444): `ayuv4444` opaque,
/// `ayuv4444Alpha` rendered over transparent with straight color and the coverage in alpha (tagged straight).
public enum ExportPixelFormat: Sendable, Hashable {
    case bgra8, yuv420v, yuv420v10, yuv422v10, ayuv4444, ayuv4444Alpha
    /// Premultiplied linear rgba16Float over transparent: the working picture as is (image sequences, `FrameStillWriter`).
    case rgbaHalf

    #if canImport(CoreVideo)
    public var cvPixelFormat: OSType {
        switch self {
        case .bgra8: kCVPixelFormatType_32BGRA
        case .yuv420v: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv420v10: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .yuv422v10: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .ayuv4444, .ayuv4444Alpha: kCVPixelFormatType_4444AYpCbCr16
        case .rgbaHalf: kCVPixelFormatType_64RGBAHalf
        }
    }
    #endif
    /// Chroma subsampled horizontally: width and height must be even.
    var needsEvenSize: Bool { self == .yuv420v || self == .yuv420v10 || self == .yuv422v10 }
}
