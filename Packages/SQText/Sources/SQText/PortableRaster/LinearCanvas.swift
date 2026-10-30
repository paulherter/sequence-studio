import Foundation

/// CPU drawing for the portable text raster (Windows, Linux; on the Mac only the parity tests use it): coverage masks
/// from polygons, round strokes, Gaussian blur and source-over compositing in linear light, premultiplied, y down.
/// Coverage is applied in linear light like the Mac's Core Graphics linear-sRGB context, so edges match.
struct LinearCanvas {
    let width: Int, height: Int
    /// RGBA per pixel, premultiplied, linear light (sRGB primaries), rows top to bottom.
    var pixels: [Float]

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [Float](repeating: 0, count: width * height * 4)
    }

    /// Source-over of a solid premultiplied color through `mask`.
    mutating func fill(_ mask: [Float], color c: SIMD4<Float>) {
        guard c.w > 0 else { return }
        for i in 0..<(width * height) where mask[i] > 0 { blend(i, c * mask[i]) }
    }

    /// Source-over of a per-pixel premultiplied color through `mask`.
    mutating func fill(_ mask: [Float], color: (Int, Int) -> SIMD4<Float>) {
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if mask[i] > 0 { blend(i, color(x, y) * mask[i]) }
            }
        }
    }

    /// `self` over `below` (the result replaces `self`).
    mutating func place(over below: LinearCanvas) {
        for i in 0..<(width * height) {
            let a = pixels[i * 4 + 3]
            for k in 0..<4 { pixels[i * 4 + k] += below.pixels[i * 4 + k] * (1 - a) }
        }
    }

    var alpha: [Float] { (0..<(width * height)).map { pixels[$0 * 4 + 3] } }

    private mutating func blend(_ i: Int, _ s: SIMD4<Float>) {
        let k = i * 4, keep = 1 - s.w
        pixels[k] = s.x + pixels[k] * keep
        pixels[k + 1] = s.y + pixels[k + 1] * keep
        pixels[k + 2] = s.z + pixels[k + 2] * keep
        pixels[k + 3] = s.w + pixels[k + 3] * keep
    }

    /// An sRGB color (straight alpha) as premultiplied linear light.
    static func linear(_ c: RGBAColor) -> SIMD4<Float> {
        let a = Float(c.alpha)
        return SIMD4(toLinear(c.red) * a, toLinear(c.green) * a, toLinear(c.blue) * a, a)
    }

    static func toLinear(_ v: Double) -> Float {
        Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }
}

