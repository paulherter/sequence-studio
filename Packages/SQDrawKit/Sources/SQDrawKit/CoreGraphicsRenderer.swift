#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// The Mac backend of the Canvas: replays a `DrawList` into a CGContext, so the shared toolkit code (shell, panels)
/// draws inside an AppKit view as it draws through D3D12 on Windows. Same quad meaning as `SoftwareRenderer` and the
/// quad shader: rounded rects (filled or stroked inward), atlas glyphs tinted, triangles, round-capped segments, the
/// picture and image slots. The context must be in DrawList pixels with a top-left origin (a flipped view's context
/// scaled by 1/scale, or a bitmap context flipped with `flipped(_:height:)`).
public enum CoreGraphicsRenderer {
    /// Flips a bottom-left bitmap context to the DrawList's top-left pixel space.
    public static func flipped(_ ctx: CGContext, height: Int) {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }

    /// The atlas as a CG image mask (one byte per texel, coverage 255 paints), rows stored bottom-up so a glyph cell
    /// drawn into the top-left DrawList space lands upright without a flip per glyph; build once per atlas generation.
    public static func mask(_ atlas: GlyphAtlas) -> CGImage? {
        let n = atlas.size
        var rows = [UInt8](repeating: 0, count: n * n)
        atlas.pixels.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { dst in
                for y in 0..<n {
                    let from = src.baseAddress! + y * n, to = dst.baseAddress! + (n - 1 - y) * n
                    to.update(from: from, count: n)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rows) as CFData) else { return nil }
        // Image masks paint where the sample is 0; the decode array turns coverage 255 into paint.
        return CGImage(maskWidth: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, provider: provider,
                       decode: [1, 0], shouldInterpolate: false)
    }

    /// Draws `list` into `ctx`. `glyphs` is `mask(atlas)`; `video` the picture slot, `images` the image slots.
    /// `punchesVideo`: without a `video` image the picture quad is cleared to transparent (a GPU layer under the context
    /// shows through, everything drawn after the quad stays on top), not filled black.
    public static func draw(_ list: DrawList, in ctx: CGContext, glyphs: CGImage?, video: CGImage? = nil,
                            images: [Int: CGImage] = [:], punchesVideo: Bool = false) {
        var state = State(cells: glyphs.map(GlyphCells.cells))
        for q in list.quads { draw(q, ctx, &state, glyphs, video, images, punchesVideo) }
    }

    /// Per draw call: the fill color last set (most quads in a row share it) and the atlas cells.
    private struct State {
        var cells: GlyphCells?
        var color: DrawColor?
        var last: (DrawColor, CGColor)?
        mutating func fill(_ c: DrawColor, _ ctx: CGContext) {
            guard c != color else { return }
            color = c
            ctx.setFillColor(cgColor(c))
        }
        /// One CGColor per color run (a new CGColor per quad showed in the profile).
        mutating func cgColor(_ c: DrawColor) -> CGColor {
            if let l = last, l.0 == c { return l.1 }
            let made = cg(c)
            last = (c, made)
            return made
        }
    }

    /// An RGBA render of `list` (sRGB, opaque `clear` background): the Mac counterpart of `SoftwareRenderer.render`.
    public static func render(_ list: DrawList, width: Int, height: Int, clear: DrawColor, atlas: GlyphAtlas?) -> RGBAImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(cg(clear.alpha(1)))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        flipped(ctx, height: height)
        draw(list, in: ctx, glyphs: atlas.flatMap(mask))
        guard let base = ctx.data else { return nil }
        let pixels = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Pixel area from which a rounded fill is split into plain rects and four clipped corners.
    static let bigRoundedArea: Float = 64 * 64

