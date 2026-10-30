import Foundation

/// A straight-alpha sRGB color, components 0...1 (blended in sRGB like the Mac's device RGB contexts).
public struct DrawColor: Sendable, Equatable, Hashable {
    public var r, g, b, a: Float
    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Float = 1) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, alpha)
    }
    public func alpha(_ a: Float) -> DrawColor { DrawColor(r, g, b, a) }
    /// This color mixed toward white by `f` (the clip edge `Theme.lift`).
    public func lifted(_ f: Float) -> DrawColor { DrawColor(r + (1 - r) * f, g + (1 - g) * f, b + (1 - b) * f, a) }
    public static let white = DrawColor(1, 1, 1)
    public static let black = DrawColor(0, 0, 0)
    public static let clear = DrawColor(0, 0, 0, 0)
}

/// A rectangle in pixels, y down.
public struct DrawRect: Sendable, Equatable, Hashable {
    public var x, y, w, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
    public static let zero = DrawRect(x: 0, y: 0, w: 0, h: 0)
    public var maxX: Float { x + w }
    public var maxY: Float { y + h }
    public var midX: Float { x + w / 2 }
    public var midY: Float { y + h / 2 }
    public func contains(_ px: Float, _ py: Float) -> Bool { px >= x && py >= y && px < x + w && py < y + h }
    public func inset(_ d: Float) -> DrawRect { DrawRect(x: x + d, y: y + d, w: max(0, w - 2 * d), h: max(0, h - 2 * d)) }
    public func intersection(_ o: DrawRect) -> DrawRect {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return DrawRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }
    /// Splits off the top `h` (returns it) and keeps the rest.
    public mutating func sliceTop(_ v: Float) -> DrawRect {
        let t = DrawRect(x: x, y: y, w: w, h: min(v, h)); y += t.h; h -= t.h; return t
    }
    public mutating func sliceBottom(_ v: Float) -> DrawRect {
        let t = DrawRect(x: x, y: maxY - min(v, h), w: w, h: min(v, h)); h -= t.h; return t
    }
    public mutating func sliceLeft(_ v: Float) -> DrawRect {
        let t = DrawRect(x: x, y: y, w: min(v, w), h: h); x += t.w; w -= t.w; return t
    }
}

/// One GPU instance: every primitive is a quad (80 bytes, the layout of `SQQuad` in the D3D12 shim).
public struct DrawQuad: Sendable, Equatable {
    public enum Kind: Float, Sendable { case shape = 0, glyph = 1, video = 2, triangle = 3, segment = 4, image = 5 }
    public var x, y, w, h: Float
    /// Glyph: atlas texel origin (u0, v0). Video: normalized source rect (u0, v0)-(u1, v1).
    public var u0, v0, u1, v1: Float
    public var r, g, b, a: Float
    public var radius: Float
    /// 0 = filled; otherwise the width of an inside stroke.
    public var stroke: Float
    public var kind: Float
    /// Image quads: the image slot (0...5).
    public var pad: Float = 0
    public var clipX0, clipY0, clipX1, clipY1: Float

    public init(rect: DrawRect, uv: (Float, Float, Float, Float) = (0, 0, 0, 0), color: DrawColor, radius: Float = 0,
                stroke: Float = 0, kind: Kind = .shape, clip: DrawRect) {
        x = rect.x; y = rect.y; w = rect.w; h = rect.h
        (u0, v0, u1, v1) = uv
        r = color.r; g = color.g; b = color.b; a = color.a
        self.radius = radius; self.stroke = stroke; self.kind = kind.rawValue
        clipX0 = clip.x; clipY0 = clip.y; clipX1 = clip.maxX; clipY1 = clip.maxY
    }
    public var rect: DrawRect { DrawRect(x: x, y: y, w: w, h: h) }
    public var color: DrawColor { DrawColor(r, g, b, a) }
}

/// The frame's quads in painter's order, with a clip stack. Views fill it, a renderer draws it.
public struct DrawList: Sendable {
    public private(set) var quads: [DrawQuad] = []
    public private(set) var width: Float, height: Float
    private var clips: [DrawRect]

    public init(width: Float, height: Float) {
        self.width = width; self.height = height
        clips = [DrawRect(x: 0, y: 0, w: width, h: height)]
    }

    private init(width: Float, height: Float, quads: [DrawQuad]) {
        self.width = width; self.height = height
        self.quads = quads
        clips = [DrawRect(x: 0, y: 0, w: width, h: height)]
    }

    /// Grows the canvas to at least `width x height` (floating panels draw right of the window, in the same list). Call with
    /// no clip pushed; quads already in the list keep their clips.
    public mutating func extendCanvas(width w: Float, height h: Float) {
        width = max(width, w); height = max(height, h)
        clips = [DrawRect(x: 0, y: 0, w: width, h: height)]
    }

