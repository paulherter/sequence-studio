import Foundation
#if canImport(CoreText)
import CoreText
import CoreGraphics
#endif

/// Per-word background rectangles (the per-word pill of a karaoke caption): one rounded box around each word instead of one
/// around the whole block. Pure function of the layout and the style, so monitor and burn-in draw the same pills.
public enum TextWordRects {
    /// The pill rectangles of `layout`, in layout space: one per word and line (a word the wrap broke across two lines gets a
    /// box on each). Words are in reading order. Empty without a background, without text or with fewer than two words.
    /// The horizontal padding is the style's, narrowed so that neighboring pills on a line keep a small gap and never merge.
    public static func rects(layout: TextLayoutResult, style: TextStyle) -> [TextRect] {
        guard let bg = style.background, layout.wordSpans.count > 1, !layout.lines.isEmpty else { return [] }
        var ink: [TextRect] = []              // the words' own extents
        var lineOf: [Int] = []
        for (offset, l) in lineOffsets(layout: layout, style: style) {
            let lineRange = NSRange(location: l.location, length: (l.content as NSString).length)
            for span in layout.wordSpans {
                let x = NSIntersectionRange(span, lineRange)
                guard x.length > 0 else { continue }
                let a = offset(x.location - l.location + l.markerLength)
                let b = offset(x.location - l.location + l.markerLength + x.length)
                guard b > a else { continue }
                ink.append(TextRect(x: l.x + Double(a), y: l.y, width: Double(b - a), height: l.height))
                lineOf.append(l.location)
            }
        }
        guard !ink.isEmpty else { return [] }
        // Smallest gap between two neighbors on one line; the padding may use at most half of it, less a hairline.
        var minGap = Double.greatestFiniteMagnitude
        for (k, r) in ink.enumerated() where k > 0 && lineOf[k] == lineOf[k - 1] {
            minGap = min(minGap, r.x - ink[k - 1].maxX)
        }
        let hairline = max(1, style.size * 0.03)
        let padX = minGap == .greatestFiniteMagnitude ? bg.padding.horizontal
            : min(bg.padding.horizontal, max(0, minGap / 2 - hairline))
        return ink.map { $0.expanded(left: padX, top: bg.padding.vertical, right: padX, bottom: bg.padding.vertical) }
    }

    /// Per drawn line: the x offset (layout px from `TextLine.x`) of a UTF-16 index of its text.
    static func lineOffsets(layout: TextLayoutResult, style: TextStyle) -> [((Int) -> Double, TextLine)] {
        #if canImport(CoreText)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return TextRenderer.ctLines(layout: layout, style: style, highlight: nil, space: srgb).plain.map { ct, l in
            ({ Double(CTLineGetOffsetForStringIndex(ct, $0, nil)) }, l)
        }
        #else
        return layout.lines.filter { !$0.text.isEmpty }.map { l in
            let ts = TextLayout.typesetter(l.text, font: TextLayout.makeFont(style.lineStyle(l.styleIndex)),
                                           tracking: style.tracking, rightToLeft: l.isRightToLeft)
            return ({ ts.line(location: 0, length: $0).width }, l)
        }
        #endif
    }

    /// True when `highlight` asks for pills per word and `style` has a background.
    static func wantsPerWord(_ highlight: TextHighlight?, style: TextStyle) -> Bool {
        highlight?.perWordPill == true && style.background != nil
    }
}
