import SQCore

/// Pixel layout of a frame's storage. Platform codes without a neutral name travel as `.other` (CoreVideo FourCC on the
/// Mac, e.g. Apple's lossless-compressed `&8v0`), so wrapping never fails.
public enum SQFramePixelFormat: Sendable, Hashable {
    /// 8-bit B, G, R, A, one plane.
    case bgra8
    /// 8-bit R, G, B, A, one plane.
    case rgba8
    /// 8-bit 4:2:0 YCbCr, Y plane + interleaved CbCr plane, video range.
    case nv12
    case nv12FullRange
    /// 10-bit 4:2:0 YCbCr in 16-bit words, two planes, video range.
    case p010
    case p010FullRange
    /// 10-bit 4:2:2 YCbCr in 16-bit words, two planes, video range.
    case p210
    /// 16-bit float R, G, B, A, one plane.
    case rgba16f
    /// 32-bit float R, G, B, A, one plane.
    case rgba32f
    /// 16-bit A, Y, Cb, Cr 4:4:4, one plane (ProRes 4444 decode).
    case ayuv16
    /// A platform format code without a neutral case.
    case other(UInt32)

    /// Number of planes; nil for `.other` (only the platform knows).
    public var planeCount: Int? {
        switch self {
        case .nv12, .nv12FullRange, .p010, .p010FullRange, .p210: 2
        case .bgra8, .rgba8, .rgba16f, .rgba32f, .ayuv16: 1
        case .other: nil
        }
    }

    public var isYCbCr: Bool {
        switch self {
        case .nv12, .nv12FullRange, .p010, .p010FullRange, .p210, .ayuv16: true
        case .bgra8, .rgba8, .rgba16f, .rgba32f, .other: false
        }
    }

    /// Full-range (0...max) YCbCr; RGB formats are always full range.
    public var isFullRange: Bool {
        switch self {
        case .nv12, .p010, .p210: false
        default: true
        }
    }

    /// Significant bits per component; nil for `.other`.
    public var bitsPerComponent: Int? {
        switch self {
        case .bgra8, .rgba8, .nv12, .nv12FullRange: 8
        case .p010, .p010FullRange, .p210: 10
        case .rgba16f, .ayuv16: 16
        case .rgba32f: 32
        case .other: nil
        }
    }
}

/// Color space a frame's pixels are encoded in (primaries + transfer).
public enum SQFrameColorSpace: Sendable, Hashable {
    /// Not tagged: the reader decides (on the Mac the buffer attachments and the track's `VideoTrackInfo` decide).
    case unspecified
    case rec601
    case rec709
    case sRGB
    case displayP3
    case rec2020
    case rec2020PQ
    case rec2020HLG
    /// Linear light, Rec.709 primaries (the compositor's working space, text rasters).
    case linearRec709
}

/// The platform object that holds a frame's pixels: a CVPixelBuffer on the Mac (`SQFrameCoreVideo`), later a D3D12
/// texture or an FFmpeg frame on Windows. Opaque to everything outside the platform layer; immutable once wrapped.
/// A storage of at most three words (one reference) sits inline in the `any SQFrameStorage` box: no allocation per frame.
public protocol SQFrameStorage: Sendable {}

/// One video frame handed across package boundaries (decoder -> playback -> render). A value: copies share the storage,
/// nothing is copied pixel-wise. Engine internals unwrap the platform storage (`pixelBuffer` on the Mac).
public struct SQFrame: Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: SQFramePixelFormat
    public var colorSpace: SQFrameColorSpace
    public var presentationTime: Time
    public let storage: any SQFrameStorage

    public init(width: Int, height: Int, pixelFormat: SQFramePixelFormat, colorSpace: SQFrameColorSpace = .unspecified,
                presentationTime: Time = .zero, storage: any SQFrameStorage) {
        self.width = width; self.height = height; self.pixelFormat = pixelFormat; self.colorSpace = colorSpace
        self.presentationTime = presentationTime; self.storage = storage
    }

    /// The same pixels at another presentation time.
    public func withPresentationTime(_ t: Time) -> SQFrame {
        var f = self
        f.presentationTime = t
        return f
    }
}
