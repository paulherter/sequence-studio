#if canImport(CoreText)
import Foundation
import CoreGraphics
import CoreText

// Rasterizes text with per-character animator states (TextAnimator.swift). Same passes as the static renderer
// (shadow over the whole group, background box, outside stroke, fill, center stroke), but every character is drawn with
// its own alpha, transform (scale about its unit's center, offset) and blur. All-rest states give the static picture.

extension TextRenderer {
    /// `characterStates` holds one state per `TextUnits.segment(layout)` character (missing ones are at rest). The raster
    /// grows to hold every moved or blurred character; `originX/Y` say where it starts in layout space, as usual.
    /// `tight`: the raster covers only what is painted (lines, background, shadow, moved characters) instead of the whole
    /// text box: the same drawing at the same device coordinates, clipped and cut on the full raster's pixel grid, so its
    /// pixels are bit for bit the full raster's (the playback cache of in-between frames: a caption's box is mostly empty).
    public static func render(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil, scale: Double = 1,
                              highlight: TextHighlight? = nil, characterStates: [TextCharacterState],
                              tight: Bool = false) throws -> TextRaster? {
        try render(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight, scale: scale, highlight: highlight,
                   characterStates: characterStates, tight: tight, admit: nil)
    }

    /// `admit`: see `rasterize`.
    static func render(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double?, scale: Double,
                       highlight: TextHighlight?, characterStates: [TextCharacterState], tight: Bool,
                       admit: ((Int) -> Bool)?) throws -> TextRaster? {
        let highlight = style.drawn(highlight: highlight)
        let style = style.drawn      // a footage fill is a plain glyph
        let layout = TextLayout.layout(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight)
        guard !layout.lines.isEmpty else { return nil }
        let geo = AnimatedGeometry(layout: layout, style: style, states: characterStates)
        let bounds = geo.bounds
        let crop = tight ? geo.tightBounds(scale: max(0.01, scale)) : nil
        return try rasterize(layout: layout, bounds: bounds, scale: scale, crop: crop, admit: admit) { ctx, s, space in
            drawAnimated(layout: layout, geo: geo, bounds: bounds, style: style, highlight: highlight, into: ctx, scale: s,
                         space: space)
        }
    }

    private static func drawAnimated(layout: TextLayoutResult, geo: AnimatedGeometry, bounds: TextRect, style: TextStyle,
                                     highlight: TextHighlight?, into ctx: CGContext, scale s: Double, space: CGColorSpace) {
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
        // Glyph origins unquantized, as `glyphPath` (gradient fills) and the portable raster place them; with quantizing
        // solid glyphs sat up to 1 px left of gradient glyphs and of the Windows picture.
        ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)
        let onlyLit = highlight?.onlyLit == true
        // Spread ("Size"): shadows come from the grown glyph shapes, drawn per character below (before the glyphs).
        let spreadShadow = onlyLit ? nil : style.shadow.flatMap { $0.spread > 0 ? $0 : nil }
        if let sh = style.shadow, !onlyLit, spreadShadow == nil {
            ctx.setShadow(offset: CGSize(width: sh.offsetX * s, height: -sh.offsetY * s), blur: sh.blur * s,
                          color: cg(sh.color, space))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(-s))
        ctx.translateBy(x: CGFloat(-bounds.x), y: CGFloat(-bounds.y))

        if let bg = style.background, let r = layout.backgroundRect, !onlyLit {
            fillBackground(bg, block: r, layout: layout, style: style, highlight: highlight, ctx: ctx, space: space)
        }

        let (lines, fillLines) = ctLines(layout: layout, style: style, highlight: highlight, space: space)
        // Blur: the glyph is drawn far outside the raster and only its shadow (blurred, offset back) lands. Shadow offsets
        // are in device space and ignore the CTM.
        // From the full bounds, so a tight raster shifts by the same amount as the full one.
        let away = (geo.bounds.width + geo.bounds.height) * 2 + 1000

