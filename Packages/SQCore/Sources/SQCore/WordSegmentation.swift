import Foundation

/// The one definition of a "word" for captions (`CaptionItem.tokens`, word editing), karaoke, text animators
/// (`TextUnits`), the text layout (`TextWords` in SQText), caption burn-in and transcription tokens, so a word index means
/// the same thing in the monitor, in an export and in the stored word timings.
///
/// Whitespace separates words. Every CJK character (ideographs, kana, fullwidth forms: `isCJK`) is a word of its own,
/// since such text has no spaces. A closing mark (`CJKBreaking`'s "may not start a line", also ASCII `.,!?)`) stays with the
/// word before it, an opening mark (`（「(`) joins the word after it. Latin text is exactly whitespace splitting.
public enum WordSegmentation {
    public static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x2E80...0x2FDF, 0x3000...0x30FF, 0x3190...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF00...0xFFEF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    /// May not start a line (closing marks, small kana, prolonged sound mark, iteration marks).
    public static let closing = Set("、。，．・：；！？）〕］｝〉》」』】〙〗〟'”ゝゞヽヾーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ々〻")
        .union(Set(")]}!?,.:;%"))
    /// May not end a line (opening marks).
    public static let opening = Set("（〔［｛〈《「『【〘〖〝‘“([{")

    private enum Kind { case latin, cjk, open }

    /// Character-index spans of the words of `chars`.
    public static func spans(_ chars: [Character]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        var kind = Kind.latin
        func close(_ n: Int) { if let s = start { out.append(s..<n); start = nil } }
        for (n, ch) in chars.enumerated() {
            if ch.isWhitespace { close(n); continue }
            if closing.contains(ch) {
                if start == nil { start = n; kind = .latin }
            } else if opening.contains(ch) {
                if start != nil, kind == .cjk { close(n) }
                if start == nil { start = n; kind = .open }
            } else if isCJK(ch) {
                if start != nil, kind != .open { close(n) }
                if start == nil { start = n }
                kind = .cjk
            } else {
                if start != nil, kind == .cjk { close(n) }
                if start == nil { start = n }
                kind = .latin
            }
        }
        close(chars.count)
        return out
    }

    public static func spans(of text: String) -> [Range<Int>] { spans(Array(text)) }

    public static func words(_ text: String) -> [String] {
        let chars = Array(text)
        return spans(chars).map { String(chars[$0]) }
    }

    public static func wordCount(_ text: String) -> Int { spans(of: text).count }

    /// True when a space does not belong between `a` and `b` (a CJK character on either side of the seam).
    public static func isTight(_ a: String, _ b: String) -> Bool {
        guard let x = a.last, let y = b.first else { return false }
        return isCJK(x) || isCJK(y)
    }

    /// The words as one line: a space between words, none beside a CJK character.
    public static func join(_ words: [String]) -> String {
        var out = ""
        for w in words {
            if !out.isEmpty, !isTight(out, w) { out += " " }
            out += w
        }
        return out
    }
}
