import Foundation

/// An 8-bit RGBA image, rows top to bottom (alpha is 255 for rendered frames).
public struct RGBAImage: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }
    public init(width: Int, height: Int, fill c: DrawColor) {
        self.width = width; self.height = height
        let px = [UInt8(c.r * 255 + 0.5), UInt8(c.g * 255 + 0.5), UInt8(c.b * 255 + 0.5), 255]
        pixels = Array([[UInt8]](repeating: px, count: width * height).joined())
    }
}

/// The reference rasterizer of a `DrawList`: the same per-pixel math as the D3D12 quad shader (CSQWinApp `ui.hlsl`):
/// coverage at pixel centers from a rounded-rect distance, glyph texels read 1:1, the picture sampled bilinear, then
/// `src * a + dst * (1 - a)` in sRGB values. Used for the Mac comparison screenshots and as a test oracle.
public enum SoftwareRenderer {
    public static func render(_ list: DrawList, width: Int, height: Int, clear: DrawColor, atlas: GlyphAtlas?,
                              video: RGBAImage? = nil, images: [Int: RGBAImage] = [:]) -> RGBAImage {
        var buf = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { buf[i * 3] = clear.r; buf[i * 3 + 1] = clear.g; buf[i * 3 + 2] = clear.b }
        for q in list.quads { draw(q, &buf, width, height, atlas, video, images) }
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 { out[i * 4 + c] = UInt8(min(max(buf[i * 3 + c], 0), 1) * 255 + 0.5) }
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }

    /// Coverage of a rounded box (half size `hx, hy`, radius `r`) at offset `cx, cy` from its center.
    @inline(__always) static func roundBox(_ cx: Float, _ cy: Float, _ hx: Float, _ hy: Float, _ r: Float) -> Float {
        let qx = abs(cx) - hx + r, qy = abs(cy) - hy + r
        let mx = max(qx, 0), my = max(qy, 0)
        let d = (mx * mx + my * my).squareRoot() + min(max(qx, qy), 0) - r
        return min(max(0.5 - d, 0), 1)
    }

    /// The shader's per-quad coverage and color at pixel center (px, py); nil = untouched.
    static func shade(_ q: DrawQuad, _ px: Float, _ py: Float, _ atlas: GlyphAtlas?, _ video: RGBAImage?,
                      _ images: [Int: RGBAImage] = [:]) -> (Float, Float, Float, Float)? {
        let lx = px - q.x, ly = py - q.y
        switch DrawQuad.Kind(rawValue: q.kind) ?? .shape {
        case .shape:
            let hx = q.w / 2, hy = q.h / 2
            let r = min(q.radius, min(hx, hy))
            var cov = roundBox(lx - hx, ly - hy, hx, hy, r)
            if q.stroke > 0 {
                let ix = hx - q.stroke, iy = hy - q.stroke
                if ix > 0 && iy > 0 { cov -= roundBox(lx - hx, ly - hy, ix, iy, max(r - q.stroke, 0)) }
            }
            return (q.r, q.g, q.b, q.a * max(cov, 0))
        case .glyph:
            guard let atlas, lx >= 0, ly >= 0, lx < q.w, ly < q.h else { return nil }
            let tx = Int(q.u0) + Int(lx), ty = Int(q.v0) + Int(ly)
            let t = Float(atlas.pixels[ty * atlas.size + tx]) / 255
            return (q.r, q.g, q.b, q.a * t)
        case .video:
            guard let video else { return (0, 0, 0, 1) }
            let u = q.u0 + (q.u1 - q.u0) * lx / q.w, v = q.v0 + (q.v1 - q.v0) * ly / q.h
            let c = bilinear(video, u, v)
            return (c.0, c.1, c.2, 1)
        case .triangle:
            // Pointing right: left edge, then the two slanted edges toward (w, h/2). Left-pointing mirrors x.
            let lx = q.u0 > 0.5 ? q.w - lx : lx
            let n = (q.w * q.w + q.h * q.h / 4).squareRoot()
            let dTop = (ly * q.w - lx * q.h / 2) / n
            let dBottom = ((q.h - ly) * q.w - lx * q.h / 2) / n
            let cov = min(max(min(lx, min(dTop, dBottom)) + 0.5, 0), 1)
            return (q.r, q.g, q.b, q.a * cov)
        case .image:
            guard let img = images[Int(q.pad)] else { return nil }
            let u = q.u0 + (q.u1 - q.u0) * lx / q.w, v = q.v0 + (q.v1 - q.v0) * ly / q.h
            let c = bilinear(img, u, v), a = bilinearAlpha(img, u, v)
            return (q.r * c.0, q.g * c.1, q.b * c.2, q.a * a)
        case .segment:
            return (q.r, q.g, q.b, q.a * segmentCoverage(px, py, q.u0, q.v0, q.u1, q.v1, q.stroke))
        }
    }

