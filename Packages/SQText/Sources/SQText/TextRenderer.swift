#if canImport(CoreText)
import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import Synchronization

/// Result of rasterizing a text block. Pixel (0, 0) is the top-left of `layout.inkBounds`; `originX/Y` is that
/// corner in layout space (sequence pixels, y down), so the caller places the image at block position + origin.
/// Pixels are premultiplied RGBA.
public struct TextRaster: @unchecked Sendable {
    public let layout: TextLayoutResult
    public let scale: Double
    /// Top-left of the raster in layout space (= `layout.inkBounds` origin), unscaled.
    public let originX: Double, originY: Double
    public let pixelWidth: Int, pixelHeight: Int
    /// 8-bit sRGB, premultiplied alpha (display/UI use, tests). Drawn when first asked for: playback and export only
    /// read `linearBuffer`, and drawing both doubled the cost of every raster.
    public var image: CGImage { lazyImage.value }
    let lazyImage: LazyTextImage
    /// Linear light (sRGB primaries, gamma removed), premultiplied, `kCVPixelFormatType_64RGBAHalf`,
    /// IOSurface-backed and Metal compatible. Compositor input (docs/ARCHITECTURE.md section 5).
    public let linearBuffer: CVPixelBuffer
    /// The whole raster this one was cut from (`originX/Y` and pixel size before the cut); the raster itself when it was
    /// not cut. Scale and rotation of a text layer pivot about the center of this rect, whatever part is kept.
    public let wholeOriginX: Double, wholeOriginY: Double
    public let wholePixelWidth: Int, wholePixelHeight: Int
}

/// Zero-filled pages for a drawing of which only a part is kept: pages nobody writes to are never backed by memory, so
/// a clipped drawing costs what it paints, not the size of the whole bitmap.
final class ScratchPages {
    let base: UnsafeMutableRawPointer
    let bytes: Int
    init?(bytes: Int) {
        guard bytes > 0, let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), p != MAP_FAILED else { return nil }
        base = p; self.bytes = bytes
    }
    deinit { munmap(base, bytes) }

    /// Bytes of the pages that are backed by memory right now.
    var residentBytes: Int {
        let page = Int(getpagesize()), n = (bytes + page - 1) / page
        var map = [CChar](repeating: 0, count: n)
        guard mincore(base, bytes, &map) == 0 else { return bytes }
        return map.reduce(0) { $0 + (($1 & 1) != 0 ? page : 0) }
    }
}

/// The 8-bit picture of a raster, drawn once on first use (any thread).
final class LazyTextImage: @unchecked Sendable {
    private let lock = NSLock()
    private var made: CGImage?
    private var make: (() -> CGImage?)?
    init(_ make: @escaping () -> CGImage?) { self.make = make }

    var value: CGImage {
        lock.lock(); defer { lock.unlock() }
        if let made { return made }
        // A context that cannot be made (out of memory) leaves one transparent pixel instead of a crash.
        let image = make?() ?? Self.empty
        made = image; make = nil
        return image
    }

    private static let empty: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
}

public enum TextRendererError: Error, Sendable {
    case bufferCreationFailed(Int32), contextCreationFailed
    /// The caller's memory budget (`admit`) had no room for this raster; nothing was allocated.
    case overBudget
}

/// Rasterizes `TextLayout` output with Core Graphics / Core Text (see docs/PHASE7.md "Text renderer").
public enum TextRenderer {
    /// Largest raster side in pixels.
    static let maxRasterSide = 16_384

    /// Returns nil for empty text / empty ink.
    /// - Parameter highlight: words of the text drawn in another fill color (karaoke); stroke and shadow are unchanged.
    public static func render(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil, scale: Double = 1,
                              highlight: TextHighlight? = nil) throws -> TextRaster? {
        let highlight = style.drawn(highlight: highlight)
        let style = style.drawn      // a footage fill is a plain glyph
        let layout = TextLayout.layout(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight)
        guard !layout.lines.isEmpty else { return nil }
        return try rasterize(layout: layout, bounds: layout.inkBounds, scale: scale) { ctx, s, space in
            draw(layout: layout, style: style, highlight: highlight, into: ctx, scale: s, space: space)
        }
    }

