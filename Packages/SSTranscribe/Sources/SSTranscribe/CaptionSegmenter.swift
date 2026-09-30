import Foundation
import SSCore

public struct Caption: Sendable, Hashable {
    public var lines: [String]
    public var range: TimeRange
    public var firstWordID: UUID
    public var lastWordID: UUID
    /// Indices into `Transcript.words`.
    public var wordIndices: Range<Int>
    public var styleRef: String
    public var animationRef: String
}

public enum CaptionSegmenter {
    /// Splits a transcript into captions. Every word lands in exactly one caption; captions never overlap
    /// and their range is exactly the first word's start to the last word's end (start clamped to the
    /// previous caption's end when word times overlap).
    /// Breaks: line/char limit, max duration, pause, sentence end once the caption is about half a line full
    /// and at least `minDuration` long. A word longer than a line gets a line of its own.
    public static func segment(_ transcript: Transcript, preset: CaptionPreset) -> [Caption] {
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
                styleRef: preset.styleRef, animationRef: preset.animationRef))
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

    private static func endsSentence(_ text: String) -> Bool {
        guard let c = text.last(where: { !"\"'”“»«)]".contains($0) }) else { return false }
        return c == "." || c == "!" || c == "?" || c == "…"
    }

    /// Greedy line wrap; an over-long word occupies its own line.
    static func wrap(_ words: [String], maxChars: Int) -> [String] {
        var lines: [String] = []
        for word in words {
            if let last = lines.last, last.count + 1 + word.count <= maxChars {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines
    }
}
