import Foundation

/// The text raster without Core Graphics: the same drawing steps as `TextRenderer.draw` (spread shadow, group shadow,
/// background box, outside stroke, solid / gradient / karaoke fill, line bars, centered stroke), on `LinearCanvas` from
/// the font files' own outlines. Windows renders titles with it; on the Mac it is compiled for the parity test against
/// Core Text (`PortableTextRasterTests`).
/// Glyphs advance by their variable-font widths, GPOS pair kerning and tracking; weights are the family's named instances,
/// italic is the family's italic file (`PortableFontMatch`).
/// shortcut: no ligatures, contextual alternates or right-to-left reordering; upgrade with HarfBuzz.
public enum PortableTextRenderer {
    /// A drawn block: premultiplied linear-light RGBA floats, `width` x `height`, top row first. Pixel (0, 0) is the
    /// top-left of `bounds` (layout space) at `scale`.
    public struct Picture: Sendable {
        public let width: Int, height: Int
        public let pixels: [Float]
        public init(width: Int, height: Int, pixels: [Float]) { self.width = width; self.height = height; self.pixels = pixels }
    }

    /// A rendered text block, the portable counterpart of `TextRaster` (same origin, scale and pixel size).
    public struct Raster: Sendable {
        public let layout: TextLayoutResult
        public let scale: Double
        /// Top-left of the raster in layout space (= `layout.inkBounds` origin), unscaled.
        public let originX: Double, originY: Double
        public let picture: Picture
    }

    /// `TextRenderer.render` without Core Graphics: same layout, same raster size and origin; nil for empty text or
    /// ink, or a raster side over `maxRasterSide`.
    /// shortcut: no `crop` (the whole ink box is drawn) and no memory budget; upgrade when Windows plays huge titles.
    public static func render(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil, scale: Double = 1,
                              highlight: TextHighlight? = nil) -> Raster? {
        let highlight = style.drawn(highlight: highlight)
        let style = style.drawn
        let layout = TextLayout.layout(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight)
        let ink = layout.inkBounds
        guard !layout.lines.isEmpty, scale.isFinite, ink.width.isFinite, ink.height.isFinite, ink.x.isFinite, ink.y.isFinite
        else { return nil }
        let s = max(0.01, scale)
        let rawW = (ink.width * s).rounded(.up), rawH = (ink.height * s).rounded(.up)
        guard rawW.isFinite, rawH.isFinite, rawW > 0, rawH > 0, rawW <= Double(maxRasterSide), rawH <= Double(maxRasterSide)
        else { return nil }
        let picture = draw(layout: layout, style: style, highlight: highlight, bounds: ink, scale: s,
                           width: Int(rawW), height: Int(rawH))
        return Raster(layout: layout, scale: s, originX: ink.x, originY: ink.y, picture: picture)
    }

    /// Largest raster side in pixels (as `TextRenderer.maxRasterSide`).
    static let maxRasterSide = 16_384

    /// Draws `layout` (made from `style`) over `bounds` at `scale`. `style` and `highlight` as `TextRenderer.render`
    /// passes them (already `drawn`).
    public static func draw(layout: TextLayoutResult, style: TextStyle, highlight: TextHighlight?, bounds ink: TextRect,
                            scale s: Double, width: Int, height: Int) -> Picture {
        let onlyLit = highlight?.onlyLit == true
        let glyphs = GlyphPlacer(layout: layout, style: style, ink: ink, scale: s)
        func mask(_ build: (inout PolygonMask) -> Void) -> [Float] {
            var m = PolygonMask(width: width, height: height)
            build(&m)
            return m.mask()
        }
        func px(_ r: TextRect) -> (Double, Double, Double, Double) { ((r.x - ink.x) * s, (r.y - ink.y) * s, r.width * s, r.height * s) }
        func rectPolygon(_ r: TextRect) -> [SIMD2<Double>] {
            let (x, y, w, h) = px(r)
            return [SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h)]
        }
        let bars = onlyLit ? [] : TextDecorations.bars(layout: layout, style: style)
        let allOutlines = glyphs.outlines(of: nil)
        let glyphFill = mask { m in for c in allOutlines { m.add(c) } }

        var picture = LinearCanvas(width: width, height: height)
        let blurSigma: (TextShadow) -> Double = { $0.blur * s / 2 }   // shortcut: sigma = blur / 2 approximates Core Graphics' kernel (coverage within 5%, PortableTextRasterTests); measure CG to upgrade

        // Spread ("Size"): the shadow of the grown glyphs and bars, drawn first; the group itself casts none then.
        let spreadShadow = onlyLit ? nil : style.shadow.flatMap { $0.spread > 0 ? $0 : nil }
        if let sh = spreadShadow {
            let grown = mask { m in
                for c in allOutlines { m.add(c) }
                m.stroke(allOutlines, halfWidth: sh.spread * s)
                for b in bars {
                    let r = rectPolygon(b.rect)
                    m.addPositive(r); m.stroke([r], halfWidth: sh.spread * s)
                }
            }
            let cast = MaskOps.shift(MaskOps.blur(grown, width: width, height: height, sigma: blurSigma(sh)),
                                     width: width, height: height, dx: sh.offsetX * s, dy: sh.offsetY * s)
            picture.fill(cast, color: LinearCanvas.linear(sh.color))
        }

