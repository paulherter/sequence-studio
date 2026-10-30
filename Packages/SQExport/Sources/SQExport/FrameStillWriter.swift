import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameStillWriter {
    /// BT.709 OETF of a linear value.
    public static func oetf(_ x: Float) -> Float { FrameStillPixels.oetf(x) }

    /// Writes `pixels` (rgba, premultiplied linear, `width * height * 4` half floats) to `url`.
    public static func write(pixels: UnsafeBufferPointer<Float16>, width w: Int, height h: Int,
                             format: FrameStillFormat, to url: URL) throws {
        guard w > 0, h > 0, pixels.count >= w * h * 4, let image = image(pixels: pixels, width: w, height: h, format: format),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let props: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func image(pixels src: UnsafeBufferPointer<Float16>, width w: Int, height h: Int, format: FrameStillFormat) -> CGImage? {
        let n = w * h
        if format == .exr {
            guard let space = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
            var out = [Float16](repeating: 1, count: n * 4)
            for i in 0..<(n * 4) { out[i] = src[i] }
            guard let provider = CGDataProvider(data: Data(bytes: out, count: out.count * 2) as CFData) else { return nil }
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)
            return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                           bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        // The code values are shared with the Windows writer (`FrameStillPixels`).
        guard let px = FrameStillPixels.image(halfRGBA: UnsafeRawBufferPointer(src), width: w, height: h, bytesPerRow: w * 8,
                                              format: format),
              let provider = CGDataProvider(data: Data(px.bytes) as CFData) else { return nil }
        let alphaInfo: CGImageAlphaInfo = px.hasAlpha ? .last : .noneSkipLast
        let order: CGBitmapInfo = px.bitsPerChannel == 16 ? .byteOrder16Little : []
        return CGImage(width: w, height: h, bitsPerComponent: px.bitsPerChannel, bitsPerPixel: px.bitsPerChannel * 4,
                       bytesPerRow: px.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue | order.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
