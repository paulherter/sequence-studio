import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQCore

/// Still images (png, jpg, heic ...) read through ImageIO. The picture is decoded once into a BGRA8 pixel buffer
/// (upright: EXIF orientation applied) that the compositor samples like a decoded video frame.
/// The pixel values are taken as sRGB-ish display values and linearised with the Rec.709 curve like video (close to sRGB).
public enum StillImage {
    /// Raster formats ImageIO reads. webp, psd, exr and the camera RAW formats depend on the OS; a file ImageIO cannot
    /// open fails to import with a reason (`MediaDiagnosis`).
    public static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp",
        "psd", "exr", "tga", "dpx", "dng", "ico", "icns", "hdr", "jp2", "j2k", "sgi",
    ]
    /// Camera RAW stills (developed by the system's RAW engine, one frame).
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "raw", "dcr", "kdc", "mrw", "3fr", "erf",
    ]
    /// Vector artwork rasterized once at import size: SVG, and the first page of a PDF or Illustrator (AI, PDF compatible) file.
    public static let vectorExtensions: Set<String> = ["svg", "pdf", "ai"]
    /// File extensions imported as stills.
    public static let extensions: Set<String> = rasterExtensions.union(rawExtensions).union(vectorExtensions)

    /// Vector artwork is drawn so its longest side is at least this many pixels (a 100 pt logo is not a 100 px still).
    public static let vectorMinimumSide = 1920

    /// Longest side of the decoded buffer; larger pictures are scaled down (textures are limited to 16384).
    public static let maxDimension = 8192

    public static func isStill(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func isVector(_ url: URL) -> Bool { vectorExtensions.contains(url.pathExtension.lowercased()) }

    public enum StillError: Error, Sendable { case unreadable, bufferFailed }

    /// Upright pixel size from the file properties (no pixel decode). Orientations 5...8 swap width and height.
    public static func size(of url: URL) throws -> (width: Int, height: Int) {
        if isVector(url) { return try vectorPixelSize(of: url) }
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
        if isVector(url) {
            var side = min(maxPixel ?? maxDimension, maxDimension)
            if fitHeight > 0 { side = max(1, Int((Double(fitHeight) * Double(max(w, h)) / Double(h)).rounded())) }
            let scale = min(1, Double(side) / Double(max(w, h)))
            return try renderVector(url, width: max(1, Int((Double(w) * scale).rounded())), height: max(1, Int((Double(h) * scale).rounded())))
        }
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

    /// `VideoTrackInfo` describing a still (`codec` "image", 8 bit), for the compositor's color hint.
    public static func trackInfo(width: Int, height: Int) -> VideoTrackInfo {
        VideoTrackInfo(width: width, height: height, codec: "image", bitDepth: 8, chroma: "4:4:4",
                       nominalFrameDuration: Time(1, 30), isVariableFrameRate: false,
                       colorPrimaries: nil, transfer: nil, matrix: nil)
    }

    // MARK: Vector artwork

    /// Intrinsic size in points (PDF: first page crop box with its rotation; SVG: the image's own size).
    static func vectorPointSize(of url: URL) -> CGSize? {
        if url.pathExtension.lowercased() == "svg" {
            guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else { return nil }
            return img.size
        }
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        var r = page.getBoxRect(.cropBox)
        if page.rotationAngle % 180 != 0 { r = CGRect(x: 0, y: 0, width: r.height, height: r.width) }
        return r.width > 0 && r.height > 0 ? r.size : nil
    }

    static func vectorPixelSize(of url: URL) throws -> (width: Int, height: Int) {
        guard let p = vectorPointSize(of: url) else { throw StillError.unreadable }
        let longest = Double(max(p.width, p.height))
        let s = min(max(1, Double(vectorMinimumSide) / longest), Double(maxDimension) / longest)
        return (max(1, Int((p.width * s).rounded())), max(1, Int((p.height * s).rounded())))
    }

    /// Draws the artwork on a transparent canvas of `width` x `height` pixels.
    static func renderVector(_ url: URL, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw StillError.bufferFailed }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        if url.pathExtension.lowercased() == "svg" {
            guard let img = NSImage(contentsOf: url) else { throw StillError.unreadable }
            var rect = canvas
            guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw StillError.unreadable }
            ctx.draw(cg, in: canvas)
        } else {
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { throw StillError.unreadable }
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
        }
        guard let out = ctx.makeImage() else { throw StillError.bufferFailed }
        return out
    }
}
