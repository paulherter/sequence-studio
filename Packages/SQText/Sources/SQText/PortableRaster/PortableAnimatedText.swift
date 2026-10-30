import Foundation

// Text animators on the portable raster (Windows): the drawing of `TextRenderer.render(… characterStates:)`
// (TextAnimatorRenderer.swift) without Core Graphics. Every character is its own layer (outside stroke, fill, its pieces
// of the line bars, centered stroke) with its alpha, its transform (scale about its unit's center, offset) and its blur;
// the background box stays put, the group casts the shadow (or, with a spread, every character casts its grown shape).

extension PortableTextRenderer {
    /// `render(text:…)` with one state per `TextUnits.segment(layout)` character (missing ones are at rest). The raster
    /// grows to hold every moved or blurred character, as on the Mac; `originX/Y` say where it starts in layout space.
    /// All-rest states give the static raster's size and origin.
    /// shortcut: no `tight` crop (the whole animated box is drawn every frame); add it when big animated captions are slow.
    public static func render(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil, scale: Double = 1,
                              highlight: TextHighlight? = nil, characterStates: [TextCharacterState]) -> Raster? {
        let highlight = style.drawn(highlight: highlight)
        let style = style.drawn
        let layout = TextLayout.layout(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight)
        guard !layout.lines.isEmpty, scale.isFinite else { return nil }
        let s = max(0.01, scale)
        let ink = layout.inkBounds
        guard ink.width.isFinite, ink.height.isFinite, ink.x.isFinite, ink.y.isFinite else { return nil }
        // Outlines once, in pixels from the ink origin; the animated bounds only move them.
        let glyphs = GlyphPlacer(layout: layout, style: style, ink: ink, scale: s)
        let geo = PortableAnimatedGeometry(layout: layout, style: style, glyphs: glyphs, ink: ink, scale: s, states: characterStates)
        let b = geo.bounds
        guard b.width.isFinite, b.height.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let rawW = (b.width * s).rounded(.up), rawH = (b.height * s).rounded(.up)
        guard rawW > 0, rawH > 0, rawW <= Double(maxRasterSide), rawH <= Double(maxRasterSide) else { return nil }
        let picture = drawAnimated(layout: layout, style: style, highlight: highlight, glyphs: glyphs, geo: geo, ink: ink,
                                   scale: s, width: Int(rawW), height: Int(rawH))
        return Raster(layout: layout, scale: s, originX: b.x, originY: b.y, picture: picture)
    }