/// Closed polygons in pixels (y down) to a nonzero coverage mask. Overlapping polygons of the same winding are a union
/// (the summed coverage is clamped at 1), so strokes are built from same-wound pieces.
struct PolygonMask {
    let width: Int, height: Int
    private var raster: CoverageRasterizer

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        raster = CoverageRasterizer(width: width, height: height)
    }

    /// One closed polygon (the closing edge is added).
    mutating func add(_ points: [SIMD2<Double>]) {
        guard points.count > 2 else { return }
        for i in points.indices { edge(points[i], points[(i + 1) % points.count]) }
    }

    /// Adds `points` wound so that their signed area is positive (for unions).
    mutating func addPositive(_ points: [SIMD2<Double>]) {
        add(Self.signedArea(points) < 0 ? points.reversed() : points)
    }

    /// The accumulation buffer spills a column left of 0 or right of `width` into the neighboring row, so every edge is
    /// cut at both sides and the parts outside are laid on the border (which keeps the area right of them covered).
    private mutating func edge(_ a: SIMD2<Double>, _ b: SIMD2<Double>) {
        let w = Double(width)
        var cuts: [Double] = [0, 1]
        if b.x != a.x {
            for xc in [0, w] {
                let t = (xc - a.x) / (b.x - a.x)
                if t > 0 && t < 1 { cuts.append(t) }
            }
        }
        cuts.sort()
        for k in 0..<(cuts.count - 1) {
            let p = a + (b - a) * cuts[k], q = a + (b - a) * cuts[k + 1]
            raster.line(Float(min(max(p.x, 0), w)), Float(p.y), Float(min(max(q.x, 0), w)), Float(q.y))
        }
    }

    func mask() -> [Float] { raster.coverageValues() }

    static func signedArea(_ p: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }

    /// A circle as a polygon fine enough at radius `r` pixels.
    static func disc(_ c: SIMD2<Double>, _ r: Double) -> [SIMD2<Double>] {
        let n = max(8, min(96, Int((r * 2).rounded(.up))))
        return (0..<n).map { k in
            let t = Double(k) / Double(n) * 2 * .pi
            return c + SIMD2(cos(t), sin(t)) * r
        }
    }

    /// A round-joined, round-capped stroke of half width `r` along closed polylines: one rectangle per edge and one disc
    /// per vertex, all wound the same way (the union is what Core Graphics strokes with round joins).
    mutating func stroke(_ polylines: [[SIMD2<Double>]], halfWidth r: Double) {
        guard r > 0 else { return }
        for line in polylines where line.count > 1 {
            for i in line.indices {
                let a = line[i], b = line[(i + 1) % line.count]
                addPositive(Self.disc(a, r))
                let d = b - a, len = (d * d).sum().squareRoot()
                guard len > 1e-9 else { continue }
                let n = SIMD2(-d.y, d.x) / len * r
                addPositive([a + n, b + n, b - n, a - n])
            }
        }
    }

    /// A rounded rectangle (radius clamped to half the shorter side).
    static func roundedRect(x: Double, y: Double, width w: Double, height h: Double, radius: Double) -> [SIMD2<Double>] {
        let r = min(max(radius, 0), min(w, h) / 2)
        guard r > 0 else { return [SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h)] }
        let n = max(4, min(32, Int(r.rounded(.up))))
        var out: [SIMD2<Double>] = []
        let corners = [(SIMD2(x + w - r, y + r), -Double.pi / 2), (SIMD2(x + w - r, y + h - r), 0.0),
                       (SIMD2(x + r, y + h - r), Double.pi / 2), (SIMD2(x + r, y + r), Double.pi)]
        for (c, start) in corners {
            for k in 0...n {
                let t = start + Double(k) / Double(n) * .pi / 2
                out.append(c + SIMD2(cos(t), sin(t)) * r)
            }
        }
        return out
    }
}

enum MaskOps {
    /// Pixelwise union of two masks (clamped sum: both come from the same shapes' parts).
    static func union(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { min(1, $0 + $1) } }

    /// Separable Gaussian blur, sigma in pixels, zero outside.
    static func blur(_ m: [Float], width w: Int, height h: Int, sigma: Double) -> [Float] {
        guard sigma > 0.05, w > 0, h > 0 else { return m }
        let radius = Int((sigma * 3).rounded(.up))
        var k = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = k.reduce(0, +)
        k = k.map { $0 / total }
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for j in -radius...radius { let xx = x + j; if xx >= 0 && xx < w { s += m[y * w + xx] * k[j + radius] } }
                tmp[y * w + x] = s
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for j in -radius...radius { let yy = y + j; if yy >= 0 && yy < h { s += tmp[yy * w + x] * k[j + radius] } }
                out[y * w + x] = s
            }
        }
        return out
    }

    /// `m` moved by (dx, dy) pixels (bilinear for fractional offsets), zero where nothing moves in.
    static func shift(_ m: [Float], width w: Int, height h: Int, dx: Double, dy: Double) -> [Float] {
        guard dx != 0 || dy != 0 else { return m }
        var out = [Float](repeating: 0, count: w * h)
        let fx = dx.rounded(.down), fy = dy.rounded(.down)
        let tx = Float(dx - fx), ty = Float(dy - fy), ix = Int(fx), iy = Int(fy)
        func at(_ x: Int, _ y: Int) -> Float { x >= 0 && x < w && y >= 0 && y < h ? m[y * w + x] : 0 }
        for y in 0..<h {
            for x in 0..<w {
                let sx = x - ix, sy = y - iy
                let top = at(sx, sy) * (1 - tx) + at(sx - 1, sy) * tx
                let bottom = at(sx, sy - 1) * (1 - tx) + at(sx - 1, sy - 1) * tx
                out[y * w + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }
}