        // Glyph ranges of every character: `lines` (context color) for the stroke, `fillLines` (karaoke colors) for the fill.
        struct Segment { let run: CTRun; let range: CFRange; let line: TextLine; let color: CGColor? }
        func segments(_ set: [(CTLine, TextLine)]) -> [Int: [Segment]] {
            var out: [Int: [Segment]] = [:]
            for (ct, l) in set {
                guard let lineIndex = layout.lines.firstIndex(of: l) else { continue }
                let map = geo.characterIndex(line: lineIndex)
                for run in (CTLineGetGlyphRuns(ct) as? [CTRun]) ?? [] {
                    let n = CTRunGetGlyphCount(run)
                    guard n > 0 else { continue }
                    var idx = [CFIndex](repeating: 0, count: n)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
                    let color = runForeground(run)
                    var g = 0
                    while g < n {
                        let ch = map[idx[g]]
                        var e = g + 1
                        while e < n, map[idx[e]] == ch { e += 1 }
                        if let c = ch {
                            out[c, default: []].append(Segment(run: run, range: CFRange(location: g, length: e - g), line: l, color: color))
                        }
                        g = e
                    }
                }
            }
            return out
        }

        let stroke = onlyLit ? nil : style.stroke.flatMap { $0.width > 0 ? $0 : nil }
        let strokeSegs = stroke == nil ? [:] : segments(lines)
        let fillSegs = segments(fillLines)
        let fillColor = cg(style.color, space)
        // Line styles: each line's bars are cut into pieces, one per character, so a character carries its own piece and
        // moves, fades and blurs with it. Spaces are not characters: a piece reaches to the next character on its line
        // (the first one back to the line's left edge, the last to its right edge), so the bar has no gaps.
        let bars = onlyLit ? [] : TextDecorations.bars(layout: layout, style: style)
        var order: [Int: [Int]] = [:]
        if !bars.isEmpty {
            for ch in geo.units.characters { order[ch.line, default: []].append(ch.index) }
            for k in order.keys { order[k]!.sort { geo.characterRects[$0].x < geo.characterRects[$1].x } }
        }
        func pieces(_ c: Int) -> [(CGRect, Int)] {
            let line = geo.units.characters[c].line
            guard let list = order[line], let pos = list.firstIndex(of: c) else { return [] }
            let r = geo.characterRects[c]
            return bars.filter { $0.lineIndex == line }.map { b in
                let x0 = pos == 0 ? min(b.rect.x, r.x) : r.x
                let x1 = pos == list.count - 1 ? max(b.rect.maxX, r.x + r.width) : geo.characterRects[list[pos + 1]].x
                return (CGRect(x: x0, y: b.rect.y, width: max(0, x1 - x0), height: b.rect.height), b.styleIndex)
            }
        }

        if let sh = spreadShadow {
            let solid = CGColor(colorSpace: space, components: [0, 0, 0, 1])!
            for c in 0..<geo.units.characters.count {
                let st = geo.state(c)
                guard st.opacity > 0, let segs = fillSegs[c] else { continue }
                ctx.saveGState()
                ctx.setAlpha(CGFloat(min(1, st.opacity)))
                ctx.setShadow(offset: CGSize(width: (sh.offsetX + away) * s, height: -sh.offsetY * s), blur: sh.blur * s,
                              color: cg(sh.color, space))
                ctx.translateBy(x: CGFloat(-away), y: 0)
                ctx.concatenate(geo.transforms[c])
                ctx.setFillColor(solid); ctx.setStrokeColor(solid)
                ctx.setLineWidth(CGFloat(sh.spread * 2))
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                ctx.setTextDrawingMode(.fillStroke)
                for seg in segs {
                    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    ctx.textPosition = CGPoint(x: seg.line.x, y: seg.line.y + seg.line.baseline)
                    CTRunDraw(seg.run, ctx, seg.range)
                }
                for (r, _) in pieces(c) { ctx.fill(r); ctx.stroke(r) }
                ctx.restoreGState()
            }
        }

