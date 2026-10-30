import Foundation
import SQCore
import SQMedia

/// The playback quality's picture reduction for engines that get full-size NV12 bytes from their decoder (Windows: FFmpeg
/// frames downloaded to the CPU): a box filter over 2 x 2 (1/2) or 4 x 4 (1/4) luma samples and the matching chroma
/// pairs. The compositor places a layer by the media's native size, so a smaller picture only lowers the sampled detail.
/// shortcut: the decoder still decodes at full size (only upload, cache and sampling shrink); upgrade by letting FFmpeg
/// scale (sws / hardware scaler) when decode time limits Windows playback.
public enum NV12Reduce {
    /// The divisor of a decode scale (1, 2, 4).
    public static func divisor(_ s: DecodeScale) -> Int {
        switch s { case .full: 1; case .half: 2; case .quarter: 4 }
    }

    /// `bytes` (width x height luma, then interleaved CbCr at half size, stride = width) reduced by `divisor`; nil when
    /// the divisor is 1, the size does not divide evenly into whole chroma pairs, or the bytes are short.
    public static func reduce(_ bytes: [UInt8], width w: Int, height h: Int, by d: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard d > 1, w % (2 * d) == 0, h % (2 * d) == 0, bytes.count >= w * h * 3 / 2 else { return nil }
        let ow = w / d, oh = h / d
        var out = [UInt8](repeating: 0, count: ow * oh * 3 / 2)
        let area = d * d, half = area / 2
        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<oh {
                    for x in 0..<ow {
                        var sum = 0
                        for dy in 0..<d {
                            let row = (y * d + dy) * w + x * d
                            for dx in 0..<d { sum += Int(src[row + dx]) }
                        }
                        dst[y * ow + x] = UInt8((sum + half) / area)
                    }
                }
                // Chroma: (w / 2) x (h / 2) Cb Cr pairs, each averaged over d x d pairs.
                let cw = w / 2, ocw = ow / 2, och = oh / 2
                let cBase = w * h, oBase = ow * oh
                for y in 0..<och {
                    for x in 0..<ocw {
                        var cb = 0, cr = 0
                        for dy in 0..<d {
                            let row = cBase + (y * d + dy) * cw * 2 + x * d * 2
                            for dx in 0..<d { cb += Int(src[row + dx * 2]); cr += Int(src[row + dx * 2 + 1]) }
                        }
                        let o = oBase + (y * ocw + x) * 2
                        dst[o] = UInt8((cb + half) / area)
                        dst[o + 1] = UInt8((cr + half) / area)
                    }
                }
            }
        }
        return (out, ow, oh)
    }
}
