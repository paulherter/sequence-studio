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
    /// ascent + descent (no leading / line spacing).
    public let height: Double
    /// Distance from `y` to the baseline.
    public let baseline: Double
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
}

/// Deterministic pure function of (text, style, maxWidth), built on Core Text.
///
/// Coordinate convention (docs/ARCHITECTURE.md): all output is in sequence pixels (font size and widths are
/// points = pixels, scale 1), origin top-left of the text block, y down. Core Text's y-up baseline metrics are
/// converted here; no consumer needs to flip.
public enum TextLayout {
    /// - Parameter maxWidth: wrap width in points; nil disables wrapping. Also the alignment container
    ///   (nil: the widest line).
    public static func layout(text: String, style: TextStyle, maxWidth: Double?) -> TextLayoutResult {
        let font = makeFont(style)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let pitch = ascent + descent + leading + style.lineSpacing
        let wrap = maxWidth.map { max(1, $0) } ?? Double.greatestFiniteMagnitude

        // (text, width) per line
        var raw: [(String, Double)] = []
        if !text.isEmpty {
            for para in text.components(separatedBy: "\n") {
                if para.isEmpty { raw.append(("", 0)); continue }
                raw.append(contentsOf: wrapParagraph(para, font: font, maxWidth: wrap))
            }
        }
        guard !raw.isEmpty else { return TextLayoutResult(lines: [], bounds: .zero, inkBounds: .zero, backgroundRect: nil) }

        let container = maxWidth.map { max(1, $0) } ?? raw.map(\.1).max()!
        var lines: [TextLine] = []
        for (i, (t, w)) in raw.enumerated() {
            let x: Double
            switch style.alignment {
            case .left: x = 0
            case .center: x = (container - w) / 2
            case .right: x = container - w
            }
            let box = TextRect(x: x, y: Double(i) * pitch, width: w, height: ascent + descent)
            lines.append(TextLine(text: t, x: x, y: box.y, width: w, height: ascent + descent, baseline: ascent,
                                  inkBounds: inkRect(box, style: style)))
        }
        let minX = lines.map(\.x).min()!, maxX = lines.map { $0.x + $0.width }.max()!
        let bounds = TextRect(x: minX, y: 0, width: maxX - minX, height: lines.last!.y + ascent + descent)
        var bg: TextRect?
        if let b = style.background {
            bg = TextRect(x: bounds.x - b.padding.horizontal, y: bounds.y - b.padding.vertical,
                          width: bounds.width + 2 * b.padding.horizontal, height: bounds.height + 2 * b.padding.vertical)
        }
        let ink = inkRect(bounds.union(bg ?? bounds), style: style)
        return TextLayoutResult(lines: lines, bounds: bounds, inkBounds: ink, backgroundRect: bg)
    }

    /// `rect` grown by the full stroke width (conservative: covers outside strokes) and united with its shadow.
    /// Shadow offset is in layout space (positive y = down); blur is taken as full radius.
    static func inkRect(_ rect: TextRect, style: TextStyle) -> TextRect {
        let grown = rect.expanded(by: style.stroke?.width ?? 0)
        guard let sh = style.shadow else { return grown }
        return grown.union(grown.offsetBy(dx: sh.offsetX, dy: sh.offsetY).expanded(by: sh.blur))
    }

    static func makeFont(_ style: TextStyle) -> CTFont { FontResolver.font(for: style) }

    private static func wrapParagraph(_ para: String, font: CTFont, maxWidth: Double) -> [(String, Double)] {
        let attr = NSAttributedString(string: para, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let ns = para as NSString
        var out: [(String, Double)] = []
        var start = 0
        while start < ns.length {
            var count = CTTypesetterSuggestLineBreak(ts, start, maxWidth)
            if count < 1 { count = 1 }
            let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
            let full = CTLineGetTypographicBounds(line, nil, nil, nil)
            let w = max(0, full - CTLineGetTrailingWhitespaceWidth(line))
            let piece = ns.substring(with: NSRange(location: start, length: count))
            out.append((piece.trimmingCharacters(in: .whitespaces), w))
            start += count
        }
        return out
    }
}
