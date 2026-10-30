import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQCore
import UniformTypeIdentifiers
import VideoToolbox

public struct CoverImageError: Error, CustomStringConvertible {
    public let description: String
}

/// Writes one rendered frame as PNG or JPEG (the export dialog's "Also save cover image").
public enum CoverImageWriter {
    /// Non-square pixels: a still has no pixel aspect tag, so the image is written at its display width.
    public static func write(_ frame: CVPixelBuffer, format: CoverImageFormat, pixelAspect: PixelAspect = .square, to url: URL) throws {
        var stored: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &stored)
        var image = stored
        if let s = stored, !pixelAspect.isSquare {
            let w = pixelAspect.displayWidth(ofStored: s.width)
            if let cs = s.colorSpace, let ctx = CGContext(data: nil, width: w, height: s.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(s, in: CGRect(x: 0, y: 0, width: w, height: s.height))
                image = ctx.makeImage() ?? s
            }
        }
        guard let image else { throw CoverImageError(description: "The cover frame could not be converted to an image.") }
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CoverImageError(description: "The cover image file could not be created.")
        }
        let opts: [CFString: Any] = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CoverImageError(description: "The cover image could not be written.") }
    }
}
