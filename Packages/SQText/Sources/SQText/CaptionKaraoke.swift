import Foundation
import SQCore

/// Words of a text drawn in another colour (the karaoke look). `words` counts whitespace-separated words across all
/// lines, in reading order; the stroke and shadow keep their colours, only the fill changes.
public struct TextHighlight: Sendable, Hashable, Codable {
    public var words: Range<Int>
    public var color: RGBAColor
    /// True: the raster holds only the lit words' fill in the highlight colour, on a transparent ground, with the same
    /// size and origin as the plain raster. Captions draw it as a second layer over the plain raster, so the plain
    /// caption is rendered once per caption and never once per word.
    public var onlyLit: Bool
    public init(words: Range<Int>, color: RGBAColor, onlyLit: Bool = false) {
        self.words = words; self.color = color; self.onlyLit = onlyLit
    }

    private enum CodingKeys: String, CodingKey { case words, color, onlyLit }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(words: try c.decode(Range<Int>.self, forKey: .words), color: try c.decode(RGBAColor.self, forKey: .color),
                  onlyLit: try c.decodeIfPresent(Bool.self, forKey: .onlyLit) ?? false)
    }
}

/// Which words of a caption are lit at a time: the one place both the Program monitor and the export burn-in ask,
/// so they cannot disagree.
public enum CaptionKaraoke {
    public static func color(_ k: KaraokeStyle) -> RGBAColor { RGBAColor(red: k.red, green: k.green, blue: k.blue) }

    /// The highlight that lights word `i` (and, when words stay lit, all before it).
    public static func highlight(forWord i: Int, style: KaraokeStyle) -> TextHighlight {
        TextHighlight(words: (style.keepSpoken ? 0 : i)..<(i + 1), color: color(style), onlyLit: true)
    }

    /// The highlight of `item` at timeline time `t`; nil when karaoke is off or no word is lit.
    public static func highlight(for item: CaptionItem, style: KaraokeStyle?, at t: Time) -> TextHighlight? {
        guard let style else { return nil }
        let count = item.tokens.count
        guard count > 0 else { return nil }
        if let i = item.activeWord(at: t) {
            return TextHighlight(words: (style.keepSpoken ? 0 : i)..<(i + 1), color: color(style), onlyLit: true)
        }
        // After the last word has been spoken a progressive fill is complete.
        if style.keepSpoken, let end = item.effectiveWords.last?.range.end, t >= end, item.range.contains(t) {
            return TextHighlight(words: 0..<count, color: color(style), onlyLit: true)
        }
        return nil
    }
}
