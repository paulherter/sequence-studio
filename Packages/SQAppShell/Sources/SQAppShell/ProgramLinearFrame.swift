import Foundation
import SQExport

/// A read-back of the composited Program picture in working-linear Rec.709 (the Mac samples its rgba16Float render
/// target, ColorPickHub): what the Color page's white-balance eyedropper and Basic Correction Auto measure on platforms
/// that read the frame back themselves (Windows: `WinCompositor.downloadLinear`). Rows top down.
public struct ProgramLinearFrame: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [SIMD3<Float>]

    public init(width: Int, height: Int, pixels: [SIMD3<Float>]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// From rgba half floats (stride = width * 8): the color channels as stored (premultiplied, as the Mac reads them).
    public init?(halfRGBA bytes: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, bytes.count >= width * height * 8 else { return nil }
        let px = bytes.withUnsafeBytes { raw in
            (0..<(width * height)).map { i -> SIMD3<Float> in
                func ch(_ c: Int) -> Float {
                    FrameStillPixels.float(halfBits: raw.loadUnaligned(fromByteOffset: i * 8 + c * 2, as: UInt16.self))
                }
                return SIMD3(ch(0), ch(1), ch(2))
            }
        }
        self.init(width: width, height: height, pixels: px)
    }

    /// The pixel rectangle (x, y, width, height) of the (2·radius+1)² patch around a 0…1 position (y down), cut at the
    /// picture edge (the Mac `ColorPickHub.patch`).
    public static func patch(width: Int, height: Int, at p: SIMD2<Double>, radius: Int) -> (Int, Int, Int, Int)? {
        guard width > 0, height > 0, p.x.isFinite, p.y.isFinite else { return nil }
        let cx = min(max(Int(p.x * Double(width)), 0), width - 1), cy = min(max(Int(p.y * Double(height)), 0), height - 1)
        let x0 = max(cx - radius, 0), y0 = max(cy - radius, 0)
        return (x0, y0, min(cx + radius, width - 1) - x0 + 1, min(cy + radius, height - 1) - y0 + 1)
    }

    /// The mean color of the patch around `p` (the eyedropper's sample); nil outside the picture or for an empty frame.
    public func average(at p: SIMD2<Double>, radius: Int = 2) -> SIMD3<Float>? {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1, pixels.count == width * height,
              let (x0, y0, w, h) = Self.patch(width: width, height: height, at: p, radius: radius) else { return nil }
        var sum = SIMD3<Float>.zero
        for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { sum += pixels[y * width + x] } }
        return sum / Float(w * h)
    }

    /// Size of the scaled read-back for Auto: `width` (at most the picture's) by the picture's aspect, at least one row.
    public static func scaledSize(width: Int, sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int)? {
        guard width > 0, sourceWidth > 0, sourceHeight > 0 else { return nil }
        let w = min(width, sourceWidth)
        return (w, max(Int((Double(w) * Double(sourceHeight) / Double(sourceWidth)).rounded()), 1))
    }
}
