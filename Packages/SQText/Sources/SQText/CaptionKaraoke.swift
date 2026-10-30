import Foundation
import SQCore

/// Words of a text drawn in another color (the karaoke look). `words` counts whitespace-separated words across all
/// lines, in reading order; the stroke and shadow keep their colors, only the fill changes.
public struct TextHighlight: Sendable, Hashable, Codable {
    public var words: Range<Int>
    public var color: RGBAColor
    /// True: the raster holds only the lit words' fill in the highlight color, on a transparent ground, with the same
    /// size and origin as the plain raster. Captions draw it as a second layer over the plain raster, so the plain
    /// caption is rendered once per caption and never once per word.
    public var onlyLit: Bool
    /// True: the background (pill) is drawn as one box per word instead of one box around the whole text. Only the plain
    /// layer of a karaoke caption carries it (see `CaptionKaraoke.plainHighlight`); it lights no words by itself.
    public var perWordPill: Bool
    public init(words: Range<Int>, color: RGBAColor, onlyLit: Bool = false, perWordPill: Bool = false) {
        self.words = words; self.color = color; self.onlyLit = onlyLit; self.perWordPill = perWordPill
    }

    private enum CodingKeys: String, CodingKey { case words, color, onlyLit, perWordPill }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(words: try c.decode(Range<Int>.self, forKey: .words), color: try c.decode(RGBAColor.self, forKey: .color),
                  onlyLit: try c.decodeIfPresent(Bool.self, forKey: .onlyLit) ?? false,
                  perWordPill: try c.decodeIfPresent(Bool.self, forKey: .perWordPill) ?? false)
    }
}

/// Which words of a caption are lit at a time: the one place both the Program monitor and the export burn-in ask,
/// so they cannot disagree.
public enum CaptionKaraoke {
    public static func color(_ k: KaraokeStyle) -> RGBAColor { RGBAColor(red: k.red, green: k.green, blue: k.blue) }

    /// The "highlight" of the plain layer of a karaoke caption whose style has a pill: no word is lit, but the pill is drawn per
    /// word. Nil (the plain layer keeps its single box) without karaoke, without a background or with fewer than two words.
    public static func plainHighlight(style: TextStyle, karaoke: KaraokeStyle?, wordCount: Int) -> TextHighlight? {
        guard karaoke != nil, style.background != nil, wordCount > 1 else { return nil }
        return TextHighlight(words: 0..<0, color: .white, perWordPill: true)
    }

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

    /// The highlight `item` ends with (what `highlight(for:style:at:)` gives just before its end): a caption that holds
    /// through a small gap or stays as the tail under the next caption keeps it (`CaptionHandover`).
    public static func heldHighlight(for item: CaptionItem, style: KaraokeStyle?) -> TextHighlight? {
        guard let style else { return nil }
        let count = item.tokens.count
        guard count > 0, let last = item.karaokeKeys.last(where: { $0.time < item.range.end }) else { return nil }
        if let i = last.activeWord { return highlight(forWord: i, style: style) }
        return style.keepSpoken ? TextHighlight(words: 0..<count, color: color(style), onlyLit: true) : nil
    }
}