    private static func drawAnimated(layout: TextLayoutResult, style: TextStyle, highlight: TextHighlight?, glyphs: GlyphPlacer,
                                     geo: PortableAnimatedGeometry, ink: TextRect, scale s: Double,
                                     width: Int, height: Int) -> Picture {
        let onlyLit = highlight?.onlyLit == true
        let b = geo.bounds
        let full = PixelBox(x: 0, y: 0, width: width, height: height)
        /// A point of the glyph placer (pixels from the ink origin) through character `c`'s transform into raster pixels.
        func place(_ c: Int?) -> (SIMD2<Double>) -> SIMD2<Double> {
            let t = c.map { geo.transforms[$0] } ?? .identity
            return { p in
                let q = t.apply(SIMD2(p.x / s + ink.x, p.y / s + ink.y))
                return SIMD2((q.x - b.x) * s, (q.y - b.y) * s)
            }
        }
        /// A rectangle in layout space through character `c`'s transform into raster pixels.
        func rectPolygon(_ r: TextRect, _ c: Int?) -> [SIMD2<Double>] {
            let t = c.map { geo.transforms[$0] } ?? .identity
            return [SIMD2(r.x, r.y), SIMD2(r.maxX, r.y), SIMD2(r.maxX, r.maxY), SIMD2(r.x, r.maxY)].map {
                let q = t.apply($0)
                return SIMD2((q.x - b.x) * s, (q.y - b.y) * s)
            }
        }

        // Glyphs and line-bar pieces of every character.
        let paint = glyphs.fillColors(highlight: highlight)
        var outlines: [Int: [[SIMD2<Double>]]] = [:]
        var fills: [Int: [(RGBAColor, [[SIMD2<Double>]])]] = [:]
        for p in glyphs.placed {
            guard let c = geo.lineMaps[p.line][p.offset] else { continue }
            let m = place(c)
            let o = p.outline.map { $0.map(m) }
            outlines[c, default: []] += o
            if let color = paint(p) { fills[c, default: []].append((color, o)) }
        }
        let bars = onlyLit ? [] : TextDecorations.bars(layout: layout, style: style)
        var order: [Int: [Int]] = [:]
        if !bars.isEmpty {
            for ch in geo.units.characters { order[ch.line, default: []].append(ch.index) }
            for k in order.keys { order[k]!.sort { geo.characterRects[$0].x < geo.characterRects[$1].x } }
        }
        /// The bar pieces of character `c` in layout space (the Mac's `pieces`): a piece reaches to the next character on
        /// its line, the first back to the bar's start, the last to its end, so the bar has no gaps.
        func pieces(_ c: Int) -> [(TextRect, Int)] {
            let line = geo.units.characters[c].line
            guard let list = order[line], let pos = list.firstIndex(of: c) else { return [] }
            let r = geo.characterRects[c]
            return bars.filter { $0.lineIndex == line }.map { bar in
                let x0 = pos == 0 ? min(bar.rect.x, r.x) : r.x
                let x1 = pos == list.count - 1 ? max(bar.rect.maxX, r.maxX) : geo.characterRects[list[pos + 1]].x
                return (TextRect(x: x0, y: bar.rect.y, width: max(0, x1 - x0), height: bar.rect.height), bar.styleIndex)
            }
        }

        var picture = LinearCanvas(width: width, height: height)
        let blurSigma: (Double) -> Double = { $0 * s / 2 }   // as the static raster (Core Graphics' shadow blur)
        let count = geo.units.characters.count

        // Spread ("Size"): every character casts the shadow of its grown shape, at its opacity; the group casts none then.
        let spreadShadow = onlyLit ? nil : style.shadow.flatMap { $0.spread > 0 ? $0 : nil }
        if let sh = spreadShadow {
            // shortcut: the characters' grown shapes are laid together (source-over at their opacity) and blurred once,
            // where Core Graphics blurs each character's shadow on its own (the same where they do not overlap).
            var cast = [Float](repeating: 0, count: width * height)
            for c in 0..<count {
                let st = geo.state(c)
                guard st.opacity > 0, let o = outlines[c] else { continue }
                let barRects = pieces(c).map { rectPolygon($0.0, c) }
                let k = geo.transforms[c].scale
                var m = PolygonMask(width: width, height: height)
                for p in o { m.add(p) }
                m.stroke(o, halfWidth: sh.spread * s * k)
                for r in barRects { m.addPositive(r); m.stroke([r], halfWidth: sh.spread * s * k) }
                let a = Float(min(1, st.opacity))
                for (i, v) in m.mask().enumerated() where v > 0 { cast[i] += v * a * (1 - cast[i]) }
            }
            let blurred = MaskOps.shift(MaskOps.blur(cast, width: width, height: height, sigma: blurSigma(sh.blur)),
                                        width: width, height: height, dx: sh.offsetX * s, dy: sh.offsetY * s)
            picture.fill(blurred, color: LinearCanvas.linear(sh.color))
        }

        var group = LinearCanvas(width: width, height: height)
        if let bg = style.background, let r = layout.backgroundRect, !onlyLit {
            let words = TextWordRects.wantsPerWord(highlight, style: style) ? TextWordRects.rects(layout: layout, style: style) : []
            var m = PolygonMask(width: width, height: height)
            for w in words.isEmpty ? [r] : words {
                m.addPositive(PolygonMask.roundedRect(x: (w.x - b.x) * s, y: (w.y - b.y) * s, width: w.width * s,
                                                      height: w.height * s, radius: bg.cornerRadius * s))
            }
            group.fill(m.mask(), color: LinearCanvas.linear(bg.color))
        }

        // One layer per character (stroke and fill together, so a fading character never shows its outline through its
        // fill), drawn only over the pixels it can reach.
        let stroke = onlyLit ? nil : style.stroke.flatMap { $0.width > 0 ? $0 : nil }
        for c in 0..<count {
            let st = geo.state(c)
            let barPieces = pieces(c)
            guard st.opacity > 0, outlines[c] != nil || !barPieces.isEmpty else { continue }
            let blur = max(st.in.blur, st.out.blur)
            let k = geo.transforms[c].scale
            let barPolys = barPieces.map { (rectPolygon($0.0, c), $0.1) }
            let o = outlines[c] ?? []
            // The pixels this character can paint: its outlines and bars, grown by the stroke and the blur.
            let reach = (stroke.map { $0.position == .outside ? $0.width : $0.width / 2 } ?? 0) * s * k + blur * s * 1.5 + 2
            guard let box = PixelBox.around(o + barPolys.map(\.0), margin: reach)?.clipped(to: full) else { continue }
            func shifted(_ ps: [[SIMD2<Double>]]) -> [[SIMD2<Double>]] {
                ps.map { $0.map { SIMD2($0.x - Double(box.x), $0.y - Double(box.y)) } }
            }
            func mask(_ build: (inout PolygonMask) -> Void) -> [Float] {
                var m = PolygonMask(width: box.width, height: box.height)
                build(&m)
                return m.mask()
            }
            var layer = LinearCanvas(width: box.width, height: box.height)
            func strokePass(_ sk: TextStroke) {
                let half = (sk.position == .outside ? sk.width * 2 : sk.width) * s * k / 2
                layer.fill(mask { m in
                    m.stroke(shifted(o), halfWidth: half)
                    m.stroke(shifted(barPolys.map(\.0)), halfWidth: half)
                }, color: LinearCanvas.linear(sk.color))
            }
            if let sk = stroke, sk.position == .outside { strokePass(sk) }
            for (color, polys) in fills[c] ?? [] {
                layer.fill(mask { m in for p in shifted(polys) { m.add(p) } }, color: LinearCanvas.linear(color))
            }
            for (poly, si) in barPolys {
                layer.fill(mask { $0.add(shifted([poly])[0]) }, color: LinearCanvas.linear(style.lineStyle(si).color))
            }
            if let sk = stroke, sk.position == .centre { strokePass(sk) }
            if blur > 0 { layer.blur(sigma: blurSigma(blur)) }
            group.composite(layer, at: box, opacity: Float(min(1, st.opacity)))
        }

        // The group's shadow (no spread): cast by everything painted.
        if let sh = style.shadow, !onlyLit, spreadShadow == nil {
            let cast = MaskOps.shift(MaskOps.blur(group.alpha, width: width, height: height, sigma: blurSigma(sh.blur)),
                                     width: width, height: height, dx: sh.offsetX * s, dy: sh.offsetY * s)
            picture.fill(cast, color: LinearCanvas.linear(sh.color))
        }
        group.place(over: picture)
        return Picture(width: width, height: height, pixels: group.pixels)
    }
}

