#if canImport(CoreVideo)
import CoreVideo
import SQCore
import SQFrame

/// Mac storage: the CVPixelBuffer itself (IOSurface-backed, Metal compatible). One reference, so it sits inline in the
/// `any SQFrameStorage` box: wrapping and unwrapping copy and allocate nothing (a retain, as passing the buffer did).
/// `@unchecked`: decoded and rendered buffers are not written after they are wrapped (as `DecodedFrame` always assumed).
public struct CoreVideoFrameStorage: SQFrameStorage, @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

public extension SQFramePixelFormat {
    /// The neutral case of a CoreVideo pixel format; unknown codes stay `.other(code)`.
    init(coreVideo code: OSType) {
        switch code {
        case kCVPixelFormatType_32BGRA: self = .bgra8
        case kCVPixelFormatType_32RGBA: self = .rgba8
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .nv12
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .nv12FullRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: self = .p010
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self = .p010FullRange
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: self = .p210
        case kCVPixelFormatType_64RGBAHalf: self = .rgba16f
        case kCVPixelFormatType_128RGBAFloat: self = .rgba32f
        case kCVPixelFormatType_4444AYpCbCr16: self = .ayuv16
        default: self = .other(code)
        }
    }

    /// The CoreVideo code of this format.
    var coreVideoFormat: OSType {
        switch self {
        case .bgra8: kCVPixelFormatType_32BGRA
        case .rgba8: kCVPixelFormatType_32RGBA
        case .nv12: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12FullRange: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .p010: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p010FullRange: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .p210: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .rgba16f: kCVPixelFormatType_64RGBAHalf
        case .rgba32f: kCVPixelFormatType_128RGBAFloat
        case .ayuv16: kCVPixelFormatType_4444AYpCbCr16
        case .other(let code): code
        }
    }
}

public extension SQFrame {
    /// Wraps `pixelBuffer` without copying. Size and format are read from the buffer (field reads).
    /// shortcut: the color tag is not derived from the buffer's attachments (Mac readers use the attachments and
    /// `VideoTrackInfo` directly); derive it when a non-Mac reader needs the tag.
    init(pixelBuffer: CVPixelBuffer, presentationTime: Time = .zero, colorSpace: SQFrameColorSpace = .unspecified) {
        self.init(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                  pixelFormat: SQFramePixelFormat(coreVideo: CVPixelBufferGetPixelFormatType(pixelBuffer)),
                  colorSpace: colorSpace, presentationTime: presentationTime,
                  storage: CoreVideoFrameStorage(pixelBuffer))
    }

    /// The wrapped CVPixelBuffer, nil when the storage is not CoreVideo.
    var coreVideoBuffer: CVPixelBuffer? { (storage as? CoreVideoFrameStorage)?.pixelBuffer }

    /// The wrapped CVPixelBuffer. Every frame on the Mac is CoreVideo-backed; another storage is a programming error.
    var pixelBuffer: CVPixelBuffer {
        guard let pb = coreVideoBuffer else { preconditionFailure("SQFrame storage is not a CVPixelBuffer: \(type(of: storage))") }
        return pb
    }
}
#endif
