import Foundation
import CoreGraphics
import CoreText
import CoreVideo

/// Result of rasterizing a text block. Pixel (0, 0) is the top-left of `layout.inkBounds`; `originX/Y` is that
/// corner in layout space (sequence pixels, y down), so the caller places the image at block position + origin.
/// Pixels are premultiplied RGBA.
public struct TextRaster: @unchecked Sendable {
    public let layout: TextLayoutResult
    public let scale: Double
    /// Top-left of the raster in layout space (= `layout.inkBounds` origin), unscaled.
    public let originX: Double, originY: Double
    public let pixelWidth: Int, pixelHeight: Int
    /// 8-bit sRGB, premultiplied alpha (display/UI use, tests).
    public let image: CGImage
    /// Linear light (sRGB primaries, gamma removed), premultiplied, `kCVPixelFormatType_64RGBAHalf`,
    /// IOSurface-backed and Metal compatible. Compositor input (docs/ARCHITECTURE.md section 5).
    public let linearBuffer: CVPixelBuffer
}

public enum TextRendererError: Error, Sendable { case bufferCreationFailed(Int32), contextCreationFailed }

/// Rasterizes `TextLayout` output with Core Graphics / Core Text (see docs/PHASE7.md "Text renderer").
public enum TextRenderer {
    /// Returns nil for empty text / empty ink.
    /// - Parameter highlight: words of the text drawn in another fill colour (karaoke); stroke and shadow are unchanged.
    public static func render(text: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil, scale: Double = 1,
                              highlight: TextHighlight? = nil) throws -> TextRaster? {
        let layout = TextLayout.layout(text: text, style: style, maxWidth: maxWidth, boxHeight: boxHeight)
        let ink = layout.inkBounds
        let s = max(0.01, scale)
        let w = Int((ink.width * s).rounded(.up)), h = Int((ink.height * s).rounded(.up))
        guard !layout.lines.isEmpty, w > 0, h > 0 else { return nil }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

        guard let ctx8 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TextRendererError.contextCreationFailed
        }
        draw(layout: layout, style: style, highlight: highlight, into: ctx8, scale: s, space: srgb)
        guard let image = ctx8.makeImage() else { throw TextRendererError.contextCreationFailed }

        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else { throw TextRendererError.bufferCreationFailed(st) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctxF = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 16,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: linear, bitmapInfo: info) else {
            throw TextRendererError.contextCreationFailed
        }
        draw(layout: layout, style: style, highlight: highlight, into: ctxF, scale: s, space: srgb)

        return TextRaster(layout: layout, scale: s, originX: ink.x, originY: ink.y,
                          pixelWidth: w, pixelHeight: h, image: image, linearBuffer: buffer)
    }

    private static func cg(_ c: RGBAColor, _ space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [c.red, c.green, c.blue, c.alpha].map { CGFloat($0) })!
    }

    /// `space` is the colorspace the style's sRGB colors are expressed in (CG converts to the context's space).
    private static func draw(layout: TextLayoutResult, style: TextStyle, highlight: TextHighlight?, into ctx: CGContext,
                             scale s: Double, space: CGColorSpace) {
        let ink = layout.inkBounds
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)

        // CG shadow offsets are in device space, y up; layout offsets are y down. blur = full radius in layout px.
        if let sh = style.shadow, highlight?.onlyLit != true {
            ctx.setShadow(offset: CGSize(width: sh.offsetX * s, height: -sh.offsetY * s), blur: sh.blur * s,
                          color: cg(sh.color, space))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // shadow is cast by the whole group
        // Layout space: origin top-left of the ink rect, y down.
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(-s))
        ctx.translateBy(x: CGFloat(-ink.x), y: CGFloat(-ink.y))

        if let bg = style.background, let r = layout.backgroundRect, highlight?.onlyLit != true {
            let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            let rad = min(bg.cornerRadius, min(rect.width, rect.height) / 2)
            ctx.setFillColor(cg(bg.color, space))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.fillPath()
        }

        let font = TextLayout.makeFont(style)
        let lines: [(CTLine, TextLine)] = layout.lines.compactMap { l in
            guard !l.text.isEmpty else { return nil }
            var attrs = TextLayout.attributes(font: font, tracking: style.tracking)
            attrs[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
            let attr = NSAttributedString(string: l.text, attributes: attrs)
            return (CTLineCreateWithAttributedString(attr), l)
        }
        func drawLines(_ mode: CGTextDrawingMode, _ set: [(CTLine, TextLine)]) {
            ctx.setTextDrawingMode(mode)
            for (ct, l) in set {
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // text space is y up, CTM is y down
                ctx.textPosition = CGPoint(x: l.x, y: l.y + l.baseline)
                CTLineDraw(ct, ctx)
            }
        }
        // Karaoke: the lit words carry their own foreground colour, everything else follows the context fill. Words are
        // counted over all lines in reading order, so the same highlight means the same words in the monitor and export.
        // The word spans come from the layout (found once on the original text), so the same highlight means the same words
        // in the monitor and in the export, and a word the wrap broke across lines is lit on both lines. Every run gets an
        // explicit colour (CTLineDraw leaves the last run's colour in the context). `onlyLit` draws just the lit words.
        let onlyLit = highlight?.onlyLit == true
        let fillLines: [(CTLine, TextLine)]
        if let h = highlight, !h.words.isEmpty {
            let lit = h.words.compactMap { layout.wordSpans.indices.contains($0) ? layout.wordSpans[$0] : nil }
            let clear = CGColor(colorSpace: space, components: [0, 0, 0, 0])!
            let base = onlyLit ? clear : cg(style.color, space)
            fillLines = lines.map { (_, l) in
                var attrs = TextLayout.attributes(font: font, tracking: style.tracking)
                attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = base
                let attr = NSMutableAttributedString(string: l.text, attributes: attrs)
                let lineRange = NSRange(location: l.location, length: (l.text as NSString).length)
                for span in lit {
                    let x = NSIntersectionRange(span, lineRange)
                    guard x.length > 0 else { continue }
                    attr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: cg(h.color, space),
                                      range: NSRange(location: x.location - l.location, length: x.length))
                }
                return (CTLineCreateWithAttributedString(attr), l)
            }
        } else { fillLines = onlyLit ? [] : lines }

        let stroke = onlyLit ? nil : style.stroke.flatMap { $0.width > 0 ? $0 : nil }
        func strokePass(_ st: TextStroke) {
            ctx.setStrokeColor(cg(st.color, space))
            // Outside: twice the width, the inner half is covered by the fill drawn after it. Centred: the width itself,
            // drawn over the fill.
            ctx.setLineWidth(CGFloat(st.position == .outside ? st.width * 2 : st.width))
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            drawLines(.stroke, lines)
        }
        if let st = stroke, st.position == .outside { strokePass(st) }
        ctx.setFillColor(cg(style.color, space))
        drawLines(.fill, fillLines)
        if let st = stroke, st.position == .centre { strokePass(st) }
        ctx.endTransparencyLayer()
    }
}