/// A pixel rectangle of a raster.
struct PixelBox: Equatable {
    var x: Int, y: Int, width: Int, height: Int

    /// The whole pixels around `polygons`, grown by `margin`; nil without points.
    static func around(_ polygons: [[SIMD2<Double>]], margin: Double) -> PixelBox? {
        var lo = SIMD2(Double.infinity, .infinity), hi = SIMD2(-Double.infinity, -.infinity)
        for p in polygons { for q in p { lo = pointwiseMin(lo, q); hi = pointwiseMax(hi, q) } }
        guard lo.x.isFinite, hi.x.isFinite, lo.y.isFinite, hi.y.isFinite else { return nil }
        let x0 = Int((lo.x - margin).rounded(.down)), y0 = Int((lo.y - margin).rounded(.down))
        let x1 = Int((hi.x + margin).rounded(.up)), y1 = Int((hi.y + margin).rounded(.up))
        return PixelBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The part inside `o`; nil when nothing is left.
    func clipped(to o: PixelBox) -> PixelBox? {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(x + width, o.x + o.width), y1 = min(y + height, o.y + o.height)
        return x1 > x0 && y1 > y0 ? PixelBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
    }
}

extension LinearCanvas {
    /// Gaussian blur of every (premultiplied) channel, zero outside.
    mutating func blur(sigma: Double) {
        let n = width * height
        for k in 0..<4 {
            let channel = (0..<n).map { pixels[$0 * 4 + k] }
            let out = MaskOps.blur(channel, width: width, height: height, sigma: sigma)
            for i in 0..<n { pixels[i * 4 + k] = out[i] }
        }
    }

