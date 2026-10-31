import Foundation
import SQText

/// A CGContext-shaped drawing API over a `DrawList`, so Mac `draw(_:)` code ports almost line by line: coordinates are in
/// points (y down, like the flipped Mac views), state is a stack of translation + clip (`saveGState` / `restoreGState`),
/// and the calls mirror what the Mac panels do with NSBezierPath and NSString drawing. The canvas turns points into device
/// pixels with `scale` and emits quads; a CoreGraphics backend can implement the same calls on the Mac later.
public struct Canvas {
    public var list: DrawList
    public let atlas: GlyphAtlas?
    /// The SemiBold face index for `draw(_:in:...face:)` (`GlyphAtlas.semiboldFace`; 0 without an atlas).
    public var semibold: Int { atlas?.semiboldFace ?? 0 }
    /// The Medium face index (`GlyphAtlas.mediumFace`; 0 without an atlas).
    public var medium: Int { atlas?.mediumFace ?? 0 }
    /// Device pixels per point.
    public let scale: Float
    private var state = State()
    private var stack: [State] = []

    struct State { var tx: CGFloat = 0, ty: CGFloat = 0; var clipDepth = 0 }

    public init(list: DrawList, atlas: GlyphAtlas?, scale: Float) { self.list = list; self.atlas = atlas; self.scale = scale }
    public init(width: Float, height: Float, atlas: GlyphAtlas?, scale: Float) {
        self.init(list: DrawList(width: width, height: height), atlas: atlas, scale: scale)
    }

    // MARK: State

    public mutating func saveGState() { stack.append(state); state.clipDepth = 0 }
    public mutating func restoreGState() {
        for _ in 0..<state.clipDepth { list.popClip() }
        state = stack.popLast() ?? State()
    }
    public mutating func translateBy(x: CGFloat, y: CGFloat) { state.tx += x; state.ty += y }
    /// Intersects the clip with `r` until the matching `restoreGState`.
    public mutating func clip(to r: CGRect) { list.pushClip(px(r)); state.clipDepth += 1 }

    /// A rect in points (current translation applied) as device pixels.
    public func px(_ r: CGRect) -> DrawRect {
        let s = CGFloat(scale)
        return DrawRect(x: Float((r.minX + state.tx) * s), y: Float((r.minY + state.ty) * s),
                        w: Float(r.width * s), h: Float(r.height * s))
    }
    public func px(_ p: CGPoint) -> (Float, Float) {
        (Float((p.x + state.tx) * CGFloat(scale)), Float((p.y + state.ty) * CGFloat(scale)))
    }

    // MARK: Shapes

    public mutating func fill(_ r: CGRect, _ c: DrawColor) { list.fill(px(r), c) }
    public mutating func fill(roundedRect r: CGRect, radius: CGFloat, _ c: DrawColor) {
        list.fill(px(r), c, radius: Float(radius) * scale)
    }
    /// Stroke centered on the edge of `r` like NSBezierPath (half the width inside, half outside).
    public mutating func stroke(roundedRect r: CGRect, radius: CGFloat, width: CGFloat, _ c: DrawColor) {
        let o = r.insetBy(dx: -width / 2, dy: -width / 2)
        list.stroke(px(o), c, width: max(Float(width) * scale, 0.5), radius: Float(radius + width / 2) * scale)
    }
    public mutating func fill(ellipseIn r: CGRect, _ c: DrawColor) {
        let d = px(r)
        list.fill(d, c, radius: min(d.w, d.h) / 2)
    }
    public mutating func stroke(ellipseIn r: CGRect, width: CGFloat, _ c: DrawColor) {
        let d = px(r.insetBy(dx: -width / 2, dy: -width / 2))
        list.stroke(d, c, width: Float(width) * scale, radius: min(d.w, d.h) / 2)
    }
    /// A straight line with round caps (NSBezierPath move/line + stroke, `lineCapStyle = .round`).
    /// Image slot `slot` into `r` (the renderer holds the pixels; `DrawList.image`).
    /// `source`: the normalized part of the slot to show (an atlas cell, a crop).
    public mutating func draw(imageSlot slot: Int, in r: CGRect, source: (Float, Float, Float, Float) = (0, 0, 1, 1),
                              tint: DrawColor = .white) {
        list.image(px(r), slot: slot, source: source, tint: tint)
    }
    public mutating func strokeLine(from a: CGPoint, to b: CGPoint, width: CGFloat, _ c: DrawColor) {
        let (x0, y0) = px(a), (x1, y1) = px(b)
        list.segment(x0, y0, x1, y1, width: Float(width) * scale, c)
    }
    /// An open polyline (round joins come from the overlapping round caps).
    public mutating func strokePolyline(_ points: [CGPoint], width: CGFloat, _ c: DrawColor) {
        guard points.count > 1 else { return }
        for i in 1..<points.count { strokeLine(from: points[i - 1], to: points[i], width: width, c) }
    }
    /// A filled polygon (NSBezierPath fill, non-zero winding of a simple outline): key diamonds, arrows, curve areas.
    /// shortcut: one span quad per device row (even-odd spans), upgrade to a triangle-fan quad kind for large shapes.
    public mutating func fill(polygon points: [CGPoint], _ c: DrawColor) {
        guard points.count > 2 else { return }
        let p = points.map { px($0) }
        Self.spans(p) { list.fill($0, c) }
    }

