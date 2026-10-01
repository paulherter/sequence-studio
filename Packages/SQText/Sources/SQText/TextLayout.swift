import Foundation
import CoreText

/// Rectangle in layout space: sequence pixels (points = pixels, scale 1), origin top-left, y down.
/// See docs/ARCHITECTURE.md "Coordinate convention". Renderers convert to Core Graphics/Metal at their own boundary.
public struct TextRect: Sendable, Hashable, Codable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let zero = TextRect(x: 0, y: 0, width: 0, height: 0)
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public func expanded(left: Double, top: Double, right: Double, bottom: Double) -> TextRect {
        TextRect(x: x - left, y: y - top, width: width + left + right, height: height + top + bottom)
    }
    public func expanded(by d: Double) -> TextRect { expanded(left: d, top: d, right: d, bottom: d) }
    public func offsetBy(dx: Double, dy: Double) -> TextRect { TextRect(x: x + dx, y: y + dy, width: width, height: height) }
    public func union(_ o: TextRect) -> TextRect {
        let x0 = min(x, o.x), y0 = min(y, o.y), x1 = max(maxX, o.maxX), y1 = max(maxY, o.maxY)
        return TextRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// One laid-out line. Coordinates: sequence pixels (points = pixels), origin top-left, y grows downward.
/// The layout origin (0, 0) is the top-left of the text block; callers place the block in the sequence.
public struct TextLine: Sendable, Hashable {
    /// Line content without the trailing whitespace that caused the wrap.
    public let text: String
    /// Aligned left edge.
    public let x: Double
    /// Top of the line box.
    public let y: Double
    /// Typographic width (trailing whitespace excluded).
    public let width: Double
    /// ascent + descent of the runs actually used on this line (fallback fonts such as emoji included, never
    /// less than the main font); no leading / line spacing.
    public let height: Double
    /// Distance from `y` to the baseline.
    public let baseline: Double
    /// UTF-16 offset of `text` in `TextLayoutResult.displayText` (so word spans can be mapped onto the line).
    public let location: Int
    public var rect: TextRect { TextRect(x: x, y: y, width: width, height: height) }
    /// `rect` grown by the style's stroke width and shadow (offset + blur); equals `rect` without either.
    public let inkBounds: TextRect
}

public struct TextLayoutResult: Sendable, Hashable {
    public let lines: [TextLine]
    /// Union of all line rects (tight around the text, without stroke/shadow).
    public let bounds: TextRect
    /// Everything that can be painted: text, stroke, background box and shadow (offset + blur). Use for clipping
    /// and dirty regions. Equals `bounds` for a plain style; nil-text gives `.zero`.
    public let inkBounds: TextRect
    /// `bounds` expanded by the style's background padding; nil without background or text.
    public let backgroundRect: TextRect?
    /// The text as drawn (capitals when the style says All Caps; the stored text is untouched).
    public let displayText: String
    /// UTF-16 ranges of the words in `displayText`, found once on the original text with one whitespace definition
    /// (`Character.isWhitespace`, the same as `CaptionItem.tokens`). A word the wrap breaks across lines stays one word.
    public let wordSpans: [NSRange]
}

/// Deterministic pure function of (text, style, maxWidth), built on Core Text.
///
/// Coordinate convention (docs/ARCHITECTURE.md): all output is in sequence pixels (font size and widths are
/// points = pixels, scale 1), origin top-left of the text block, y down. Core Text's y-up baseline metrics are
/// converted here; no consumer needs to flip.
public enum TextLayout {
    /// - Parameter maxWidth: wrap width in points; nil disables wrapping. Also the alignment container
    ///   (nil: the widest line).
    /// - Parameter boxHeight: area text: the box is `maxWidth` x `boxHeight`; the block is placed in it by
    ///   `style.verticalAlignment` and `bounds` is the box. Without it (point text, or a wrap width only) the block is
    ///   the text itself.
    public static func layout(text original: String, style: TextStyle, maxWidth: Double?, boxHeight: Double? = nil) -> TextLayoutResult {
        // All caps changes the glyphs only: the caller keeps the text as typed, the layout (and so the renderer, which
        // draws the line texts) sees the capitals.
        let (text, wordSpans) = TextWords.display(original, allCaps: style.allCaps)
        let font = makeFont(style)
        let fontAscent = CTFontGetAscent(font), fontDescent = CTFontGetDescent(font), fontLeading = CTFontGetLeading(font)
        let wrap = maxWidth.map { max(1, $0) } ?? Double.greatestFiniteMagnitude

        var raw: [Measured] = []
        if !text.isEmpty {
            var base = 0
            for para in text.components(separatedBy: "\n") {
                if para.isEmpty { raw.append(Measured(text: "", width: 0, ascent: 0, descent: 0, leading: 0, location: base)) }
                else { raw.append(contentsOf: wrapParagraph(para, base: base, font: font, maxWidth: wrap, tracking: style.tracking)) }
                base += para.utf16.count + 1
            }
        }
        guard !raw.isEmpty else {
            return TextLayoutResult(lines: [], bounds: .zero, inkBounds: .zero, backgroundRect: nil, displayText: text, wordSpans: wordSpans)
        }

        let container = maxWidth.map { max(1, $0) } ?? raw.map(\.width).max()!
        var lines: [TextLine] = []
        var y = 0.0
        for m in raw {
            // Runs in fallback fonts (emoji, CJK) may be taller than the main font; never shorter than it.
            let ascent = max(fontAscent, m.ascent), descent = max(fontDescent, m.descent)
            let leading = max(fontLeading, m.leading)
            let x: Double
            switch style.alignment {
            case .left: x = 0
            case .center: x = (container - m.width) / 2
            case .right: x = container - m.width
            }
            let box = TextRect(x: x, y: y, width: m.width, height: ascent + descent)
            lines.append(TextLine(text: m.text, x: x, y: y, width: m.width, height: ascent + descent, baseline: ascent,
                                  location: m.location, inkBounds: inkRect(box, style: style)))
            y += ascent + descent + leading + style.lineSpacing
        }
        let minX = lines.map(\.x).min()!, maxX = lines.map { $0.x + $0.width }.max()!
        var textBounds = TextRect(x: minX, y: 0, width: maxX - minX, height: lines.last!.rect.maxY - lines[0].y)
        var bounds = textBounds
        if let boxH = boxHeight, let w = maxWidth {
            let h = max(1, boxH), cw = max(1, w)
            let dy: Double
            switch style.verticalAlignment {
            case .top: dy = 0
            case .middle: dy = (h - textBounds.height) / 2
            case .bottom: dy = h - textBounds.height
            }
            if dy != 0 {
                lines = lines.map {
                    TextLine(text: $0.text, x: $0.x, y: $0.y + dy, width: $0.width, height: $0.height, baseline: $0.baseline,
                             location: $0.location, inkBounds: $0.inkBounds.offsetBy(dx: 0, dy: dy))
                }
                textBounds = textBounds.offsetBy(dx: 0, dy: dy)
            }
            bounds = TextRect(x: 0, y: 0, width: cw, height: h)
        }
        var bg: TextRect?
        if let b = style.background {
            bg = TextRect(x: textBounds.x - b.padding.horizontal, y: textBounds.y - b.padding.vertical,
                          width: textBounds.width + 2 * b.padding.horizontal, height: textBounds.height + 2 * b.padding.vertical)
        }
        let ink = inkRect(bounds.union(textBounds).union(bg ?? textBounds), style: style)
        return TextLayoutResult(lines: lines, bounds: bounds, inkBounds: ink, backgroundRect: bg, displayText: text, wordSpans: wordSpans)
    }

    /// `rect` grown by how far the stroke reaches (its width outside, half of it centred) and united with its shadow.
    /// Shadow offset is in layout space (positive y = down); blur is taken as full radius.
    static func inkRect(_ rect: TextRect, style: TextStyle) -> TextRect {
        let grown = rect.expanded(by: style.stroke?.reach ?? 0)
        guard let sh = style.shadow else { return grown }
        return grown.union(grown.offsetBy(dx: sh.offsetX, dy: sh.offsetY).expanded(by: sh.blur))
    }

    static func makeFont(_ style: TextStyle) -> CTFont { FontResolver.font(for: style) }

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)].isWhitespace { end = s.index(before: end) }
        return String(s[..<end])
    }

    private struct Measured {
        var text: String
        var width: Double
        var ascent: Double, descent: Double, leading: Double
        var location: Int
    }

    static func attributes(font: CTFont, tracking: Double) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if tracking != 0 { a[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        return a
    }

    private static func wrapParagraph(_ para: String, base: Int, font: CTFont, maxWidth: Double, tracking: Double) -> [Measured] {
        let attr = NSAttributedString(string: para, attributes: attributes(font: font, tracking: tracking))
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let ns = para as NSString
        var out: [Measured] = []
        var start = 0
        while start < ns.length {
            var count = CTTypesetterSuggestLineBreak(ts, start, maxWidth)
            if count < 1 { count = 1 }
            let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
            // Typographic bounds cover all runs actually used, including fallback fonts.
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let full = CTLineGetTypographicBounds(line, &a, &d, &l)
            let w = max(0, full - CTLineGetTrailingWhitespaceWidth(line))
            let piece = ns.substring(with: NSRange(location: start, length: count))
            // Leading whitespace is significant (drawn and measured); only the wrap-causing trailing run is dropped.
            out.append(Measured(text: trimTrailingWhitespace(piece), width: w, ascent: a, descent: d, leading: l, location: base + start))
            start += count
        }
        return out
    }
}

/// Words of a text. One definition for the whole app: `Character.isWhitespace` separates words.
public enum TextWords {
    /// The text as drawn and the UTF-16 spans of its words, computed once. With `allCaps` each character is
    /// capitalised on its own, so a length-changing capital ("ß" becomes "SS") moves the spans but never splits or
    /// merges a word, and the spans still describe the words of the original text.
    public static func display(_ original: String, allCaps: Bool) -> (text: String, spans: [NSRange]) {
        var out = "", spans: [NSRange] = []
        var start: Int?
        var length = 0
        for ch in original {
            let piece = allCaps ? String(ch).uppercased() : String(ch)
            if ch.isWhitespace {
                if let st = start { spans.append(NSRange(location: st, length: length - st)); start = nil }
            } else if start == nil { start = length }
            out += piece
            length += piece.utf16.count
        }
        if let st = start { spans.append(NSRange(location: st, length: length - st)) }
        return (out, spans)
    }
}