    /// Creates the 8-bit image and the linear half-float buffer of `bounds` (layout space) and runs `draw` into each
    /// (the closure gets the context, the clamped scale and the sRGB color space the style colors are in).
    /// `crop` (layout space, on the pixel grid of `bounds`): only that part is kept. The drawing still happens in a
    /// context the size of `bounds`, clipped to the part, so every shape is rasterized at the device coordinates it has
    /// in the whole raster and the kept pixels are bit for bit the same (a smaller context shifts them, and Core Graphics
    /// rounds a stroke's coverage differently then); the clip is what makes it cheap, and the context's memory are pages
    /// that only exist where the drawing wrote (`ScratchPages`).
    /// `admit` gets the bytes this raster is about to take (buffer plus the pages of a cut drawing) before anything is
    /// allocated; false throws `overBudget`.
    static func rasterize(layout: TextLayoutResult, bounds ink: TextRect, scale: Double, crop: TextRect? = nil,
                          admit: ((Int) -> Bool)? = nil,
                          draw: @escaping (CGContext, Double, CGColorSpace) -> Void) throws -> TextRaster? {
        guard scale.isFinite, ink.width.isFinite, ink.height.isFinite, ink.x.isFinite, ink.y.isFinite else { return nil }
        if let crop, !(crop.x.isFinite && crop.y.isFinite && crop.width.isFinite && crop.height.isFinite) { return nil }
        let s = max(0.01, scale)
        let rawW = (ink.width * s).rounded(.up), rawH = (ink.height * s).rounded(.up)
        guard rawW.isFinite, rawH.isFinite, rawW > 0, rawH > 0 else { return nil }
        // Hard cap on one raster side: a hostile size or scale must not reach the integer conversion or an allocation.
        guard rawW <= Double(maxRasterSide), rawH <= Double(maxRasterSide) else { throw TextRendererError.overBudget }
        let fullW = Int(rawW), fullH = Int(rawH)
        var cx = 0, cy = 0, w = fullW, h = fullH
        if let crop {
            // Outward to whole pixels: the whole raster is rounded up too, so its last, partly covered column is kept.
            let e = 1e-6
            cx = min(fullW - 1, max(0, Int(((crop.x - ink.x) * s + e).rounded(.down))))
            cy = min(fullH - 1, max(0, Int(((crop.y - ink.y) * s + e).rounded(.down))))
            w = min(fullW - cx, max(1, Int(((crop.x + crop.width - ink.x) * s - e).rounded(.up)) - cx))
            h = min(fullH - cy, max(1, Int(((crop.y + crop.height - ink.y) * s - e).rounded(.up)) - cy))
        }
        let cropped = w != fullW || h != fullH
        // Device space (y up) of the kept part.
        let keep = CGRect(x: cx, y: fullH - cy - h, width: w, height: h)
        let (area, areaOverflow) = w.multipliedReportingOverflow(by: h)
        let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: cropped ? 16 : 8)
        if areaOverflow || bytesOverflow { throw TextRendererError.overBudget }
        if let admit, !admit(bytes) { throw TextRendererError.overBudget }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

