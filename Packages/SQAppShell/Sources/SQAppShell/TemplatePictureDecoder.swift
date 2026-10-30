import Foundation
import SQDrawKit
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Decodes the PNG of a saved multi-layer template for the Text panel's tiles (`TextTemplateTileAtlas.decodePicture`):
/// ImageIO on the Mac; other platforms set `platform` at launch (Windows: FFmpeg, `WinStillDecoder`).
@MainActor
public enum TemplatePictureDecoder {
    /// The platform decoder where ImageIO is missing (nil: saved pictures show the template's sample text).
    public static var platform: (@MainActor (Data) -> RGBAImage?)?

    public static func decode(_ data: Data) -> RGBAImage? {
        if let platform { return platform(data) }
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width > 0, img.height > 0 else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Premultiplied to straight alpha (RGBAImage holds straight color).
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
            let a = Double(px[i + 3]) / 255
            for k in 0..<3 { px[i + k] = UInt8(min(255, (Double(px[i + k]) / a).rounded())) }
        }
        return RGBAImage(width: w, height: h, pixels: px)
        #else
        return nil
        #endif
    }
}