        // Each character is one transparency layer (stroke and fill together) whose alpha is the character's opacity, so a
        // fading character never shows its outline through its fill. Blur and transform act inside the layer.
        for c in 0..<geo.units.characters.count {
            let st = geo.state(c)
            let barPieces = pieces(c)
            guard st.opacity > 0, strokeSegs[c] != nil || fillSegs[c] != nil || !barPieces.isEmpty else { continue }
            let blur = max(st.in.blur, st.out.blur)
            func drawBars(stroked: Bool, color: CGColor) {
                for (r, si) in barPieces {
                    ctx.saveGState()
                    let c0 = stroked ? color : cg(style.lineStyle(si).color, space)
                    if blur > 0 {
                        ctx.setShadow(offset: CGSize(width: away * s, height: 0), blur: blur * s, color: c0)
                        ctx.translateBy(x: CGFloat(-away), y: 0)
                    }
                    ctx.concatenate(geo.transforms[c])
                    if stroked { ctx.stroke(r) } else { ctx.setFillColor(c0); ctx.fill(r) }
                    ctx.restoreGState()
                }
            }
            func draw(_ segs: [Segment]?, mode: CGTextDrawingMode, color: CGColor) {
                for seg in segs ?? [] {
                    ctx.saveGState()
                    ctx.setTextDrawingMode(mode)
                    if blur > 0 {   // shift before the character's own transform, so its scale never scales the shift
                        ctx.setShadow(offset: CGSize(width: away * s, height: 0), blur: blur * s, color: seg.color ?? color)
                        ctx.translateBy(x: CGFloat(-away), y: 0)
                    }
                    ctx.concatenate(geo.transforms[c])
                    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    ctx.textPosition = CGPoint(x: seg.line.x, y: seg.line.y + seg.line.baseline)
                    CTRunDraw(seg.run, ctx, seg.range)
                    ctx.restoreGState()
                }
            }
            func strokePass(_ sk: TextStroke) {
                let color = cg(sk.color, space)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(CGFloat(sk.position == .outside ? sk.width * 2 : sk.width))
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                draw(strokeSegs[c], mode: .stroke, color: color)
                drawBars(stroked: true, color: color)
            }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(min(1, st.opacity)))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            if let sk = stroke, sk.position == .outside { strokePass(sk) }
            ctx.setFillColor(fillColor)
            draw(fillSegs[c], mode: .fill, color: fillColor)
            drawBars(stroked: false, color: fillColor)
            if let sk = stroke, sk.position == .centre { strokePass(sk) }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
    }

    /// The run's own foreground color (karaoke), nil when it follows the context.
    private static func runForeground(_ run: CTRun) -> CGColor? {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        guard let v = attrs[kCTForegroundColorAttributeName as String] else { return nil }
        return (v as! CGColor)
    }
}

/// Where every character sits and how it is moved: rects in layout space, unit centers, per-character transforms and
/// the union of everything that can paint (the raster bounds).
struct AnimatedGeometry {
    let units: TextUnits
    let states: [TextCharacterState]
    let transforms: [CGAffineTransform]
    let bounds: TextRect
    /// What is really painted (before it is cut on the pixel grid): the lines and the background with stroke and shadow,
    /// and every moved or blurred character.
    private let painted: TextRect
    private let margin: Double
    private let lineMaps: [[Int: Int]]
    /// The advance box of every character in layout space (the pieces line styles are cut from).
    let characterRects: [TextRect]

