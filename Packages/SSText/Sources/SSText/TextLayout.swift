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
}

public struct TextLayoutResult: Sendable, Hashable {
    public let lines: [TextLine]
    /// Union of all line rects (tight around the text, without stroke/shadow).
    public let bounds: TextRect
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
        guard !raw.isEmpty else { return TextLayoutResult(lines: [], bounds: .zero, backgroundRect: nil) }

        let container = maxWidth.map { max(1, $0) } ?? raw.map(\.1).max()!
        var lines: [TextLine] = []
        for (i, (t, w)) in raw.enumerated() {
            let x: Double
            switch style.alignment {
            case .left: x = 0
            case .center: x = (container - w) / 2
            case .right: x = container - w
            }
            lines.append(TextLine(text: t, x: x, y: Double(i) * pitch, width: w, height: ascent + descent, baseline: ascent))
        }
        let minX = lines.map(\.x).min()!, maxX = lines.map { $0.x + $0.width }.max()!
        let bounds = TextRect(x: minX, y: 0, width: maxX - minX, height: lines.last!.y + ascent + descent)
        var bg: TextRect?
        if let b = style.background {
            bg = TextRect(x: bounds.x - b.padding.horizontal, y: bounds.y - b.padding.vertical,
                          width: bounds.width + 2 * b.padding.horizontal, height: bounds.height + 2 * b.padding.vertical)
        }
        return TextLayoutResult(lines: lines, bounds: bounds, backgroundRect: bg)
    }

    static func makeFont(_ style: TextStyle) -> CTFont {
        var font = CTFontCreateWithName(style.fontName as CFString, CGFloat(style.size), nil)
        // Weights >= semibold map to the bold trait (family-wide weight axes are a later refinement).
        if style.weight >= .semibold,
           let bold = CTFontCreateCopyWithSymbolicTraits(font, CGFloat(style.size), nil, .boldTrait, .boldTrait) {
            font = bold
        }
        return font
    }

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