        var group = LinearCanvas(width: width, height: height)
        if let bg = style.background, let r = layout.backgroundRect, !onlyLit {
            let words = TextWordRects.wantsPerWord(highlight, style: style) ? TextWordRects.rects(layout: layout, style: style) : []
            let boxes = mask { m in
                for w in words.isEmpty ? [r] : words {
                    let (x, y, bw, bh) = px(w)
                    m.addPositive(PolygonMask.roundedRect(x: x, y: y, width: bw, height: bh, radius: bg.cornerRadius * s))
                }
            }
            group.fill(boxes, color: LinearCanvas.linear(bg.color))
        }

        let stroke = onlyLit ? nil : style.stroke.flatMap { $0.width > 0 ? $0 : nil }
        func strokePass(_ st: TextStroke) {
            // Outside: twice the width, the inner half is covered by the fill drawn after it. Centered: the width itself.
            let half = (st.position == .outside ? st.width * 2 : st.width) * s / 2
            let m = mask { m in
                m.stroke(allOutlines, halfWidth: half)
                m.stroke(bars.map { rectPolygon($0.rect) }, halfWidth: half)
            }
            group.fill(m, color: LinearCanvas.linear(st.color))
        }
        if let st = stroke, st.position == .outside { strokePass(st) }

        if let g = style.gradient, highlight == nil, let block = lineBlock(layout) {
            let a = g.axis(in: block)
            let sx = (a.start.x - ink.x) * s, sy = (a.start.y - ink.y) * s
            let dx = (a.end.x - a.start.x) * s, dy = (a.end.y - a.start.y) * s
            let len2 = max(dx * dx + dy * dy, 1e-12)
            group.fill(glyphFill) { x, y in
                let t = min(1, max(0, ((Double(x) + 0.5 - sx) * dx + (Double(y) + 0.5 - sy) * dy) / len2))
                // Core Graphics interpolates in the gradient's (sRGB) space, then converts to the linear context.
                func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * t }
                return LinearCanvas.linear(RGBAColor(red: mix(g.start.red, g.end.red), green: mix(g.start.green, g.end.green),
                                                     blue: mix(g.start.blue, g.end.blue), alpha: mix(g.start.alpha, g.end.alpha)))
            }
        } else {
            for (color, outlines) in glyphs.fillGroups(highlight: highlight) {
                group.fill(mask { m in for c in outlines { m.add(c) } }, color: LinearCanvas.linear(color))
            }
        }
        for b in bars {
            group.fill(mask { $0.add(rectPolygon(b.rect)) }, color: LinearCanvas.linear(style.lineStyle(b.styleIndex).color))
        }
        if let st = stroke, st.position == .centre { strokePass(st) }

        // The shadow is cast by the whole group.
        if let sh = style.shadow, !onlyLit, spreadShadow == nil {
            let cast = MaskOps.shift(MaskOps.blur(group.alpha, width: width, height: height, sigma: blurSigma(sh)),
                                     width: width, height: height, dx: sh.offsetX * s, dy: sh.offsetY * s)
            picture.fill(cast, color: LinearCanvas.linear(sh.color))
        }
        group.place(over: picture)
        return Picture(width: width, height: height, pixels: group.pixels)
    }
}

extension PortableTextRenderer {
    /// The union of the line boxes (the block a gradient fill spans), nil without lines.
    static func lineBlock(_ layout: TextLayoutResult) -> TextRect? {
        var block: TextRect?
        for l in layout.lines { block = block.map { $0.union(l.rect) } ?? l.rect }
        return block
    }
}

/// Glyph outlines of a layout in raster pixels (y down), with the UTF-16 offset of each glyph in its line's text.
struct GlyphPlacer {
    struct Placed { let line: Int; let offset: Int; let outline: [[SIMD2<Double>]] }
    let placed: [Placed]
    let layout: TextLayoutResult
    let style: TextStyle
    /// Per line: the pen (layout space, unscaled) at every UTF-16 offset of the line's text, the end included: the caret
    /// positions `CTLineGetOffsetForStringIndex` gives on the Mac (tracking follows each glyph).
    let carets: [[Int: Double]]