    init(layout: TextLayoutResult, style: TextStyle, states: [TextCharacterState]) {
        let units = TextUnits.segment(layout)
        self.units = units
        self.states = states
        let fonts = (0..<style.lineStyleCount).map { TextLayout.makeFont(style.lineStyle($0)) }
        var maps = [[Int: Int]](repeating: [:], count: layout.lines.count)
        var rects: [TextRect] = []
        var ctLines: [Int: CTLine] = [:]
        for c in units.characters {
            let l = layout.lines[c.line]
            let ct = ctLines[c.line] ?? {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: l.text, attributes: TextLayout.attributes(font: fonts[min(l.styleIndex, fonts.count - 1)],
                                                                 tracking: style.tracking, rightToLeft: l.isRightToLeft)))
                ctLines[c.line] = line
                return line
            }()
            let o = c.range.location - l.location + l.markerLength
            for k in 0..<c.range.length { maps[c.line][o + k] = c.index }
            let x0 = CTLineGetOffsetForStringIndex(ct, o, nil), x1 = CTLineGetOffsetForStringIndex(ct, o + c.range.length, nil)
            rects.append(TextRect(x: l.x + min(x0, x1), y: l.y, width: abs(x1 - x0), height: l.height))
        }
        lineMaps = maps
        characterRects = rects

        func unitRects(_ unit: TextAnimatorUnit) -> [Int: TextRect] {
            var r: [Int: TextRect] = [:]
            for c in units.characters {
                let i = units.index(of: c, unit: unit)
                r[i] = r[i].map { $0.union(rects[c.index]) } ?? rects[c.index]
            }
            return r
        }
        var cache: [TextAnimatorUnit: [Int: TextRect]] = [:]
        func centre(_ c: TextUnits.Character, _ unit: TextAnimatorUnit) -> CGPoint {
            if cache[unit] == nil { cache[unit] = unitRects(unit) }
            let r = cache[unit]![units.index(of: c, unit: unit)] ?? rects[c.index]
            return CGPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)
        }
        func move(_ st: TextUnitState, about p: CGPoint) -> CGAffineTransform {
            CGAffineTransform(translationX: p.x + st.offsetX, y: p.y + st.offsetY)
                .scaledBy(x: st.scale, y: st.scale)
                .translatedBy(x: -p.x, y: -p.y)
        }

        // What each character really paints: its glyph outlines (a swash or a script font reaches far past the advance
        // box and the line height), united with the advance box.
        var shapes = rects.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        for (li, ct) in ctLines {
            let l = layout.lines[li]
            for run in (CTLineGetGlyphRuns(ct) as? [CTRun]) ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0, let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { continue }
                let font = f as! CTFont
                let all = CFRange(location: 0, length: n)
                var glyphs = [CGGlyph](repeating: 0, count: n), at = [CGPoint](repeating: .zero, count: n)
                var idx = [CFIndex](repeating: 0, count: n), boxes = [CGRect](repeating: .zero, count: n)
                CTRunGetGlyphs(run, all, &glyphs); CTRunGetPositions(run, all, &at); CTRunGetStringIndices(run, all, &idx)
                CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, &boxes, n)
                let matrix = CTRunGetTextMatrix(run), slant = CTFontGetMatrix(font)
                for g in 0..<n {
                    guard let c = maps[li][idx[g]] else { continue }
                    var box = boxes[g].isNull ? CGRect.zero : boxes[g].union(boxes[g].applying(matrix))
                    // A synthesized italic is a shear in the font's matrix, which Core Text applies in some of these calls
                    // and repeats in the run's text matrix: the drawn glyph (sheared once) lies between the outline
                    // without the shear and the one with it twice, so the union of them holds it.
                    for var m in [.identity, matrix, slant.concatenating(matrix)] {
                        guard let path = CTFontCreatePathForGlyph(font, glyphs[g], &m) else { continue }
                        let pb = path.boundingBoxOfPath
                        if !pb.isNull, !pb.isInfinite { box = box.union(pb) }
                    }
                    guard box.width > 0, box.height > 0 else { continue }
                    // Glyph space is y up from the baseline, layout space y down.
                    shapes[c] = shapes[c].union(CGRect(x: l.x + at[g].x + box.minX, y: l.y + l.baseline - at[g].y - box.maxY,
                                                       width: box.width, height: box.height))
                }
            }
        }

        var tr: [CGAffineTransform] = []
        var b = layout.inkBounds
        var p: CGRect? = nil
        let reach = style.stroke?.reach ?? 0
        // A spread shadow is cast by the glyphs grown by the spread, drawn inside the character's transform: a character
        // scaled up carries a spread scaled up with it.
        let spread = style.shadow?.spread ?? 0
        var cast: CGRect? = nil
        for c in units.characters {
            let st = c.index < states.count ? states[c.index] : TextCharacterState(in: .rest, out: .rest)
            var t = CGAffineTransform.identity
            if let u = st.inUnit, !st.in.isRest { t = t.concatenating(move(st.in, about: centre(c, u))) }
            if let u = st.outUnit, !st.out.isRest { t = t.concatenating(move(st.out, about: centre(c, u))) }
            tr.append(t)
            guard st.opacity > 0 else { continue }
            let blur = max(st.in.blur, st.out.blur)
            // The stroke is drawn inside the character's transform, its blur after it (device space).
            let shown = shapes[c.index].insetBy(dx: -reach, dy: -reach).applying(t).insetBy(dx: -blur * 2.5, dy: -blur * 2.5)
            if shown.width > 0, shown.height > 0, shown.width.isFinite, shown.height.isFinite { p = p.map { $0.union(shown) } ?? shown }
            if spread > 0 {
                let grown = shapes[c.index].insetBy(dx: -reach - spread * 2, dy: -reach - spread * 2).applying(t)
                    .insetBy(dx: -blur * 2.5, dy: -blur * 2.5)
                if grown.width > 0, grown.height > 0, grown.width.isFinite, grown.height.isFinite {
                    cast = cast.map { $0.union(grown) } ?? grown
                }
            }
            guard t != .identity || blur > 0 else { continue }
            let ink = TextLayout.inkRect(rects[c.index], style: style).expanded(by: blur * 1.5 + 1)
            let m = CGRect(x: ink.x, y: ink.y, width: ink.width, height: ink.height).applying(t)
            if m.width > 0, m.height > 0, m.width.isFinite, m.height.isFinite {
                b = b.union(TextRect(x: m.minX, y: m.minY, width: m.width, height: m.height))
            }
        }
        // The background box (one block or one per word).
        if style.background != nil, let r = layout.backgroundRect {
            for w in [r] + TextWordRects.rects(layout: layout, style: style) {
                let box = CGRect(x: w.x, y: w.y, width: w.width, height: w.height)
                p = p.map { $0.union(box) } ?? box
            }
        }
        // The group's shadow: what casts it (everything painted, and the glyphs grown by the spread through their
        // transforms), offset in device space and blurred (Core Graphics blurs a little past the radius).
        if let sh = style.shadow, let q = p {
            let from = cast.map { q.union($0) } ?? q
            p = q.union(from.offsetBy(dx: sh.offsetX, dy: sh.offsetY).insetBy(dx: -sh.blur * 2, dy: -sh.blur * 2))
        }
        transforms = tr
        bounds = b
        painted = p.map { TextRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) } ?? b
        margin = 2   // antialiasing
    }

    /// `painted` with its margin, inside `bounds` and cut on the pixel grid `bounds` has at `scale`: a raster of it is the
    /// same pixels as that part of the full raster.
    func tightBounds(scale s: Double) -> TextRect {
        let want = painted.expanded(by: margin)
        let x0 = max(bounds.x, bounds.x + ((want.x - bounds.x) * s).rounded(.down) / s)
        let y0 = max(bounds.y, bounds.y + ((want.y - bounds.y) * s).rounded(.down) / s)
        let x1 = min(bounds.maxX, bounds.x + ((want.maxX - bounds.x) * s).rounded(.up) / s)
        let y1 = min(bounds.maxY, bounds.y + ((want.maxY - bounds.y) * s).rounded(.up) / s)
        guard x1 > x0, y1 > y0 else { return bounds }
        return TextRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Line-local UTF-16 offset -> character index (whitespace has none).
    func characterIndex(line: Int) -> [Int: Int] { lineMaps[line] }

    func state(_ c: Int) -> TextCharacterState {
        c < states.count ? states[c] : TextCharacterState(in: .rest, out: .rest)
    }
}
#endif
