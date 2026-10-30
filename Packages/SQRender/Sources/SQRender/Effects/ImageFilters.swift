import Foundation
import SQCore
import SQGPUKernels
#if canImport(simd)
import simd
#endif

/// W3.1 whole-picture effects (Sharpen, Directional Blur, Mirror, Noise, Glow, Mosaic). The CPU functions are the reference the
/// compute kernels are tested against; both work on premultiplied working-linear pixels in the padded intermediate, where the
/// clip's own frame is a rectangle centered in the texture (`Frame`).
public enum ImageFilters {
    /// The clip's own frame inside the working image, in texture px.
    public struct Frame: Sendable, Equatable {
        public var center: SIMD2<Float>, size: SIMD2<Float>
        public init(center: SIMD2<Float>, size: SIMD2<Float>) { self.center = center; self.size = size }
        public var origin: SIMD2<Float> { center - size / 2 }
    }

    /// A premultiplied image for the references (row-major, y down).
    public struct Image: Sendable, Equatable {
        public var width: Int, height: Int
        public var px: [SIMD4<Float>]
        public init(width: Int, height: Int, px: [SIMD4<Float>]) { self.width = width; self.height = height; self.px = px }
        public init(width: Int, height: Int, _ f: (Int, Int) -> SIMD4<Float>) {
            self.width = width; self.height = height
            px = (0..<(width * height)).map { f($0 % width, $0 / width) }
        }
        public subscript(x: Int, y: Int) -> SIMD4<Float> {
            x < 0 || y < 0 || x >= width || y >= height ? .zero : px[y * width + x]
        }
        /// Bilinear at texture position `p` (px, pixel centers at +0.5), transparent outside: what the GPU sampler does.
        public func sample(_ p: SIMD2<Float>) -> SIMD4<Float> {
            let q = p - 0.5
            let x0 = Int(floor(q.x)), y0 = Int(floor(q.y))
            let fx = q.x - Float(x0), fy = q.y - Float(y0)
            let top = self[x0, y0] * (1 - fx) + self[x0 + 1, y0] * fx
            let bottom = self[x0, y0 + 1] * (1 - fx) + self[x0 + 1, y0 + 1] * fx
            return top * (1 - fy) + bottom * fy
        }
        func map(_ f: (Int, Int, SIMD4<Float>) -> SIMD4<Float>) -> Image {
            Image(width: width, height: height) { x, y in f(x, y, self[x, y]) }
        }
    }

    // MARK: References

    /// Pixels whose centers lie inside `frame` (inclusive bounds), kept inside a `width x height` image.
    static func pixelRect(_ frame: Frame, width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        GPUFilterPlan.pixelRect(origin: frame.origin, size: frame.size, width: width, height: height)
    }

    /// p + amount * (p - mean of the 3 x 3 neighborhood); color never negative, alpha 0...1. Inside the picture (`frame`,
    /// nil = the whole image) the neighborhood is clamped to the picture, so its edge is not sharpened against the
    /// transparent padding; outside it (a blur's halo) to the image.
    public static func sharpen(_ img: Image, amount: Float, frame: Frame? = nil) -> Image {
        let whole = Frame(center: SIMD2(Float(img.width), Float(img.height)) / 2, size: SIMD2(Float(img.width), Float(img.height)))
        let r = pixelRect(frame ?? whole, width: img.width, height: img.height)
        return img.map { x, y, p in
            let inside = x >= r.minX && x <= r.maxX && y >= r.minY && y <= r.maxY
            let lo = inside ? SIMD2(r.minX, r.minY) : SIMD2(0, 0)
            let hi = inside ? SIMD2(r.maxX, r.maxY) : SIMD2(img.width - 1, img.height - 1)
            var box = SIMD4<Float>.zero
            for j in -1...1 { for i in -1...1 { box += img[min(max(x + i, lo.x), hi.x), min(max(y + j, lo.y), hi.y)] } }
            box /= 9
            var o = p + amount * (p - box)
            o = simd_max(o, .zero); o.w = min(o.w, 1)
            return o
        }
    }

