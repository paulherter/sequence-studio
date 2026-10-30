import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The formats of Export Frame. The working picture is premultiplied linear rgba16Float; every format but EXR applies the
/// BT.709 transfer curve like the viewer does, EXR keeps the linear values.
public enum FrameStillFormat: String, CaseIterable, Sendable, Codable {
    case png, pngAlpha, jpeg, tiff16, tiff16Alpha, exr

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .pngAlpha: "PNG (with alpha)"
        case .jpeg: "JPEG"
        case .tiff16: "TIFF (16-bit)"
        case .tiff16Alpha: "TIFF (16-bit, with alpha)"
        case .exr: "EXR (half float, linear)"
        }
    }
    public var fileExtension: String {
        switch self {
        case .png, .pngAlpha: "png"
        case .jpeg: "jpg"
        case .tiff16, .tiff16Alpha: "tiff"
        case .exr: "exr"
        }
    }
    #if canImport(UniformTypeIdentifiers)
    public var typeIdentifier: String {
        switch self {
        case .png, .pngAlpha: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .tiff16, .tiff16Alpha: UTType.tiff.identifier
        case .exr: "com.ilm.openexr-image"
        }
    }
    #endif
    public var keepsAlpha: Bool { self == .pngAlpha || self == .tiff16Alpha || self == .exr }

    #if canImport(ImageIO)
    /// Whether this Mac's ImageIO can write the format (EXR depends on the system version).
    public var isSupported: Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(typeIdentifier)
    }
    #else
    /// Off the Mac `FFmpegExportEncoder` (SQMediaFFmpeg) writes every format (png, mjpeg, tiff, exr encoders).
    public var isSupported: Bool { true }
    #endif
    public static var available: [FrameStillFormat] { allCases.filter(\.isSupported) }
}