        let image = LazyTextImage {
            let ctx8 = CGContext(data: nil, width: fullW, height: fullH, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let ctx8 else { return nil }
            if cropped { ctx8.clip(to: keep) }
            draw(ctx8, s, srgb)
            let whole = ctx8.makeImage()
            return cropped ? whole?.cropping(to: CGRect(x: cx, y: cy, width: w, height: h)) : whole
        }

        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw TextRendererError.bufferCreationFailed(st) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        if cropped {
            let fromRow = fullW * 8
            let (scratchBytes, scratchOverflow) = fromRow.multipliedReportingOverflow(by: fullH)
            guard !scratchOverflow else { throw TextRendererError.overBudget }
            guard let pages = ScratchPages(bytes: scratchBytes),
                  let ctxF = CGContext(data: pages.base, width: fullW, height: fullH, bitsPerComponent: 16, bytesPerRow: fromRow,
                                       space: linear, bitmapInfo: info), let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw TextRendererError.contextCreationFailed
            }
            ctxF.clip(to: keep)
            draw(ctxF, s, srgb)
            ctxF.flush()
            // Bitmap memory is top row first, like the buffer.
            let toRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<h { memcpy(base + y * toRow, pages.base + (cy + y) * fromRow + cx * 8, w * 8) }
            scratchProbe.withLock { $0?(pages.residentBytes, w * h * 8, pages.bytes) }
        } else {
            guard let ctxF = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 16,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: linear, bitmapInfo: info) else {
                throw TextRendererError.contextCreationFailed
            }
            draw(ctxF, s, srgb)
        }

        return TextRaster(layout: layout, scale: s, originX: ink.x + Double(cx) / s, originY: ink.y + Double(cy) / s,
                          pixelWidth: w, pixelHeight: h, lazyImage: image, linearBuffer: buffer,
                          wholeOriginX: ink.x, wholeOriginY: ink.y, wholePixelWidth: fullW, wholePixelHeight: fullH)
    }

    /// Tests: called after every cut drawing with the bytes of its scratch pages that got backed by memory, the bytes
    /// kept and the bytes of the whole bitmap.
    static let scratchProbe = Mutex<(@Sendable (_ resident: Int, _ kept: Int, _ whole: Int) -> Void)?>(nil)

    static func cg(_ c: RGBAColor, _ space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [c.red, c.green, c.blue, c.alpha].map { CGFloat($0) })!
    }

    /// `space` is the colorspace the style's sRGB colors are expressed in (CG converts to the context's space).
    private static func draw(layout: TextLayoutResult, style: TextStyle, highlight: TextHighlight?, into ctx: CGContext,
                             scale s: Double, space: CGColorSpace) {
        let ink = layout.inkBounds
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
        // Glyph origins unquantized, as `glyphPath` (gradient fills) and the portable raster place them; with quantizing
        // solid glyphs sat up to 1 px left of gradient glyphs and of the Windows picture.
        ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)

        // Spread ("Size"): the shadow comes from the grown glyph shape, drawn far outside the raster so that only its offset,
        // blurred shadow lands (same trick as the animator path). The glyphs themselves are drawn below, without a CG shadow.
        let spreadShadow = highlight?.onlyLit == true ? nil : style.shadow.flatMap { $0.spread > 0 ? $0 : nil }
        if let sh = spreadShadow {
            let away = (ink.width + ink.height) * 2 + 1000
            let (shadowLines, _) = ctLines(layout: layout, style: style, highlight: nil, space: space)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: (sh.offsetX + away) * s, height: -sh.offsetY * s), blur: sh.blur * s,
                          color: cg(sh.color, space))
            ctx.translateBy(x: 0, y: CGFloat(ctx.height))
            ctx.scaleBy(x: CGFloat(s), y: CGFloat(-s))
            ctx.translateBy(x: CGFloat(-ink.x - away), y: CGFloat(-ink.y))
            let solid = CGColor(colorSpace: space, components: [0, 0, 0, 1])!
            ctx.setFillColor(solid); ctx.setStrokeColor(solid)
            ctx.setLineWidth(CGFloat(sh.spread * 2))
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.setTextDrawingMode(.fillStroke)
            for (ct, l) in shadowLines {
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: l.x, y: l.y + l.baseline)
                CTLineDraw(ct, ctx)
            }
            if highlight?.onlyLit != true {
                for b in TextDecorations.bars(layout: layout, style: style) {
                    let r = CGRect(x: b.rect.x, y: b.rect.y, width: b.rect.width, height: b.rect.height)
                    ctx.fill(r); ctx.stroke(r)
                }
            }
            ctx.restoreGState()
        }
        // CG shadow offsets are in device space, y up; layout offsets are y down. blur = full radius in layout px.
        if let sh = style.shadow, highlight?.onlyLit != true, spreadShadow == nil {
            ctx.setShadow(offset: CGSize(width: sh.offsetX * s, height: -sh.offsetY * s), blur: sh.blur * s,
                          color: cg(sh.color, space))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // shadow is cast by the whole group
        // Layout space: origin top-left of the ink rect, y down.
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(-s))
        ctx.translateBy(x: CGFloat(-ink.x), y: CGFloat(-ink.y))

        if let bg = style.background, let r = layout.backgroundRect, highlight?.onlyLit != true {
            fillBackground(bg, block: r, layout: layout, style: style, highlight: highlight, ctx: ctx, space: space)
        }

        let (lines, fillLines) = ctLines(layout: layout, style: style, highlight: highlight, space: space)
        let onlyLit = highlight?.onlyLit == true
        func drawLines(_ mode: CGTextDrawingMode, _ set: [(CTLine, TextLine)]) {
            ctx.setTextDrawingMode(mode)
            for (ct, l) in set {
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // text space is y up, CTM is y down
                ctx.textPosition = CGPoint(x: l.x, y: l.y + l.baseline)
                CTLineDraw(ct, ctx)
            }
        }
        let stroke = onlyLit ? nil : style.stroke.flatMap { $0.width > 0 ? $0 : nil }
        func strokePass(_ st: TextStroke) {
            ctx.setStrokeColor(cg(st.color, space))
            // Outside: twice the width, the inner half is covered by the fill drawn after it. Centered: the width itself,
            // drawn over the fill.
            ctx.setLineWidth(CGFloat(st.position == .outside ? st.width * 2 : st.width))
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            drawLines(.stroke, lines)
        }
        // Line styles (underline, strikethrough, overline): rects in the line's fill color, outlined like the glyphs.
        let bars = onlyLit ? [] : TextDecorations.bars(layout: layout, style: style)
        func barRects(stroked: Bool) {
            for b in bars {
                let r = CGRect(x: b.rect.x, y: b.rect.y, width: b.rect.width, height: b.rect.height)
                if stroked { ctx.stroke(r) } else {
                    ctx.setFillColor(cg(style.lineStyle(b.styleIndex).color, space)); ctx.fill(r)
                }
            }
        }
        if let st = stroke, st.position == .outside { strokePass(st); if !bars.isEmpty { barRects(stroked: true) } }
        if let g = style.gradient, highlight == nil, let block = Self.lineBlock(layout) {
            // Gradient fill: the glyphs become the clip, the gradient is painted across the block.
            ctx.saveGState()
            // The glyph outlines as a path: Core Graphics' `.clip` text mode left the clip unset, so the gradient
            // covered the whole raster.
            ctx.addPath(Self.glyphPath(fillLines))
            ctx.clip()
            let a = g.axis(in: block)
            if let grad = CGGradient(colorsSpace: space, colors: [cg(g.start, space), cg(g.end, space)] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: a.start.x, y: a.start.y), end: CGPoint(x: a.end.x, y: a.end.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        } else {
            ctx.setFillColor(cg(style.color, space))
            drawLines(.fill, fillLines)
        }
        barRects(stroked: false)
        if let st = stroke, st.position == .centre { strokePass(st); if !bars.isEmpty { barRects(stroked: true) } }
        ctx.endTransparencyLayer()
    }

    /// The outlines of every glyph of `lines` in layout space (y down), placed as `CTLineDraw` places them.
    static func glyphPath(_ lines: [(CTLine, TextLine)]) -> CGPath {
        let path = CGMutablePath()
        for (ct, l) in lines {
            for run in (CTLineGetGlyphRuns(ct) as? [CTRun]) ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0, let attrs = CTRunGetAttributes(run) as? [CFString: Any],
                      let fontRef = attrs[kCTFontAttributeName] else { continue }
                let font = fontRef as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
                for i in 0..<n {
                    var t = CGAffineTransform(translationX: l.x + pos[i].x, y: l.y + l.baseline - pos[i].y).scaledBy(x: 1, y: -1)
                    if let g = CTFontCreatePathForGlyph(font, glyphs[i], &t) { path.addPath(g) }
                }
            }
        }
        return path
    }

    /// The union of the line boxes (the block a gradient fill spans), nil without lines.
    static func lineBlock(_ layout: TextLayoutResult) -> TextRect? {
        var block: TextRect?
        for l in layout.lines { block = block.map { $0.union(l.rect) } ?? l.rect }
        return block
    }

    /// The background: one rounded box around the block, or (per-word pill) one box per word, filled as one path so the
    /// translucent color never doubles where two boxes meet.
    static func fillBackground(_ bg: TextBackground, block r: TextRect, layout: TextLayoutResult, style: TextStyle,
                               highlight: TextHighlight?, ctx: CGContext, space: CGColorSpace) {
        ctx.setFillColor(cg(bg.color, space))
        let words = TextWordRects.wantsPerWord(highlight, style: style) ? TextWordRects.rects(layout: layout, style: style) : []
        for w in words.isEmpty ? [r] : words {
            let rect = CGRect(x: w.x, y: w.y, width: w.width, height: w.height)
            let rad = min(bg.cornerRadius, min(rect.width, rect.height) / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
        }
        ctx.fillPath()
    }

    /// The Core Text lines of `layout`: `plain` follows the context color (stroke pass), `fill` carries the karaoke
    /// colors when there is a highlight (empty for an `onlyLit` highlight without lit words).
    static func ctLines(layout: TextLayoutResult, style: TextStyle, highlight: TextHighlight?,
                        space: CGColorSpace) -> (plain: [(CTLine, TextLine)], fill: [(CTLine, TextLine)]) {
        // Two-style text: each line in its own font and fill color (`TextLine.styleIndex`).
        let fonts = (0..<style.lineStyleCount).map { TextLayout.makeFont(style.lineStyle($0)) }
        func font(_ l: TextLine) -> CTFont { fonts[min(l.styleIndex, fonts.count - 1)] }
        let lines: [(CTLine, TextLine)] = layout.lines.compactMap { l in
            guard !l.text.isEmpty else { return nil }
            var attrs = TextLayout.attributes(font: font(l), tracking: style.tracking, rightToLeft: l.isRightToLeft)
            attrs[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
            let attr = NSAttributedString(string: l.text, attributes: attrs)
            return (CTLineCreateWithAttributedString(attr), l)
        }
        // Karaoke: the lit words carry their own foreground color, everything else follows the context fill. Words are
        // counted over all lines in reading order, so the same highlight means the same words in the monitor and export.
        // The word spans come from the layout (found once on the original text), so the same highlight means the same words
        // in the monitor and in the export, and a word the wrap broke across lines is lit on both lines. Every run gets an
        // explicit color (CTLineDraw leaves the last run's color in the context). `onlyLit` draws just the lit words.
        let onlyLit = highlight?.onlyLit == true
        let fillLines: [(CTLine, TextLine)]
        if let h = highlight, !h.words.isEmpty {
            let lit = h.words.compactMap { layout.wordSpans.indices.contains($0) ? layout.wordSpans[$0] : nil }
            let clear = CGColor(colorSpace: space, components: [0, 0, 0, 0])!
            fillLines = lines.map { (_, l) in
                let base = onlyLit ? clear : cg(style.lineStyle(l.styleIndex).color, space)
                var attrs = TextLayout.attributes(font: font(l), tracking: style.tracking, rightToLeft: l.isRightToLeft)
                attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = base
                let attr = NSMutableAttributedString(string: l.text, attributes: attrs)
                let lineRange = NSRange(location: l.location, length: (l.content as NSString).length)
                for span in lit {
                    let x = NSIntersectionRange(span, lineRange)
                    guard x.length > 0 else { continue }
                    attr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: cg(h.color, space),
                                      range: NSRange(location: x.location - l.location + l.markerLength, length: x.length))
                }
                return (CTLineCreateWithAttributedString(attr), l)
            }
        } else if onlyLit {
            fillLines = []
        } else if style.hasLineLooks {
            // Every line carries its own fill color (the context fill is the clip style's).
            fillLines = lines.map { (_, l) in
                var attrs = TextLayout.attributes(font: font(l), tracking: style.tracking, rightToLeft: l.isRightToLeft)
                attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = cg(style.lineStyle(l.styleIndex).color, space)
                return (CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: attrs)), l)
            }
        } else { fillLines = lines }

        return (lines, fillLines)
    }
}
#endif