    /// The row spans of a device-pixel polygon (even-odd), one rect per span, top to bottom.
    static func spans(_ p: [(Float, Float)], _ emit: (DrawRect) -> Void) {
        var minY = p[0].1, maxY = p[0].1
        for q in p { minY = min(minY, q.1); maxY = max(maxY, q.1) }
        var xs: [Float] = []
        xs.reserveCapacity(8)
        var y = minY.rounded(.down)
        while y < maxY {
            let sy = y + 0.5
            xs.removeAll(keepingCapacity: true)
            var j = p.count - 1
            for i in 0..<p.count {
                let (x0, y0) = p[j], (x1, y1) = p[i]
                if (y0 <= sy && y1 > sy) || (y1 <= sy && y0 > sy) { xs.append(x0 + (sy - y0) / (y1 - y0) * (x1 - x0)) }
                j = i
            }
            if xs.count == 2 { if xs[0] > xs[1] { xs.swapAt(0, 1) } } else { xs.sort() }
            var i = 0
            while i + 1 < xs.count {
                if xs[i + 1] > xs[i] { emit(DrawRect(x: xs[i], y: y, w: xs[i + 1] - xs[i], h: 1)) }
                i += 2
            }
            y += 1
        }
    }

    /// Polygons (points relative to `origin`) through `cache`: their row spans are built once per `key`, scale and
    /// sub-pixel offset of `origin`, then replayed at whole-pixel shifts. For static many-wedge art (the color wheels).
    /// `key` must change whenever the polygons do.
    public mutating func fill(polygons: @autoclosure () -> [([CGPoint], DrawColor)], at origin: CGPoint, key: AnyHashable,
                              cache: PolygonSpanCache) {
        let (ox, oy) = px(origin)
        let ix = ox.rounded(.down), iy = oy.rounded(.down)
        let k = PolygonSpanCache.Key(key: key, fx: ox - ix, fy: oy - iy, scale: scale)
        let spans = cache.spans(for: k) {
            var out: [(DrawRect, DrawColor)] = []
            let s = CGFloat(scale), fx = CGFloat(ox - ix), fy = CGFloat(oy - iy)
            for (pts, c) in polygons() where pts.count > 2 {
                Self.spans(pts.map { (Float($0.x * s + fx), Float($0.y * s + fy)) }) { out.append(($0, c)) }
            }
            return out
        }
        for (r, c) in spans { list.fill(DrawRect(x: r.x + ix, y: r.y + iy, w: r.w, h: r.h), c) }
    }
    /// A closed outline (NSBezierPath stroke of a closed path).
    public mutating func stroke(polygon points: [CGPoint], width: CGFloat, _ c: DrawColor) {
        guard let first = points.first else { return }
        strokePolyline(points + [first], width: width, c)
    }
    /// A vertical linear gradient from `top` to `bottom`.
    /// shortcut: one quad per device row, upgrade to a gradient quad kind when a panel draws large gradients.
    public mutating func fill(verticalGradient r: CGRect, top: DrawColor, bottom: DrawColor) {
        let d = px(r)
        let rows = max(1, Int(d.h.rounded(.up)))
        for i in 0..<rows {
            let t = rows == 1 ? 0 : Float(i) / Float(rows - 1)
            let c = DrawColor(top.r + (bottom.r - top.r) * t, top.g + (bottom.g - top.g) * t,
                              top.b + (bottom.b - top.b) * t, top.a + (bottom.a - top.a) * t)
            list.fill(DrawRect(x: d.x, y: d.y + Float(i), w: d.w, h: min(1, d.h - Float(i))), c)
        }
    }
    /// A soft drop shadow under a rounded rect (`NSShadow` with blur `blur` and offset `dy`, y down).
    /// shortcut: stacked translucent rounded rects instead of a Gaussian, upgrade to a blurred quad kind if it shows.
    /// `opaqueAbove`: an opaque card is drawn over `r` right after, so each layer is a ring around it (the part under
    /// the card is never seen): a dialog shadow then costs its outline, not 24 full-card fills (CPU backend).
    public mutating func shadow(roundedRect r: CGRect, radius: CGFloat, blur: CGFloat, dy: CGFloat, _ c: DrawColor,
                                opaqueAbove: Bool = false) {
        let steps = max(1, Int(blur.rounded()))
        for i in stride(from: steps, through: 1, by: -1) {
            let grow = CGFloat(i)
            let rr = r.offsetBy(dx: 0, dy: dy).insetBy(dx: -grow, dy: -grow)
            let layer = c.alpha(c.a / Float(steps) * 1.5)
            // The ring reaches 1 pt past the offset into the card, so the band below the card keeps every layer.
            let width = grow + abs(dy) + 1
            if opaqueAbove, width * 2 < min(rr.width, rr.height) {
                list.stroke(px(rr), layer, width: Float(width) * scale, radius: Float(radius + grow) * scale)
            } else {
                fill(roundedRect: rr, radius: radius + grow, layer)
            }
        }
    }