    /// A large rounded fill (panels, dialog shadow layers): the antialiased path fill costs per covered pixel, a plain
    /// rect fill far less. The inner cuts lie on whole pixels, so the pieces meet without a seam even when translucent.
    private static func fillBigRounded(_ rect: CGRect, radius r: CGFloat, visible: CGRect, _ c: DrawColor, _ ctx: CGContext,
                                       _ state: inout State) {
        let x0 = (rect.minX + r).rounded(.up), x1 = (rect.maxX - r).rounded(.down)
        let y0 = (rect.minY + r).rounded(.up), y1 = (rect.maxY - r).rounded(.down)
        state.fill(c, ctx)
        guard x1 > x0, y1 > y0 else {
            let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.saveGState(); ctx.clip(to: visible); ctx.addPath(path); ctx.fillPath(); ctx.restoreGState()
            state.color = nil
            return
        }
        for piece in [CGRect(x: rect.minX, y: y0, width: rect.width, height: y1 - y0),
                      CGRect(x: x0, y: rect.minY, width: x1 - x0, height: y0 - rect.minY),
                      CGRect(x: x0, y: y1, width: x1 - x0, height: rect.maxY - y1)] {
            let v = piece.intersection(visible)
            if !v.isNull, v.width > 0, v.height > 0 { ctx.fill(v) }
        }
        let corners = [CGRect(x: rect.minX, y: rect.minY, width: x0 - rect.minX, height: y0 - rect.minY),
                       CGRect(x: x1, y: rect.minY, width: rect.maxX - x1, height: y0 - rect.minY),
                       CGRect(x: rect.minX, y: y1, width: x0 - rect.minX, height: rect.maxY - y1),
                       CGRect(x: x1, y: y1, width: rect.maxX - x1, height: rect.maxY - y1)]
        for corner in corners {
            let v = corner.intersection(visible)
            guard !v.isNull, v.width > 0, v.height > 0 else { continue }
            // The arc's own small rounded rect: the corner square grown to twice the radius plus the whole-pixel slack, the same arc.
            let d = r * 2 + 2
            let own = CGRect(x: corner.minX == rect.minX ? rect.minX : rect.maxX - d,
                             y: corner.minY == rect.minY ? rect.minY : rect.maxY - d, width: d, height: d)
            ctx.saveGState()
            ctx.clip(to: v)
            ctx.addPath(CGPath(roundedRect: own, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        state.color = nil
    }

    static func cg(_ c: DrawColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    private static func draw(_ q: DrawQuad, _ ctx: CGContext, _ state: inout State, _ glyphs: CGImage?, _ video: CGImage?,
                             _ images: [Int: CGImage], _ punches: Bool) {
        let rect = CGRect(x: CGFloat(q.x), y: CGFloat(q.y), width: CGFloat(q.w), height: CGFloat(q.h))
        let clip = CGRect(x: CGFloat(q.clipX0), y: CGFloat(q.clipY0), width: CGFloat(q.clipX1 - q.clipX0),
                          height: CGFloat(q.clipY1 - q.clipY0))
        let kind = DrawQuad.Kind(rawValue: q.kind) ?? .shape
        // A segment's quad is its bounds; every other kind draws inside its quad.
        let visible = clip.intersection(rect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        // Most quads lie inside their clip: those skip the graphics state save and the clip (the bulk of the CPU time).
        let clips = visible != rect
        switch kind {
        case .shape where q.radius <= 0 && q.stroke <= 0:
            state.fill(q.color, ctx)
            ctx.fill(visible)
            return
        case .shape where q.stroke <= 0 && q.w * q.h >= bigRoundedArea && q.radius > 0:
            fillBigRounded(rect, radius: CGFloat(min(q.radius, min(q.w, q.h) / 2)), visible: visible, q.color, ctx, &state)
            return
        case .segment where q.stroke <= 2 && (q.u0 == q.u1 || q.v0 == q.v1):
            // A thin axis line: its round caps are a sub-pixel detail, a rect over the line plus half the width at each end.
            let hw = CGFloat(q.stroke) / 2
            let line = CGRect(x: CGFloat(min(q.u0, q.u1)) - hw, y: CGFloat(min(q.v0, q.v1)) - hw,
                              width: CGFloat(abs(q.u1 - q.u0)) + hw * 2, height: CGFloat(abs(q.v1 - q.v0)) + hw * 2)
            let cut = line.intersection(clip)
            guard !cut.isNull, cut.width > 0, cut.height > 0 else { return }
            state.fill(q.color, ctx)
            ctx.fill(cut)
            return
        case .glyph where !clips:
            guard let cell = state.cells?.cell(q) else { return }
            state.fill(q.color, ctx)
            ctx.draw(cell, in: rect)
            return
        default: break
        }
        ctx.saveGState()
        defer { ctx.restoreGState(); state.color = nil }
        if clips { ctx.clip(to: visible) }
        state.color = nil
        state.fill(q.color, ctx)
        switch kind {
        case .shape:
            let r = CGFloat(min(q.radius, min(q.w, q.h) / 2))
            let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            if q.stroke > 0, q.stroke * 2 < min(q.w, q.h) {
                let s = CGFloat(q.stroke)
                let inner = rect.insetBy(dx: s, dy: s)
                let ir = max(r - s, 0)
                let ring = CGMutablePath()
                ring.addPath(path)
                ring.addPath(CGPath(roundedRect: inner, cornerWidth: ir, cornerHeight: ir, transform: nil))
                ctx.addPath(ring)
                ctx.fillPath(using: .evenOdd)
            } else {
                ctx.addPath(path)
                ctx.fillPath()
            }
        case .glyph:
            guard let cell = state.cells?.cell(q) else { return }
            ctx.draw(cell, in: rect)
        case .triangle:
            let left = q.u0 > 0.5
            ctx.move(to: CGPoint(x: left ? rect.maxX : rect.minX, y: rect.minY))
            ctx.addLine(to: CGPoint(x: left ? rect.minX : rect.maxX, y: rect.midY))
            ctx.addLine(to: CGPoint(x: left ? rect.maxX : rect.minX, y: rect.maxY))
            ctx.closePath()
            ctx.fillPath()
        case .segment:
            ctx.setStrokeColor(state.cgColor(q.color))
            ctx.setLineWidth(CGFloat(q.stroke))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: CGFloat(q.u0), y: CGFloat(q.v0)))
            ctx.addLine(to: CGPoint(x: CGFloat(q.u1), y: CGFloat(q.v1)))
            ctx.strokePath()
        case .video, .image:
            let img = kind == .video ? video : images[Int(q.pad)]
            guard let img else {
                if kind == .video, punches { ctx.clear(rect) } else if kind == .video { ctx.setFillColor(cg(.black)); ctx.fill(rect) }
                return
            }
            // uv picks the source part; draw the whole image scaled so that part lands on the quad.
            let du = CGFloat(q.u1 - q.u0), dv = CGFloat(q.v1 - q.v0)
            guard du != 0, dv != 0 else { return }
            let full = CGRect(x: rect.minX - CGFloat(q.u0) / du * rect.width, y: rect.minY - CGFloat(q.v0) / dv * rect.height,
                              width: rect.width / du, height: rect.height / dv)
            ctx.translateBy(x: 0, y: full.minY * 2 + full.height)
            ctx.scaleBy(x: 1, y: -1)
            if kind == .image { ctx.setAlpha(CGFloat(q.a)) }
            ctx.draw(img, in: full)
        }
    }
}

/// Cropped atlas cells by atlas position and size, one table per mask image (a new atlas generation is a new image).
/// Cropping per glyph per frame was a third of the redraw.
final class GlyphCells: @unchecked Sendable {
    private let image: CGImage
    private let lock = NSLock()
    private var table: [Int64: CGImage] = [:]
    private init(_ image: CGImage) { self.image = image }

    nonisolated(unsafe) private static var last: GlyphCells?
    private static let lastLock = NSLock()
    /// The table of `image` (kept while the same mask is drawn).
    static func cells(_ image: CGImage) -> GlyphCells {
        lastLock.lock(); defer { lastLock.unlock() }
        if let l = last, l.image === image { return l }
        let c = GlyphCells(image)
        last = c
        return c
    }

    func cell(_ q: DrawQuad) -> CGImage? {
        let n = image.height, x = Int(q.u0), w = Int(q.w.rounded()), h = Int(q.h.rounded())
        let y = n - Int(q.v0) - h                  // rows are stored bottom-up
        guard w > 0, h > 0, x >= 0, y >= 0 else { return nil }
        let key = Int64(x) | Int64(y) << 16 | Int64(w) << 32 | Int64(h) << 48
        lock.lock(); defer { lock.unlock() }
        if let c = table[key] { return c }
        guard let c = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }
        table[key] = c
        return c
    }
}
#endif
