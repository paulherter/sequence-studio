import Foundation
import SQCore

/// Words of a text drawn in another colour (the karaoke look). `words` counts whitespace-separated words across all
/// lines, in reading order; the stroke and shadow keep their colours, only the fill changes.
public struct TextHighlight: Sendable, Hashable, Codable {
    public var words: Range<Int>
    public var color: RGBAColor
    public init(words: Range<Int>, color: RGBAColor) { self.words = words; self.color = color }
}

/// Which words of a caption are lit at a time: the one place both the Program monitor and the export burn-in ask,
/// so they cannot disagree.
public enum CaptionKaraoke {
    public static func color(_ k: KaraokeStyle) -> RGBAColor { RGBAColor(red: k.red, green: k.green, blue: k.blue) }

    /// The highlight of `item` at timeline time `t`; nil when karaoke is off or no word is lit.
    public static func highlight(for item: CaptionItem, style: KaraokeStyle?, at t: Time) -> TextHighlight? {
        guard let style else { return nil }
        let count = item.tokens.count
        guard count > 0 else { return nil }
        if let i = item.activeWord(at: t) {
            return TextHighlight(words: (style.keepSpoken ? 0 : i)..<(i + 1), color: color(style))
        }
        // After the last word has been spoken a progressive fill is complete.
        if style.keepSpoken, let end = item.effectiveWords.last?.range.end, t >= end, item.range.contains(t) {
            return TextHighlight(words: 0..<count, color: color(style))
        }
        return nil
    }
}