    /// Coverage of a round-capped line (end points in pixels, `width` thick) at pixel center (px, py).
    @inline(__always) static func segmentCoverage(_ px: Float, _ py: Float, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
                                                  _ width: Float) -> Float {
        let dx = x1 - x0, dy = y1 - y0
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? min(max(((px - x0) * dx + (py - y0) * dy) / len2, 0), 1) : 0
        let ex = px - (x0 + dx * t), ey = py - (y0 + dy * t)
        return min(max(width / 2 + 0.5 - (ex * ex + ey * ey).squareRoot(), 0), 1)
    }

    /// Bilinear sample at normalized (u, v) with texel centers at (i + 0.5) / size, edges clamped (D3D12 sampler).
    static func bilinear(_ img: RGBAImage, _ u: Float, _ v: Float) -> (Float, Float, Float) {
        let fx = u * Float(img.width) - 0.5, fy = v * Float(img.height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let ax = fx - Float(x0), ay = fy - Float(y0)
        func px(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let cx = min(max(x, 0), img.width - 1), cy = min(max(y, 0), img.height - 1)
            return Float(img.pixels[(cy * img.width + cx) * 4 + c]) / 255
        }
        func ch(_ c: Int) -> Float {
            let top = px(x0, y0, c) * (1 - ax) + px(x0 + 1, y0, c) * ax
            let bottom = px(x0, y0 + 1, c) * (1 - ax) + px(x0 + 1, y0 + 1, c) * ax
            return top * (1 - ay) + bottom * ay
        }
        return (ch(0), ch(1), ch(2))
    }

    /// The alpha channel of `bilinear`.
    static func bilinearAlpha(_ img: RGBAImage, _ u: Float, _ v: Float) -> Float {
        let fx = u * Float(img.width) - 0.5, fy = v * Float(img.height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let ax = fx - Float(x0), ay = fy - Float(y0)
        func px(_ x: Int, _ y: Int) -> Float {
            let cx = min(max(x, 0), img.width - 1), cy = min(max(y, 0), img.height - 1)
            return Float(img.pixels[(cy * img.width + cx) * 4 + 3]) / 255
        }
        let top = px(x0, y0) * (1 - ax) + px(x0 + 1, y0) * ax
        let bottom = px(x0, y0 + 1) * (1 - ax) + px(x0 + 1, y0 + 1) * ax
        return top * (1 - ay) + bottom * ay
    }

    private static func draw(_ q: DrawQuad, _ buf: inout [Float], _ width: Int, _ height: Int, _ atlas: GlyphAtlas?,
                             _ video: RGBAImage?, _ images: [Int: RGBAImage]) {
        let x0 = max(0, Int(max(q.x, q.clipX0).rounded(.down))), y0 = max(0, Int(max(q.y, q.clipY0).rounded(.down)))
        let x1 = min(width, Int(min(q.x + q.w, q.clipX1).rounded(.up)))
        let y1 = min(height, Int(min(q.y + q.h, q.clipY1).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            let py = Float(y) + 0.5
            if py < q.clipY0 || py >= q.clipY1 || py < q.y || py >= q.y + q.h { continue }
            for x in x0..<x1 {
                let px = Float(x) + 0.5
                if px < q.clipX0 || px >= q.clipX1 || px < q.x || px >= q.x + q.w { continue }
                guard let (r, g, b, a) = shade(q, px, py, atlas, video, images), a > 0 else { continue }
                let i = (y * width + x) * 3
                buf[i] = r * a + buf[i] * (1 - a)
                buf[i + 1] = g * a + buf[i + 1] * (1 - a)
                buf[i + 2] = b * a + buf[i + 2] * (1 - a)
            }
        }
    }
}

/// Minimal PNG encoder (RGBA8, filter none, stored deflate blocks): portable, no image library.
public enum PNGWriter {
    public static func encode(_ img: RGBAImage) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((img.width * 4 + 1) * img.height)
        for y in 0..<img.height {
            raw.append(0)
            raw.append(contentsOf: img.pixels[(y * img.width * 4)..<((y + 1) * img.width * 4)])
        }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, raw.count - i)
            z.append(i + n == raw.count ? 1 : 0)
            z += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z.append(contentsOf: raw[i..<(i + n)])
            i += n
        } while i < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for v in raw { a = (a + UInt32(v)) % 65_521; b = (b + a) % 65_521 }
        z += be32((b << 16) | a)
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr = be32(UInt32(img.width)) + be32(UInt32(img.height))
        ihdr += [8, 6, 0, 0, 0]
        out += chunk("IHDR", ihdr) + chunk("IDAT", z) + chunk("IEND", [])
        return Data(out)
    }

    public static func write(_ img: RGBAImage, to url: URL) throws { try encode(img).write(to: url) }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        return be32(UInt32(data.count)) + t + data + be32(crc(t + data))
    }
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
