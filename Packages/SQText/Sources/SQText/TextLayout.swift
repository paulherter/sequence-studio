import Foundation

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
    /// Which style the line is drawn in (`TextStyle.lineStyle`): 0 = the clip style, 1 = the second-line style.
    public let styleIndex: Int
    public var rect: TextRect { TextRect(x: x, y: y, width: width, height: height) }
    /// `rect` grown by the style's stroke width and shadow (offset + blur); equals `rect` without either.
    public let inkBounds: TextRect
    /// The paragraph this line belongs to is laid out right to left (`TextStyle.direction`, else its first strong
    /// character). One value per paragraph, so a wrapped line that starts with a Latin word keeps the direction.
    public var isRightToLeft: Bool = false
    /// UTF-16 length of the list marker ("• ", "2. ") at the start of `text`; 0 on every other line. The marker is not part
    /// of `displayText`: displayText index `i` sits at line index `i - location + markerLength`.
    public var markerLength: Int = 0
    /// The line's text without the list marker.
    public var content: String { markerLength > 0 ? (text as NSString).substring(from: min(markerLength, (text as NSString).length)) : text }
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
        if style.autoFit == true, let w = maxWidth, let h = boxHeight {
            var plain = fittedStyle(text: original, style: style, width: w, height: h)
            plain.autoFit = nil
            return layout(text: original, style: plain, maxWidth: maxWidth, boxHeight: boxHeight)
        }
        let (text, wordSpans) = TextWords.display(original, allCaps: style.allCaps)
        // Paragraph looks: the first paragraph in the clip style, every later one in the second-line style, or each in its
        // own `lineStyles` entry.
        let fonts = (0..<style.lineStyleCount).map { makeFont(style.lineStyle($0)) }
        let wrap = maxWidth.map { max(1, $0) } ?? Double.greatestFiniteMagnitude

        var raw: [Measured] = []
        if !text.isEmpty {
            var base = 0
            var listNumber = 0
            for (i, para) in text.components(separatedBy: "\n").enumerated() {
                let si = min(i, fonts.count - 1)
                if !para.isEmpty, let kind = style.list {
                    listNumber += 1
                    let marker = kind.marker(listNumber), pre = (marker as NSString).length
                    var wrapped = wrapParagraph(marker + para, base: base - pre, font: fonts[si], maxWidth: wrap,
                                                tracking: style.tracking, styleIndex: si,
                                                rightToLeft: TextDirection.isRightToLeft(para, override: style.direction))
                    if !wrapped.isEmpty { wrapped[0].location = base; wrapped[0].marker = pre }
                    raw.append(contentsOf: wrapped)
                } else if para.isEmpty {
                    raw.append(Measured(text: "", width: 0, ascent: 0, descent: 0, leading: 0, location: base, styleIndex: si,
                                        rightToLeft: TextDirection.isRightToLeft(para, override: style.direction)))
                } else {
                    raw.append(contentsOf: wrapParagraph(para, base: base, font: fonts[si], maxWidth: wrap, tracking: style.tracking,
                                                         styleIndex: si,
                                                         rightToLeft: TextDirection.isRightToLeft(para, override: style.direction)))
                }
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
            let font = fonts[m.styleIndex]
            let fm = fontMetrics(font)
            let ascent = max(fm.ascent, m.ascent), descent = max(fm.descent, m.descent)
            let leading = max(fm.leading, m.leading)
            let x: Double
            switch style.alignment {
            case .left: x = 0
            case .center: x = (container - m.width) / 2
            case .right: x = container - m.width
            }
            let box = TextRect(x: x, y: y, width: m.width, height: ascent + descent)
            lines.append(TextLine(text: m.text, x: x, y: y, width: m.width, height: ascent + descent, baseline: ascent,
                                  location: m.location, styleIndex: m.styleIndex, inkBounds: inkRect(box, style: style),
                                  isRightToLeft: m.rightToLeft, markerLength: m.marker))
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
                             location: $0.location, styleIndex: $0.styleIndex, inkBounds: $0.inkBounds.offsetBy(dx: 0, dy: dy),
                             isRightToLeft: $0.isRightToLeft, markerLength: $0.markerLength)
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

    /// `rect` grown by how far the stroke reaches (its width outside, half of it centered) and united with its shadow.
    /// Shadow offset is in layout space (positive y = down); blur is taken as full radius.
    /// The style scaled down (never up) until the text fits `width` x `height`: sizes, tracking and line spacing follow one
    /// factor, found by bisection (the layout is monotone in the factor). Text that cannot fit even at the smallest size
    /// (a word wider than the box) is returned at that smallest size.
    static func fittedStyle(text: String, style: TextStyle, width: Double, height: Double) -> TextStyle {
        var base = style
        base.autoFit = nil
        func fits(_ s: TextStyle) -> Bool {
            let r = layout(text: text, style: s, maxWidth: width)
            guard !r.lines.isEmpty else { return true }
            return r.bounds.height <= height + 1e-6 && r.lines.allSatisfy { $0.width <= width + 1e-6 }
        }
        if fits(base) { return base }
        func scaled(_ f: Double) -> TextStyle {
            var s = base
            s.size = max(1, base.size * f); s.tracking = base.tracking * f; s.lineSpacing = base.lineSpacing * f
            if var l = s.secondLine { l.size = max(1, l.size * f); s.secondLine = l }
            if let own = s.lineStyles { s.lineStyles = own.map { var l = $0; l.size = max(1, l.size * f); return l } }
            return s
        }
        var lo = 0.02, hi = 1.0
        if !fits(scaled(lo)) { return scaled(lo) }
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            if fits(scaled(mid)) { lo = mid } else { hi = mid }
        }
        return scaled(lo)
    }

    static func inkRect(_ rect: TextRect, style: TextStyle) -> TextRect {
        let grown = rect.expanded(by: style.stroke?.reach ?? 0)
        guard let sh = style.shadow else { return grown }
        return grown.union(grown.offsetBy(dx: sh.offsetX, dy: sh.offsetY).expanded(by: sh.blur + sh.spread))
    }

    static func makeFont(_ style: TextStyle) -> PlatformFont { FontResolver.font(for: style) }

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
        var styleIndex: Int
        var rightToLeft = false
        var marker = 0
    }

    /// UTF-16 offsets where a line may start: after each whitespace run that is followed by a word (FB-M: lines break only
    /// at whitespace, never inside a word or at a hyphen). Whitespace is `Character.isWhitespace`, as in `TextWords`.
    static func breakOpportunities(_ para: String) -> [Int] {
        var out: [Int] = []
        var offset = 0, prevSpace = false, sawWord = false   // leading whitespace stays with the first word
        var prev: Character?
        for ch in para {
            let space = ch.isWhitespace
            if !space, prevSpace, sawWord {
                out.append(offset)
            } else if !space, !prevSpace, let p = prev, CJKBreaking.canBreak(between: p, and: ch) {
                // CJK has no spaces: a line may also break between an ideograph/kana and its neighbor, except before
                // a closing mark or after an opening one (kinsoku).
                out.append(offset)
            }
            if !space { sawWord = true }
            prevSpace = space
            prev = ch
            offset += ch.utf16.count
        }
        return out
    }

    /// Greedy word wrap: each line takes as many whole words as fit `maxWidth` (trailing whitespace not counted); a word
    /// wider than `maxWidth` gets a line of its own and overflows. Returns the UTF-16 length of each line, trailing
    /// whitespace included (as Core Text counts it).
    static func lineLengths(_ ts: any LineTypesetting, length: Int, breaks: [Int], maxWidth: Double) -> [Int] {
        func width(_ a: Int, _ b: Int) -> Double {
            let m = ts.line(location: a, length: b - a)
            return max(0, m.width - m.trailingWhitespace)
        }
        var out: [Int] = []
        var start = 0, k = 0                       // breaks[k] is the first opportunity after `start`
        while start < length {
            while k < breaks.count, breaks[k] <= start { k += 1 }
            var end = k < breaks.count ? breaks[k] : length   // at least one word
            var j = k
            while end < length {
                let next = j + 1 < breaks.count ? breaks[j + 1] : length
                guard width(start, next) <= maxWidth + 1e-6 else { break }
                end = next; j += 1
            }
            out.append(end - start)
            start = end
        }
        return out
    }

    private static func wrapParagraph(_ para: String, base: Int, font: PlatformFont, maxWidth: Double, tracking: Double,
                                      styleIndex: Int, rightToLeft: Bool) -> [Measured] {
        let ts = typesetter(para, font: font, tracking: tracking, rightToLeft: rightToLeft)
        let ns = para as NSString
        var out: [Measured] = []
        var start = 0
        let counts = maxWidth >= Double.greatestFiniteMagnitude ? [ns.length]
            : lineLengths(ts, length: ns.length, breaks: breakOpportunities(para), maxWidth: maxWidth)
        for count in counts where count > 0 {
            // Typographic bounds cover all runs actually used, including fallback fonts.
            let lm = ts.line(location: start, length: count)
            let a = lm.ascent, d = lm.descent, l = lm.leading
            let w = max(0, lm.width - lm.trailingWhitespace)
            let piece = ns.substring(with: NSRange(location: start, length: count))
            // Leading whitespace is significant (drawn and measured); only the wrap-causing trailing run is dropped.
            out.append(Measured(text: trimTrailingWhitespace(piece), width: w, ascent: a, descent: d, leading: l, location: base + start,
                                styleIndex: styleIndex, rightToLeft: rightToLeft))
            start += count
        }
        return out
    }
}