    /// p + amount * (p - Gaussian blur) where the largest channel difference exceeds `threshold`. Inside the picture
    /// (`frame`, nil = the whole image) the blur repeats the picture's edge pixels; the padding outside stays as it is.
    /// `sigma` is clamped to `GaussianBlur.maxDirectSigma` like the GPU path.
    public static func unsharpMask(_ img: Image, sigma: Float, amount: Float, threshold: Float, frame: Frame? = nil) -> Image {
        guard amount != 0, sigma > 0 else { return img }
        let whole = Frame(center: SIMD2(Float(img.width), Float(img.height)) / 2, size: SIMD2(Float(img.width), Float(img.height)))
        let r = pixelRect(frame ?? whole, width: img.width, height: img.height)
        guard r.maxX >= r.minX, r.maxY >= r.minY else { return img }
        let cw = r.maxX - r.minX + 1, ch = r.maxY - r.minY + 1
        var crop: [SIMD4<Float>] = []
        for y in r.minY...r.maxY { for x in r.minX...r.maxX { crop.append(img[x, y]) } }
        let blurred = GaussianBlur.blur(crop, width: cw, height: ch, sigma: min(sigma, Float(GaussianBlur.maxDirectSigma)),
                                        repeatEdges: true)
        return img.map { x, y, p in
            guard x >= r.minX, x <= r.maxX, y >= r.minY, y <= r.maxY else { return p }
            let d = p - blurred[(y - r.minY) * cw + (x - r.minX)]
            guard max(abs(d.x), abs(d.y), abs(d.z)) > threshold else { return p }
            var o = p + amount * d
            o = simd_max(o, .zero); o.w = min(o.w, 1)
            return o
        }
    }

    /// Taps along the smear: about one per px, at least 2, at most 512. Above `onePassTaps` rounded up to a product a x b
    /// (a = ceil(sqrt n)), so the GPU runs it as two comb passes with exactly the same taps (`smearPasses`).
    static func smearTaps(_ d: SIMD2<Float>) -> Int { GPUFilterPlan.smearTaps(d) }

    static let onePassTaps = GPUFilterPlan.onePassTaps

    /// Two comb passes for `n` taps (fine: a taps one spacing apart; coarse: b taps a spacings apart), or nil for one pass.
    static func smearPasses(_ n: Int) -> (fine: Int, coarse: Int)? { GPUFilterPlan.smearPasses(n) }

    /// Average of `smearTaps` bilinear taps evenly spread over `d` (texture px), centered on each pixel.
    public static func directionalBlur(_ img: Image, d: SIMD2<Float>) -> Image {
        let n = smearTaps(d)
        return img.map { x, y, _ in
            let c = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
            var acc = SIMD4<Float>.zero
            for k in 0..<n { acc += img.sample(c + d * (Float(k) / Float(n - 1) - 0.5)) }
            return acc / Float(n)
        }
    }

    /// Unit normal of the reflection line: pixels on its side show their mirror image from the other side.
    static func mirrorNormal(_ degrees: Double) -> SIMD2<Float> {
        let a = degrees * .pi / 180
        return SIMD2(Float(cos(a)), Float(sin(a)))
    }

    /// `center` in texture px.
    public static func mirror(_ img: Image, center: SIMD2<Float>, degrees: Double) -> Image {
        let n = mirrorNormal(degrees)
        return img.map { x, y, p in
            let q = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
            let d = simd_dot(q - center, n)
            return d > 0 ? img.sample(q - 2 * d * n) : p
        }
    }

    /// Integer hash shared with the kernel (PCG output step): uniform 0...1.
    static func hash01(_ x: UInt32, _ y: UInt32, _ seed: UInt32, _ ch: UInt32) -> Float {
        var h = x &* 1_973 &+ y &* 9_277 &+ seed &* 26_699 &+ ch &* 104_729
        h = h &* 747_796_405 &+ 2_891_336_453
        var w = ((h >> ((h >> 28) &+ 4)) ^ h) &* 277_803_737
        w = (w >> 22) ^ w
        return Float(w >> 8) / Float(1 << 24)
    }

    /// Adds `amount * (u - 0.5) * alpha` per channel (one u for all three without color noise); `clip` keeps
    /// 0...max(1, input) (premultiplied: max(alpha, input)), so HDR highlights are not capped; otherwise only negatives are cut.
    public static func noise(_ img: Image, amount: Float, color: Bool, clip: Bool, seed: UInt32) -> Image {
        img.map { x, y, p in
            var o = p
            for c in 0..<3 {
                let u = hash01(UInt32(x), UInt32(y), seed, color ? UInt32(c) : 0) - 0.5
                o[c] = p[c] + amount * u * p.w
                o[c] = clip ? min(max(o[c], 0), max(p.w, p[c])) : max(o[c], 0)
            }
            return o
        }
    }

