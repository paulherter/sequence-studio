import Foundation

/// Turns translated texts back into captions: the translated track has the same timings and look as the source.
/// Pure logic; the translation itself (Apple Translation, on device) lives in SQEditorUI.
public enum CaptionTranslation {
    /// New caption items with the same ranges, style, animation and position as `source`, one per source caption, carrying
    /// `texts[i]` as their text. A text that is longer than `maxCharsPerLine` is broken into at most two balanced lines.
    /// Word timings are not carried over (the words differ): the karaoke highlight spreads over the new words by length.
    /// Captions whose translated text is empty keep the source text. Returns nil when the counts differ.
    public static func translatedItems(from source: [CaptionItem], texts: [String], maxCharsPerLine: Int = 32) -> [CaptionItem]? {
        guard source.count == texts.count else { return nil }
        return zip(source, texts).map { item, text in
            var c = item
            c.id = UUID()
            let words = WordSegmentation.words(text)
            c.lines = words.isEmpty ? item.lines : balancedLines(words, maxChars: maxCharsPerLine)
            c.words = []
            return c
        }
    }

    /// One line when it fits, else two lines broken at the word boundary closest to the middle.
    static func balancedLines(_ words: [String], maxChars: Int) -> [String] {
        let whole = WordSegmentation.join(words)
        guard whole.count > maxChars, words.count > 1 else { return [whole] }
        var best = 1, bestDiff = Int.max
        for k in 1..<words.count {
            let a = WordSegmentation.join(Array(words[..<k])).count, b = WordSegmentation.join(Array(words[k...])).count
            if abs(a - b) < bestDiff { best = k; bestDiff = abs(a - b) }
        }
        return [WordSegmentation.join(Array(words[..<best])), WordSegmentation.join(Array(words[best...]))]
    }

    /// Track name for a translation: "Captions 1 (de)".
    public static func trackName(source: String, language: String) -> String {
        let base = source.isEmpty ? "Captions" : source
        return "\(base) (\(language))"
    }
}
