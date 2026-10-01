import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQCore

/// Still images (png, jpg, heic ...) read through ImageIO. The picture is decoded once into a BGRA8 pixel buffer
/// (upright: EXIF orientation applied) that the compositor samples like a decoded video frame.
/// The pixel values are taken as sRGB-ish display values and linearised with the Rec.709 curve like video (close to sRGB).
public enum StillImage {
    /// File extensions imported as stills. webp depends on ImageIO support of the OS; unreadable files fail to import.
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    /// Longest side of the decoded buffer; larger pictures are scaled down (textures are limited to 16384).
    public static let maxDimension = 8192

    public static func isStill(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    public enum StillError: Error, Sendable { case unreadable, bufferFailed }

    /// Upright pixel size from the file properties (no pixel decode). Orientations 5...8 swap width and height.
    public static func size(of url: URL) throws -> (width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { throw StillError.unreadable }
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 ? (h, w) : (w, h)
    }

    /// Upright image, scaled so its longest side is at most `maxPixel` (nil = `maxDimension`).
    /// `fitHeight` > 0 scales to exactly that pixel height instead (thumbnails, upright).
    public static func cgImage(of url: URL, maxPixel: Int? = nil, fitHeight: Int = 0) throws -> CGImage {
        let (w, h) = try size(of: url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw StillError.unreadable }
        let limit = min(maxPixel ?? maxDimension, maxDimension)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: fitHeight > 0 ? max(1, Int((Double(fitHeight) * Double(max(w, h)) / Double(h)).rounded())) : min(limit, max(w, h)),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw StillError.unreadable }
        return img
    }

    /// Decodes the picture into a BGRA8 (premultiplied) Metal-compatible pixel buffer.
    public static func load(_ url: URL) throws -> CVPixelBuffer {
        let image = try cgImage(of: url)
        return try pixelBuffer(from: image)
    }

    public static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { throw StillError.bufferFailed }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw StillError.bufferFailed }
        ctx.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }

    /// `VideoTrackInfo` describing a still (`codec` "image", 8 bit), for the compositor's colour hint.
    public static func trackInfo(width: Int, height: Int) -> VideoTrackInfo {
        VideoTrackInfo(width: width, height: height, codec: "image", bitDepth: 8, chroma: "4:4:4",
                       nominalFrameDuration: Time(1, 30), isVariableFrameRate: false,
                       colorPrimaries: nil, transfer: nil, matrix: nil)
    }
}