    /// Bright pass of Glow: share of the pixel above `threshold` (luma of the un-premultiplied color), tinted when asked.
    static func glowBright(_ p: SIMD4<Float>, threshold: Float, tint: SIMD3<Float>?) -> SIMD4<Float> {
        guard p.w > 0 else { return .zero }
        let c = SIMD3(p.x, p.y, p.z) / p.w
        let luma = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
        let w = min(max((luma - threshold) / max(1 - threshold, 1e-3), 0), 1)
        if let tint { return SIMD4(tint * p.w, p.w) * w }
        return p * w
    }

    /// Picture plus `intensity` times the blurred bright pass; alpha grows where the glow reaches past the picture.
    static func glowAdd(_ p: SIMD4<Float>, _ g: SIMD4<Float>, intensity: Float) -> SIMD4<Float> {
        let s = g * intensity
        return SIMD4(p.x + s.x, p.y + s.y, p.z + s.z, min(1, p.w + s.w * (1 - p.w)))
    }

    /// `tint` working-linear.
    public static func glow(_ img: Image, threshold: Float, sigma: Float, intensity: Float, tint: SIMD3<Float>?) -> Image {
        let bright = img.map { _, _, p in glowBright(p, threshold: threshold, tint: tint) }
        let blurred = GaussianBlur.blur(bright.px, width: img.width, height: img.height, sigma: sigma)
        return img.map { x, y, p in glowAdd(p, blurred[y * img.width + x], intensity: intensity) }
    }

    /// Pixels [start, end) whose centers fall in block `b` of size `bs` starting at `o`, inside 0...limit.
    static func blockRange(_ o: Float, _ bs: Float, _ b: Int, limit: Int) -> (Int, Int) {
        let s = Int((o + Float(b) * bs - 0.5).rounded(.up)), e = Int((o + Float(b + 1) * bs - 0.5).rounded(.up))
        return (min(max(s, 0), limit), min(max(e, 0), limit))
    }

    /// Block colors, row-major `columns x rows`: the exact mean of the pixels whose centers fall in each block (row means,
    /// then their mean, as the GPU does); a block holding no pixel center (smaller than a pixel) or Sharp Colors takes the
    /// pixel under its center.
    public static func mosaicBlocks(_ img: Image, frame: Frame, columns: Int, rows: Int, sharp: Bool) -> [SIMD4<Float>] {
        let bw = frame.size.x / Float(columns), bh = frame.size.y / Float(rows), o = frame.origin
        var out: [SIMD4<Float>] = []
        for by in 0..<rows {
            for bx in 0..<columns {
                let (x0, x1) = blockRange(o.x, bw, bx, limit: img.width), (y0, y1) = blockRange(o.y, bh, by, limit: img.height)
                if sharp || x1 <= x0 || y1 <= y0 {
                    out.append(img[Int(floor(o.x + (Float(bx) + 0.5) * bw)), Int(floor(o.y + (Float(by) + 0.5) * bh))])
                    continue
                }
                var acc = SIMD4<Float>.zero
                for y in y0..<y1 {
                    var row = SIMD4<Float>.zero
                    for x in x0..<x1 { row += img[x, y] }
                    acc += row / Float(x1 - x0)
                }
                out.append(acc / Float(y1 - y0))
            }
        }
        return out
    }

    /// Inside the frame every pixel takes its block's color; outside it (a blur's halo) the picture is kept.
    public static func mosaic(_ img: Image, frame: Frame, columns: Int, rows: Int, sharp: Bool) -> Image {
        let blocks = mosaicBlocks(img, frame: frame, columns: columns, rows: rows, sharp: sharp)
        let bw = frame.size.x / Float(columns), bh = frame.size.y / Float(rows), o = frame.origin
        return img.map { x, y, p in
            let q = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - o
            guard q.x >= 0, q.y >= 0, q.x < frame.size.x, q.y < frame.size.y else { return p }
            let bx = min(columns - 1, Int(q.x / bw)), by = min(rows - 1, Int(q.y / bh))
            return blocks[by * columns + bx]
        }
    }

    /// Mirrors `FilterU` (96 bytes; the block every SQGPU filter kernel takes).
    typealias Uniforms = GPUFilterUniforms
}
