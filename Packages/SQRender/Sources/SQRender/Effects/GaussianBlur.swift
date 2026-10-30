import Foundation
#if canImport(simd)
import simd
#endif

/// Gaussian Blur. `blurriness` is the standard deviation in px of the clip's own frame. The CPU functions are the
/// reference the compute kernel is tested against; the GPU path also shrinks the work for large sigma (see `Plan`).
public enum GaussianBlur {
    /// Largest sigma the GPU runs at full size. Beyond it the layer is drawn at 1/factor size first, blurred there and
    /// stretched back (linear filtering), so the kernel never exceeds `3 * maxDirectSigma` taps per side.
    public static let maxDirectSigma: Double = 6
    static let maxTextureSize = 16_384
    /// Pixel budget of the Long Shadow's own shadow planes (4096 x 4096: 128 MB at rgba16Float, two of them). Beyond it the
    /// plane alone runs at a reduced size and is stretched back under the full-size picture.
    public static let maxShapePassPixels = 4_096 * 4_096
    /// Pixel budget of the padded working canvas of a Long Shadow or Outline pass (8192 x 8192: 512 MB at rgba16Float). The
    /// picture is never reduced for it: only the transparent margin is cut (the far end of a very long shadow).
    public static let maxShapeCanvasPixels = 8_192 * 8_192

    /// Normalized 1D kernel for taps -radius...radius (2 * radius + 1 values). Radius defaults to ceil(3 sigma).
    public static func weights(sigma: Float, radius: Int? = nil) -> [Float] {
        let r = radius ?? Int((3 * sigma).rounded(.up))
        guard sigma > 0, r > 0 else { return [1] }
        var w = (-r...r).map { k in expf(-Float(k * k) / (2 * sigma * sigma)) }
        let sum = w.reduce(0, +)
        for i in w.indices { w[i] /= sum }
        return w
    }

    /// Separable blur of premultiplied pixels with zero outside the image: the reference. `repeatEdges` (Repeat Edge
    /// Pixels): outside the image the edge pixels repeat instead, so an opaque picture stays opaque up to its edge.
    public static func blur(_ px: [SIMD4<Float>], width: Int, height: Int, sigma: Float,
                            repeatEdges: Bool = false) -> [SIMD4<Float>] {
        guard sigma > 0 else { return px }
        let w = weights(sigma: sigma), r = (w.count - 1) / 2
        var tmp = [SIMD4<Float>](repeating: .zero, count: px.count)
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD4<Float>.zero
                for k in -r...r {
                    var xx = x + k
                    if repeatEdges { xx = min(max(xx, 0), width - 1) } else if xx < 0 || xx >= width { continue }
                    acc += px[y * width + xx] * w[k + r]
                }
                tmp[y * width + x] = acc
            }
        }
        var out = tmp
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD4<Float>.zero
                for k in -r...r {
                    var yy = y + k
                    if repeatEdges { yy = min(max(yy, 0), height - 1) } else if yy < 0 || yy >= height { continue }
                    acc += tmp[yy * width + x] * w[k + r]
                }
                out[y * width + x] = acc
            }
        }
        return out
    }

    /// How the GPU blurs a layer of `layerWidth x layerHeight` px with `sigma`.
    public struct Plan: Equatable, Sendable {
        /// The layer is drawn at 1/factor size (1 = full size).
        public var factor: Int
        /// Sigma at the working size.
        public var sigma: Float
        public var radius: Int
        /// Working texture size: the (reduced) picture plus `radius` of transparent margin on each side.
        public var textureWidth: Int, textureHeight: Int
        /// Reduced picture size inside the texture (not necessarily whole px).
        public var contentWidth: Float, contentHeight: Float

        /// Size of the finished image in layer px (bigger than the layer by the margin).
        public var outputWidth: Float { Float(textureWidth * factor) }
        public var outputHeight: Float { Float(textureHeight * factor) }

        /// `extraMargin`: more transparent border in layer px (a Drop Shadow's offset), on top of the 3 sigma; `extraMarginY`
        /// a different one for top and bottom (nil = the same).
        /// `minFactor`: work at 1/minFactor size or smaller (a layer shown at half size or less, see `effectWorkFactor`).
        /// `maxPixels`: the working texture never holds more pixels; the extra margin is cut until it fits, never the picture
        /// (export and full-quality playback keep the clip's resolution). Only the device limit `maxTextureSize` reduces it.
        public init(layerWidth: Double, layerHeight: Double, sigma: Double, extraMargin: Double = 0, extraMarginY: Double? = nil,
                    minFactor: Int = 1, maxPixels: Int = .max) {
            var f = max(1, minFactor, Int((sigma / GaussianBlur.maxDirectSigma).rounded(.up)))
            var extraMargin = extraMargin, extraMarginY = extraMarginY
            while true {
                let s = Float(sigma / Double(f))
                let r = sigma > 0 ? max(1, Int((3 * s).rounded(.up))) : 0
                // Rounded up to a multiple of 64 so a sigma that animates keeps asking for the same few texture sizes and the
                // pool can reuse them; the picture inside keeps its exact size, centered.
                func up(_ v: Int) -> Int { (v + 63) / 64 * 64 }
                let mx = r + Int((extraMargin / Double(f)).rounded(.up))
                let my = r + Int(((extraMarginY ?? extraMargin) / Double(f)).rounded(.up))
                let tw = up(Int((layerWidth / Double(f)).rounded(.up)) + 2 * mx)
                let th = up(Int((layerHeight / Double(f)).rounded(.up)) + 2 * my)
                if tw * th > maxPixels, max(extraMargin, extraMarginY ?? extraMargin) >= 1 {
                    // Over the budget: shrink the margin (5 % per try, both axes alike), keep the picture's size.
                    extraMargin = (extraMargin * 0.95).rounded(.down)
                    extraMarginY = extraMarginY.map { ($0 * 0.95).rounded(.down) }
                    continue
                }
                if max(tw, th) <= GaussianBlur.maxTextureSize || f > 4096 {
                    factor = f; self.sigma = s; radius = r
                    textureWidth = tw; textureHeight = th
                    contentWidth = Float(layerWidth / Double(f)); contentHeight = Float(layerHeight / Double(f))
                    return
                }
                f += 1
            }
        }
    }
}
