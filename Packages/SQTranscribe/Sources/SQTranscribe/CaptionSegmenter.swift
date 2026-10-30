import Foundation
import SQCore

public struct Caption: Sendable, Hashable {
    public var lines: [String]
    public var range: TimeRange
    public var firstWordID: UUID
    public var lastWordID: UUID
    /// Indices into `Transcript.words`.
    public var wordIndices: Range<Int>
    public var styleRef: String
    public var animationRef: String
    /// The spoken words with their times (same time base as `range`): the karaoke highlight follows them.
    public var words: [CaptionWord]
    /// Karaoke word highlight of the caption's track (burn-in only); nil = off.
    public var karaoke: KaraokeStyle?
    /// The caption's own position (nil: the project's).
    public var position: CaptionPosition?

    public init(lines: [String], range: TimeRange, firstWordID: UUID = UUID(), lastWordID: UUID = UUID(),
                wordIndices: Range<Int> = 0..<0, styleRef: String, animationRef: String, words: [CaptionWord] = [],
                karaoke: KaraokeStyle? = nil, position: CaptionPosition? = nil) {
        self.lines = lines; self.range = range; self.firstWordID = firstWordID; self.lastWordID = lastWordID
        self.wordIndices = wordIndices; self.styleRef = styleRef; self.animationRef = animationRef
        self.words = words; self.karaoke = karaoke; self.position = position
    }
}

public enum CaptionSegmenter {
    /// Splits a transcript into captions. Every word lands in exactly one caption; captions never overlap
    /// and their range is exactly the first word's start to the last word's end (start clamped to the
    /// previous caption's end when word times overlap).
    /// Breaks: line/char limit, max duration, pause, sentence end once the caption is about half a line full
    /// and at least `minDuration` long. A word longer than a line gets a line of its own.
    public static func segment(_ transcript: Transcript, preset: CaptionPreset) -> [Caption] {
        if preset.maxWordsPerCaption == 1 { return segmentSingleWords(transcript, preset: preset) }
        let words = transcript.words
        var captions: [Caption] = []
        var startIndex = 0
        var lastEnd: Time?

        func close(upTo end: Int) {
            let slice = words[startIndex..<end]
            guard let first = slice.first, let last = slice.last else { return }
            var s = first.range.start
            if let le = lastEnd, s < le { s = le }
            let e = max(last.range.end, s)
            captions.append(Caption(
                lines: wrap(slice.map(\.text), maxChars: preset.maxCharsPerLine),
                range: TimeRange(start: s, end: e),
                firstWordID: first.id, lastWordID: last.id, wordIndices: startIndex..<end,
                styleRef: preset.styleRef, animationRef: preset.animationRef,
                words: slice.map { CaptionWord(text: $0.text, range: $0.range, confidence: $0.confidence) }))
            lastEnd = e
            startIndex = end
        }

        for i in words.indices {
            if i > startIndex {
                let current = Array(words[startIndex..<i])
                let word = words[i]
                let prev = words[i - 1]
                var split = false
                if word.range.start - prev.range.end >= preset.pauseBreak { split = true }
                else if word.range.end - current[0].range.start > preset.maxDuration { split = true }
                else if wrap(current.map(\.text) + [word.text], maxChars: preset.maxCharsPerLine).count > preset.maxLines { split = true }
                else if endsSentence(prev.text),
                        current.map(\.text).joined(separator: " ").count * 2 >= preset.maxCharsPerLine,
                        prev.range.end - current[0].range.start >= preset.minDuration { split = true }
                if split { close(upTo: i) }
            }
        }
        close(upTo: words.count)
        return captions
    }

    private struct Unit {
        var text: String
        var words: [CaptionWord]
        var start: Time
        var end: Time
        var lo: Int
        var hi: Int
        var firstID: UUID
        var lastID: UUID
        var chars: Int { text.count }
    }

