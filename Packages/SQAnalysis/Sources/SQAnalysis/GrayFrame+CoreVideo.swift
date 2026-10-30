import CoreVideo
import Foundation

extension GrayFrame {
    /// The BGRA buffer at half size (2x2 mean), as luma. nil for other formats or an empty buffer.
    init?(halving pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        let w = CVPixelBufferGetWidth(pb) / 2, h = CVPixelBufferGetHeight(pb) / 2
        guard w >= 8, h >= 8 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let r0 = bytes + (2 * y) * row, r1 = r0 + row
                for x in 0..<w {
                    let a = r0 + 8 * x, c = r1 + 8 * x
                    let blue = Float(a[0]) + Float(a[4]) + Float(c[0]) + Float(c[4])
                    let green = Float(a[1]) + Float(a[5]) + Float(c[1]) + Float(c[5])
                    let red = Float(a[2]) + Float(a[6]) + Float(c[2]) + Float(c[6])
                    o[y * w + x] = (0.114 * blue + 0.587 * green + 0.299 * red) * 0.25
                }
            }
        }
        self.init(width: w, height: h, pixels: out)
    }

    /// The BGRA buffer at its own size, as luma. nil for other formats or an empty buffer.
    init?(fullSize pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w >= 32, h >= 32 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let r = bytes + y * row
                for x in 0..<w {
                    o[y * w + x] = 0.114 * Float(r[4 * x]) + 0.587 * Float(r[4 * x + 1]) + 0.299 * Float(r[4 * x + 2])
                }
            }
        }
        self.init(width: w, height: h, pixels: out)
    }
}