    /// Source-over of `layer` (lying at `box`) at `opacity`.
    mutating func composite(_ layer: LinearCanvas, at box: PixelBox, opacity: Float) {
        for y in 0..<box.height {
            for x in 0..<box.width {
                let si = (y * box.width + x) * 4
                let a = layer.pixels[si + 3] * opacity
                guard a > 0 else { continue }
                let di = ((box.y + y) * width + box.x + x) * 4, keep = 1 - a
                for c in 0..<3 { pixels[di + c] = layer.pixels[si + c] * opacity + pixels[di + c] * keep }
                pixels[di + 3] = a + pixels[di + 3] * keep
            }
        }
    }
}

/// An affine map of layout space (column vectors: x' = a x + c y + tx, y' = b x + d y + ty), the `CGAffineTransform`
/// the Mac builds per character.
struct TextAffine: Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    static let identity = TextAffine()

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }

    /// `self` first, then `o` (`CGAffineTransform.concatenating`).
    func then(_ o: TextAffine) -> TextAffine {
        TextAffine(a: a * o.a + b * o.c, b: a * o.b + b * o.d, c: c * o.a + d * o.c, d: c * o.b + d * o.d,
                   tx: tx * o.a + ty * o.c + o.tx, ty: tx * o.b + ty * o.d + o.ty)
    }

    /// The uniform scale it applies (scales about a point only).
    var scale: Double { (a * a + b * b).squareRoot() }

    /// Scale about `p`, then move by `offset`: the unit state's move.
    static func move(_ st: TextUnitState, about p: SIMD2<Double>) -> TextAffine {
        TextAffine(a: st.scale, b: 0, c: 0, d: st.scale, tx: p.x + st.offsetX - st.scale * p.x, ty: p.y + st.offsetY - st.scale * p.y)
    }

    func apply(_ r: TextRect) -> TextRect {
        let ps = [SIMD2(r.x, r.y), SIMD2(r.maxX, r.y), SIMD2(r.maxX, r.maxY), SIMD2(r.x, r.maxY)].map(apply)
        let lo = ps.dropFirst().reduce(ps[0]) { pointwiseMin($0, $1) }, hi = ps.dropFirst().reduce(ps[0]) { pointwiseMax($0, $1) }
        return TextRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }
}

/// `AnimatedGeometry` without Core Text: character advance boxes from the portable pen, unit centers, per-character
/// transforms and the raster bounds (the ink box grown by every moved or blurred character).
struct PortableAnimatedGeometry {
    let units: TextUnits
    let states: [TextCharacterState]
    let transforms: [TextAffine]
    let bounds: TextRect
    /// The advance box of every character in layout space.
    let characterRects: [TextRect]
    /// Per line: line-local UTF-16 offset -> character index (whitespace has none).
    let lineMaps: [[Int: Int]]

    init(layout: TextLayoutResult, style: TextStyle, glyphs: GlyphPlacer, ink: TextRect, scale s: Double,
         states: [TextCharacterState]) {
        let units = TextUnits.segment(layout)
        self.units = units
        self.states = states
        var maps = [[Int: Int]](repeating: [:], count: layout.lines.count)
        var rects: [TextRect] = []
        for c in units.characters {
            let l = layout.lines[c.line]
            let o = c.range.location - l.location + l.markerLength
            for k in 0..<c.range.length { maps[c.line][o + k] = c.index }
            let carets = glyphs.carets[c.line]
            let x0 = carets[o] ?? l.x, x1 = carets[o + c.range.length] ?? x0
            rects.append(TextRect(x: min(x0, x1), y: l.y, width: abs(x1 - x0), height: l.height))
        }
        lineMaps = maps
        characterRects = rects

        var unitRects: [TextAnimatorUnit: [Int: TextRect]] = [:]
        func centre(_ c: TextUnits.Character, _ unit: TextAnimatorUnit) -> SIMD2<Double> {
            if unitRects[unit] == nil {
                var r: [Int: TextRect] = [:]
                for ch in units.characters {
                    let i = units.index(of: ch, unit: unit)
                    r[i] = r[i].map { $0.union(rects[ch.index]) } ?? rects[ch.index]
                }
                unitRects[unit] = r
            }
            let r = unitRects[unit]![units.index(of: c, unit: unit)] ?? rects[c.index]
            return SIMD2(r.x + r.width / 2, r.y + r.height / 2)
        }

        var tr: [TextAffine] = []
        var b = layout.inkBounds
        for c in units.characters {
            let st = c.index < states.count ? states[c.index] : TextCharacterState(in: .rest, out: .rest)
            var t = TextAffine.identity
            if let u = st.inUnit, !st.in.isRest { t = t.then(.move(st.in, about: centre(c, u))) }
            if let u = st.outUnit, !st.out.isRest { t = t.then(.move(st.out, about: centre(c, u))) }
            tr.append(t)
            guard st.opacity > 0 else { continue }
            let blur = max(st.in.blur, st.out.blur)
            guard t != .identity || blur > 0 else { continue }
            let m = t.apply(TextLayout.inkRect(rects[c.index], style: style).expanded(by: blur * 1.5 + 1))
            if m.width > 0, m.height > 0, m.width.isFinite, m.height.isFinite { b = b.union(m) }
        }
        transforms = tr
        bounds = b
    }

    func state(_ c: Int) -> TextCharacterState {
        c < states.count ? states[c] : TextCharacterState(in: .rest, out: .rest)
    }
}