    init(layout: TextLayoutResult, style: TextStyle, ink: TextRect, scale s: Double) {
        self.layout = layout; self.style = style
        var out: [Placed] = []
        var carets = [[Int: Double]](repeating: [:], count: layout.lines.count)
        let shear = tan(12.0 * Double.pi / 180)
        for (li, l) in layout.lines.enumerated() where !l.text.isEmpty {
            let ls = style.lineStyle(l.styleIndex)
            guard let choice = PortableFontMatch.choose(name: ls.fontName, weight: ls.weight, italic: ls.italic, size: ls.size,
                                                        axes: ls.fontAxes) else { continue }
            let font = choice.font, coords = choice.coords
            let unit = ls.size / Double(font.unitsPerEm)          // layout px per font unit
            var pen = l.x
            let baseline = l.y + l.baseline
            var offset = 0
            var previous: Int?
            for scalar in l.text.unicodeScalars {
                let g = font.glyph(for: scalar)
                if let p = previous { pen += font.face.kern(p, g, coords: coords) * unit }
                carets[li][offset] = pen
                let k = unit * s, ox = (pen - ink.x) * s, oy = (baseline - ink.y) * s
                let italic = choice.shear ? shear : 0
                let contours = OutlineFonts.polylines(font.contours(glyph: g, coords: coords), pixelsPerUnit: k) { x, y in
                    SIMD2(ox + (x + italic * y) * k, oy - y * k)
                }
                if !contours.isEmpty { out.append(Placed(line: li, offset: offset, outline: contours)) }
                pen += font.advance(glyph: g, coords: coords) * unit + style.tracking
                offset += scalar.utf16.count
                previous = g
            }
            carets[li][offset] = pen
        }
        placed = out
        self.carets = carets
    }

    /// Every glyph outline (`line` nil) or those of one line.
    func outlines(of line: Int?) -> [[SIMD2<Double>]] {
        placed.filter { line == nil || $0.line == line }.flatMap(\.outline)
    }

    /// Glyph outlines grouped by fill color: the line's look color, lit karaoke words in the highlight color; an
    /// `onlyLit` highlight keeps just the lit words.
    func fillGroups(highlight: TextHighlight?) -> [(RGBAColor, [[SIMD2<Double>]])] {
        let paint = fillColors(highlight: highlight)
        var groups: [(RGBAColor, [[SIMD2<Double>]])] = []
        for p in placed {
            guard let c = paint(p) else { continue }
            if let i = groups.firstIndex(where: { $0.0 == c }) { groups[i].1 += p.outline } else { groups.append((c, p.outline)) }
        }
        return groups
    }

    /// The fill color of one placed glyph (nil: not drawn, an unlit word of an `onlyLit` highlight).
    func fillColors(highlight: TextHighlight?) -> (Placed) -> RGBAColor? {
        let layout = self.layout, style = self.style
        let lit: [NSRange] = (highlight?.words).map { r in
            r.compactMap { layout.wordSpans.indices.contains($0) ? layout.wordSpans[$0] : nil }
        } ?? []
        let onlyLit = highlight?.onlyLit == true
        return { p in
            let l = layout.lines[p.line]
            let at = l.location + p.offset - l.markerLength
            let isLit = p.offset >= l.markerLength && lit.contains { NSLocationInRange(at, $0) }
            if isLit, let h = highlight { return h.color }
            if onlyLit { return nil }
            return style.hasLineLooks || highlight != nil ? style.lineStyle(l.styleIndex).color : style.color
        }
    }
}

/// Outline helpers for the portable raster (the faces come from `PortableFontMatch`).
enum OutlineFonts {
    /// TrueType contours (quadratic) to closed polylines through `map` (font units to pixels).
    static func polylines(_ contours: [[GlyphRasterFont.Point]], pixelsPerUnit k: Double,
                          map: (Double, Double) -> SIMD2<Double>) -> [[SIMD2<Double>]] {
        var out: [[SIMD2<Double>]] = []
        for c in contours where c.count > 1 {
            var pts = c
            if let i = pts.firstIndex(where: { $0.onCurve }) { pts = Array(pts[i...] + pts[..<i]) } else {
                let m = GlyphRasterFont.Point(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2, onCurve: true)
                pts.insert(m, at: 1); pts = Array(pts[1...] + pts[..<1])
            }
            var poly: [SIMD2<Double>] = [map(pts[0].x, pts[0].y)]
            var cur = pts[0]
            var ctrl: GlyphRasterFont.Point?
            func quad(_ p0: GlyphRasterFont.Point, _ q: GlyphRasterFont.Point, _ p1: GlyphRasterFont.Point) {
                let len = (hypot(q.x - p0.x, q.y - p0.y) + hypot(p1.x - q.x, p1.y - q.y)) * k
                let n = max(1, min(64, Int((len / 1.5).rounded(.up))))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    poly.append(map(u * u * p0.x + 2 * u * t * q.x + t * t * p1.x, u * u * p0.y + 2 * u * t * q.y + t * t * p1.y))
                }
            }
            for p in pts[1...] + [pts[0]] {
                if p.onCurve {
                    if let q = ctrl { quad(cur, q, p) } else { poly.append(map(p.x, p.y)) }
                    cur = p; ctrl = nil
                } else if let q = ctrl {
                    let mid = GlyphRasterFont.Point(x: (q.x + p.x) / 2, y: (q.y + p.y) / 2, onCurve: true)
                    quad(cur, q, mid); cur = mid; ctrl = p
                } else { ctrl = p }
            }
            if poly.count > 1, poly.first == poly.last { poly.removeLast() }
            out.append(poly)
        }
        return out
    }
}
