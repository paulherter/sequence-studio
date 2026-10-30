import CoreGraphics
import CoreMedia
import Foundation
import SQCore

/// F7.3: the pixel aspect ratio a file tags its picture with (`pasp` in MP4/MOV, the SPS VUI the system parser lifts
/// into the format description, DisplayWidth in Matroska when the demuxer writes the extension).
public enum PixelAspectTag {
    /// Square for an untagged track and for a tag no lens or broadcast format produces (zero, negative, beyond 4:1).
    public static func pixelAspect(of fd: CMFormatDescription) -> PixelAspect {
        pixelAspect(extensions: CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:])
    }

    static func pixelAspect(extensions ext: [String: Any]) -> PixelAspect {
        guard let par = ext[kCMFormatDescriptionExtension_PixelAspectRatio as String] as? [String: Any],
              let h = (par[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.intValue,
              let v = (par[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.intValue
        else { return .square }
        return PixelAspect(h, v) ?? .square
    }

    /// `image` (upright, drawn with pixel aspect `from`) redrawn as it looks with `to`: the same height, the width
    /// rescaled. `quarterTurned` = the source is shown turned by 90 or 270 degrees: its stored width is the upright
    /// height, so a wider pixel makes the picture taller, which at the same height is a narrower image.
    /// Returns `image` itself when nothing changes or the redraw fails.
    public static func redrawn(_ image: CGImage, from: PixelAspect, to: PixelAspect, quarterTurned: Bool = false) -> CGImage {
        guard from != to else { return image }
        let (up, down) = quarterTurned ? (to.den * from.num, to.num * from.den) : (to.num * from.den, to.den * from.num)
        let width = max(1, (image.width * up + down / 2) / down)
        guard width != image.width,
              let ctx = CGContext(data: nil, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                ?? CGContext(data: nil, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