    /// One word per caption. Ignores `maxDuration`, `pauseBreak` and `gap`; callers must run `applyTiming` afterwards
    /// (it keeps the minimum). Words are never split (FB-M): a word longer than `maxCharsPerLine` is a caption of its own,
    /// and a word without letters or digits (a dash, a lone punctuation mark) joins the caption before it.
    /// A caption shorter than `minDuration` grows into the silence after it, else takes time
    /// from a long enough next caption, else merges with a neighbor (only if the text still fits),
    /// else pushes the next caption's start back by the missing time (see the cascade below).
    private static func segmentSingleWords(_ transcript: Transcript, preset: CaptionPreset) -> [Caption] {
        var units: [Unit] = []
        var lastEnd: Time?
        for (i, word) in transcript.words.enumerated() {
            var s = word.range.start
            if let le = lastEnd, s < le { s = le }
            let e = max(word.range.end, s)
            let r = TimeRange(start: s, end: e)
            let unit = Unit(text: word.text, words: [CaptionWord(text: word.text, range: r, confidence: word.confidence)], start: s, end: e,
                            lo: i, hi: i + 1, firstID: word.id, lastID: word.id)
            if let last = units.last, !word.text.contains(where: { $0.isLetter || $0.isNumber }) {
                units[units.count - 1] = merged(last, unit)
            } else {
                units.append(unit)
            }
            lastEnd = e
        }

        var i = 0
        while i < units.count {
            let need = preset.minDuration - (units[i].end - units[i].start)
            if need <= .zero { i += 1; continue }
            if i + 1 < units.count {
                let room = units[i + 1].start - units[i].end
                if room > .zero { units[i].end = units[i].end + min(room, need) }
            } else {
                units[i].end = units[i].end + need   // last caption: trailing time is free
                i += 1; continue
            }
            let still = preset.minDuration - (units[i].end - units[i].start)
            if still <= .zero { i += 1; continue }
            // Borrow time from the neighbors' surplus above the minimum (next first, then previous).
            let fromNext = i + 1 < units.count
                ? max(.zero, min(still, units[i + 1].end - units[i + 1].start - preset.minDuration)) : .zero
            let fromPrev = i > 0
                ? max(.zero, min(still - fromNext, units[i - 1].end - units[i - 1].start - preset.minDuration)) : .zero
            if fromNext + fromPrev >= still {
                if fromNext > .zero {
                    units[i].end = units[i].end + fromNext
                    units[i + 1].start = units[i].end
                }
                if fromPrev > .zero {
                    units[i].start = units[i].start - fromPrev
                    units[i - 1].end = units[i].start
                }
                i += 1; continue
            }
            if i + 1 < units.count, joinedText(units[i], units[i + 1]).count <= preset.maxCharsPerLine {
                units[i] = merged(units[i], units[i + 1]); units.remove(at: i + 1); continue
            }
            if i > 0, joinedText(units[i - 1], units[i]).count <= preset.maxCharsPerLine {
                units[i - 1] = merged(units[i - 1], units[i]); units.remove(at: i); i -= 1; continue
            }
            // Unavoidable case (no surplus anywhere, text cannot merge): keep the minimum by pushing the next
            // caption's start back; it is then too short itself and grows in turn, so a dense run of tiny
            // captions is delayed, never dropped, and the last one extends into trailing time.
            units[i].end = units[i].end + still
            if units[i + 1].start < units[i].end {
                units[i + 1].start = units[i].end
                if units[i + 1].end < units[i + 1].start { units[i + 1].end = units[i + 1].start }
            }
            i += 1
        }

        return units.map { u in
            Caption(lines: [u.text], range: TimeRange(start: u.start, end: u.end),
                    firstWordID: u.firstID, lastWordID: u.lastID, wordIndices: u.lo..<u.hi,
                    styleRef: preset.styleRef, animationRef: preset.animationRef, words: u.words)
        }
    }

    /// Different words join with one space.
    private static func joinedText(_ a: Unit, _ b: Unit) -> String { a.text + " " + b.text }

    private static func merged(_ a: Unit, _ b: Unit) -> Unit {
        Unit(text: joinedText(a, b), words: a.words + b.words, start: a.start, end: max(a.end, b.end),
             lo: a.lo, hi: b.hi, firstID: a.firstID, lastID: b.lastID)
    }

    /// Applies the preset's minimum duration and gap: a caption shorter than `minDuration` is extended into the silence
    /// after it (never over the next caption and its gap), then a caption that ends closer than `gap` to the next one
    /// is shortened (never to nothing). The start of a caption never moves. Input must be sorted and non-overlapping.
    public static func applyTiming(_ captions: [Caption], preset: CaptionPreset) -> [Caption] {
        var out = captions
        for i in out.indices {
            let s = out[i].range.start
            var e = out[i].range.end
            let limit = i + 1 < out.count ? out[i + 1].range.start - preset.gap : nil
            if e - s < preset.minDuration {
                var wanted = s + preset.minDuration
                if let limit { wanted = min(wanted, limit) }
                e = max(e, wanted)
            }
            if i + 1 < out.count {
                let next = out[i + 1].range.start
                if next - e < preset.gap, next - preset.gap > s { e = next - preset.gap }
            }
            out[i].range = TimeRange(start: s, end: e)
        }
        return out
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let c = text.last(where: { !"\"'”“»«)]".contains($0) }) else { return false }
        return c == "." || c == "!" || c == "?" || c == "…"
    }

    /// Greedy line wrap of whole words (never split); an over-long word occupies its own line, and a word without letters or
    /// digits (a dash) stays at the end of the line before it instead of starting a line.
    static func wrap(_ words: [String], maxChars: Int) -> [String] {
        var lines: [String] = []
        for word in words {
            let punctuation = !word.contains(where: { $0.isLetter || $0.isNumber })
            if let last = lines.last, punctuation || last.count + 1 + word.count <= maxChars {
                lines[lines.count - 1] = WordSegmentation.isTight(last, word) ? last + word : last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines
    }
}
