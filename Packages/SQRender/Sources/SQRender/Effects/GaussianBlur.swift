import Foundation
import simd

/// Gaussian Blur. `blurriness` is the standard deviation in px of the clip's own frame. The CPU functions are the
/// reference the compute kernel is tested against; the GPU path also shrinks the work for large sigma (see `Plan`).
public enum GaussianBlur {
    /// Largest sigma the GPU runs at full size. Beyond it the layer is drawn at 1/factor size first, blurred there and
    /// stretched back (linear filtering), so the kernel never exceeds `3 * maxDirectSigma` taps per side.
    public static let maxDirectSigma: Double = 6
    static let maxTextureSize = 16_384

    /// Normalised 1D kernel for taps -radius...radius (2 * radius + 1 values). Radius defaults to ceil(3 sigma).
    public static func weights(sigma: Float, radius: Int? = nil) -> [Float] {
        let r = radius ?? Int((3 * sigma).rounded(.up))
        guard sigma > 0, r > 0 else { return [1] }
        var w = (-r...r).map { k in expf(-Float(k * k) / (2 * sigma * sigma)) }
        let sum = w.reduce(0, +)
        for i in w.indices { w[i] /= sum }
        return w
    }

    /// Separable blur of premultiplied pixels with zero outside the image: the reference.
    public static func blur(_ px: [SIMD4<Float>], width: Int, height: Int, sigma: Float) -> [SIMD4<Float>] {
        guard sigma > 0 else { return px }
        let w = weights(sigma: sigma), r = (w.count - 1) / 2
        var tmp = [SIMD4<Float>](repeating: .zero, count: px.count)
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD4<Float>.zero
                for k in -r...r where x + k >= 0 && x + k < width { acc += px[y * width + x + k] * w[k + r] }
                tmp[y * width + x] = acc
            }
        }
        var out = tmp
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD4<Float>.zero
                for k in -r...r where y + k >= 0 && y + k < height { acc += tmp[(y + k) * width + x] * w[k + r] }
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

        public init(layerWidth: Double, layerHeight: Double, sigma: Double) {
            var f = max(1, Int((sigma / GaussianBlur.maxDirectSigma).rounded(.up)))
            while true {
                let s = Float(sigma / Double(f))
                let r = max(1, Int((3 * s).rounded(.up)))
                let tw = Int((layerWidth / Double(f)).rounded(.up)) + 2 * r
                let th = Int((layerHeight / Double(f)).rounded(.up)) + 2 * r
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