/// Words of a text. One definition for the whole app (`WordSegmentation` in SQCore): whitespace and every CJK character separate words.
public enum TextWords {
    /// The text as drawn and the UTF-16 spans of its words, computed once. With `allCaps` each character is
    /// capitalised on its own, so a length-changing capital (German sharp s becomes two capital S) moves the spans but never splits or
    /// merges a word, and the spans still describe the words of the original text.
    public static func display(_ original: String, allCaps: Bool) -> (text: String, spans: [NSRange]) {
        let chars = Array(original)
        var out = "", offsets: [Int] = [0]   // UTF-16 offset of each character of the displayed text
        for ch in chars {
            out += allCaps ? String(ch).uppercased() : String(ch)
            offsets.append(out.utf16.count)
        }
        let spans = WordSegmentation.spans(chars).map { NSRange(location: offsets[$0.lowerBound], length: offsets[$0.upperBound] - offsets[$0.lowerBound]) }
        return (out, spans)
    }
}

/// Line breaking inside unspaced CJK text (a pragmatic subset of UAX 14, enough for subtitles and titles).
enum CJKBreaking {
    static func isCJK(_ c: Character) -> Bool { WordSegmentation.isCJK(c) }

    static let noLineStart = WordSegmentation.closing
    static let noLineEnd = WordSegmentation.opening

    static func canBreak(between a: Character, and b: Character) -> Bool {
        guard isCJK(a) || isCJK(b) else { return false }
        return !noLineStart.contains(b) && !noLineEnd.contains(a)
    }
}