    // MARK: Text (face 0: the UI font of the glyph atlas; `face(family:)` adds a preview face)

    /// Width and line height of `s` at `size` points.
    public func size(of s: String, fontSize size: CGFloat, face: Int = 0) -> CGSize {
        guard let atlas else { return .zero }
        let p = Float(size) * scale
        return CGSize(width: CGFloat(atlas.width(of: s, pixelSize: p, face: face) / scale),
                      height: CGFloat((atlas.ascent(pixelSize: p, face: face) + atlas.descent(pixelSize: p, face: face)) / scale))
    }

    /// The atlas face of a font family (the bundled files, `GlyphRasterFont.bundled`) for previews in the look's own
    /// font; 0 (the UI face) without an atlas or once the atlas holds `GlyphAtlas.maxFaces`.
    public func face(family: String, weight: FontWeight = .regular, italic: Bool = false) -> Int {
        guard let atlas, let f = GlyphRasterFont.bundled(name: family, weight: weight, italic: italic) else { return 0 }
        return atlas.face(for: f)
    }

    /// `NSString.draw(at:)`: `p` is the top-left of the line box. Returns the width in points.
    @discardableResult
    public mutating func draw(_ s: String, at p: CGPoint, fontSize size: CGFloat, _ c: DrawColor,
                              maxWidth: CGFloat = .greatestFiniteMagnitude, face: Int = 0) -> CGFloat {
        guard let atlas else { return 0 }
        let ps = Float(size) * scale
        let (x, y) = px(p)
        let w = list.text(s, x: x, baseline: y + atlas.ascent(pixelSize: ps, face: face), pixelSize: ps, color: c, atlas: atlas,
                          maxWidth: maxWidth == .greatestFiniteMagnitude ? .infinity : Float(maxWidth) * scale, face: face)
        return CGFloat(w / scale)
    }

    /// One line vertically centered in `r`, aligned left, center or right (with `inset` from the side).
    @discardableResult
    public mutating func draw(_ s: String, in r: CGRect, fontSize size: CGFloat, _ c: DrawColor,
                              align: DrawList.TextAlign = .left, inset: CGFloat = 0, face: Int = 0) -> CGFloat {
        guard let atlas else { return 0 }
        let w = list.text(s, in: px(r), pixelSize: Float(size) * scale, color: c, atlas: atlas, align: align,
                          inset: Float(inset) * scale, face: face)
        return CGFloat(w / scale)
    }

    /// Word-wrapped text in `r` (`NSString.draw(with:options: .usesLineFragmentOrigin)`); returns the lines drawn.
    @discardableResult
    public mutating func drawWrapped(_ s: String, in r: CGRect, fontSize size: CGFloat, lineHeight: CGFloat, _ c: DrawColor) -> Int {
        let lines = wrap(s, width: r.width, fontSize: size)
        for (i, line) in lines.enumerated() {
            draw(line, at: CGPoint(x: r.minX, y: r.minY + CGFloat(i) * lineHeight), fontSize: size, c)
        }
        return lines.count
    }

    /// Greedy word wrap at `width` points.
    public func wrap(_ s: String, width: CGFloat, fontSize size: CGFloat) -> [String] {
        var out: [String] = []
        for para in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in para.split(separator: " ") {
                let cand = line.isEmpty ? String(word) : line + " " + word
                if !line.isEmpty, self.size(of: cand, fontSize: size).width > width { out.append(line); line = String(word) }
                else { line = cand }
            }
            out.append(line)
        }
        return out
    }
}

extension Canvas {
    /// The AppKit `EmptyStateView` text block: a 15 pt semibold title in `label`, a wrapped body hint (at most 3 lines) in
    /// `label2`, 4 pt apart, centered in `r`. `reserve` is the height kept free below for a button (centered with the text).
    /// Returns the bottom of the hint.
    @discardableResult
    public mutating func drawEmptyState(title: String, hint: String, in r: CGRect, reserve: CGFloat = 0, theme t: DrawTheme) -> CGFloat {
        let titleH: CGFloat = 20, lineH: CGFloat = 14, gap = CGFloat(DrawTheme.Spacing.xs)
        let w = max(r.width - 2 * CGFloat(DrawTheme.Spacing.lg), 0)
        let lines = Array(wrap(hint, width: w, fontSize: CGFloat(DrawTheme.TypeSize.body)).prefix(3))
        let block = titleH + (lines.isEmpty ? 0 : gap + CGFloat(lines.count) * lineH) + reserve
        let top = (r.midY - block / 2).rounded()
        let x = r.minX + CGFloat(DrawTheme.Spacing.lg)
        draw(title, in: CGRect(x: x, y: top, width: w, height: titleH), fontSize: 15, t.label, align: .center, face: semibold)
        for (i, line) in lines.enumerated() {
            draw(line, in: CGRect(x: x, y: top + titleH + gap + CGFloat(i) * lineH, width: w, height: lineH),
                 fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
        }
        return top + block - reserve
    }
}