    /// The part of the list inside `r` as a list of its own, `r.w x r.h` pixels with `r`'s corner at the origin: what a
    /// window shows of the shared canvas. Quads outside are dropped, clips are cut to `r`, segment end points move with it.
    public func region(_ r: DrawRect) -> DrawList {
        var out: [DrawQuad] = []
        out.reserveCapacity(quads.count)
        let box = DrawRect(x: 0, y: 0, w: r.w, h: r.h)
        for var q in quads {
            let clip = DrawRect(x: q.clipX0 - r.x, y: q.clipY0 - r.y, w: q.clipX1 - q.clipX0, h: q.clipY1 - q.clipY0).intersection(box)
            guard clip.w > 0, clip.h > 0 else { continue }
            q.x -= r.x; q.y -= r.y
            if q.x >= clip.maxX || q.y >= clip.maxY || q.x + q.w <= clip.x || q.y + q.h <= clip.y { continue }
            if q.kind == DrawQuad.Kind.segment.rawValue { q.u0 -= r.x; q.v0 -= r.y; q.u1 -= r.x; q.v1 -= r.y }
            q.clipX0 = clip.x; q.clipY0 = clip.y; q.clipX1 = clip.maxX; q.clipY1 = clip.maxY
            out.append(q)
        }
        return DrawList(width: r.w, height: r.h, quads: out)
    }

    public var clip: DrawRect { clips[clips.count - 1] }
    public mutating func pushClip(_ r: DrawRect) { clips.append(clip.intersection(r)) }
    public mutating func popClip() { if clips.count > 1 { clips.removeLast() } }

    public mutating func fill(_ r: DrawRect, _ c: DrawColor, radius: Float = 0) {
        guard r.w > 0, r.h > 0, c.a > 0 else { return }
        quads.append(DrawQuad(rect: r, color: c, radius: radius, clip: clip))
    }
    public mutating func stroke(_ r: DrawRect, _ c: DrawColor, width: Float, radius: Float = 0) {
        guard r.w > 0, r.h > 0, c.a > 0, width > 0 else { return }
        quads.append(DrawQuad(rect: r, color: c, radius: radius, stroke: width, clip: clip))
    }
    /// A triangle filling `r`, pointing right (the play icon) or left (`u0` = 1 tells the shader).
    public mutating func triangle(_ r: DrawRect, _ c: DrawColor, pointingLeft: Bool = false) {
        quads.append(DrawQuad(rect: r, uv: (pointingLeft ? 1 : 0, 0, 0, 0), color: c, kind: .triangle, clip: clip))
    }
    /// A straight line from (x0, y0) to (x1, y1), `width` pixels thick with round caps (anti-aliased distance to the
    /// segment). The quad covers the segment's bounds plus the half width; `uv` carries the end points.
    public mutating func segment(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, width: Float, _ c: DrawColor) {
        guard width > 0, c.a > 0 else { return }
        let pad = width / 2 + 1
        let r = DrawRect(x: min(x0, x1) - pad, y: min(y0, y1) - pad, w: abs(x1 - x0) + 2 * pad, h: abs(y1 - y0) + 2 * pad)
        quads.append(DrawQuad(rect: r, uv: (x0, y0, x1, y1), color: c, stroke: width, kind: .segment, clip: clip))
    }
    /// The video picture into `r`, from the normalized source rect.
    public mutating func video(_ r: DrawRect, source: (Float, Float, Float, Float) = (0, 0, 1, 1)) {
        quads.append(DrawQuad(rect: r, uv: source, color: .white, kind: .video, clip: clip))
    }
    /// Image slot `slot` (0...5, uploaded by the renderer) into `r`, from the normalized source rect, sampled bilinear;
    /// `tint` multiplies its color and alpha (white = as is). Scopes, thumbnails.
    public mutating func image(_ r: DrawRect, slot: Int, source: (Float, Float, Float, Float) = (0, 0, 1, 1),
                               tint: DrawColor = .white) {
        guard r.w > 0, r.h > 0, (0..<DrawList.imageSlots).contains(slot) else { return }
        var q = DrawQuad(rect: r, uv: source, color: tint, kind: .image, clip: clip)
        q.pad = Float(slot)
        quads.append(q)
    }
    /// Image slots a renderer keeps (D3D12 shim `kImages`, DrawQuads.slang `image0...5`): 0 timeline thumbnails,
    /// 1 Slip two-up, 2-3 scopes, 4 the Text panel's template tiles (`TextTemplateTileAtlas`), 5 the Effects grid's
    /// stills (`EffectsTileAtlas`).
    public static let imageSlots = 6
    mutating func glyph(_ r: DrawRect, atlasX: Int, atlasY: Int, _ c: DrawColor) {
        quads.append(DrawQuad(rect: r, uv: (Float(atlasX), Float(atlasY), 0, 0), color: c, kind: .glyph, clip: clip))
    }
}
