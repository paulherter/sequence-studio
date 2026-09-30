import Foundation
import SSCore

public enum TranscriptEditing {
    /// Duration given to each inserted word when there is no gap to fill
    /// (inserted at the start or end of a transcript, or into an empty one): 1/3 s per word.
    public static let fallbackWordDuration = Time(1, 3)

    /// Comparison key: lowercased, surrounding punctuation stripped. Falls back to the raw token if nothing is left.
    static func normalise(_ token: String) -> String {
        let lower = token.lowercased()
        let trimmed = lower.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return trimmed.isEmpty ? lower : trimmed
    }

    static func tokenise(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

extension Transcript {
    /// Applies a text-only edit. Unchanged words keep their exact timing; replaced words take the old
    /// words' span; inserted words split the gap between their unchanged neighbours proportionally to
    /// character count; deleted words vanish. Never touches media.
    ///
    /// Edge cases: a zero-length gap yields zero-length words at that point (no time to share);
    /// inserts at the start/end use `TranscriptEditing.fallbackWordDuration` per word
    /// (at the start the run ends at the first word's start, clamped at zero).
    public func applyingText(_ newText: String) -> Transcript {
        let tokens = TranscriptEditing.tokenise(newText)
        let oldKeys = words.map { TranscriptEditing.normalise($0.text) }
        let newKeys = tokens.map(TranscriptEditing.normalise)
        let pairs = Self.lcsPairs(oldKeys, newKeys)

        var result: [TranscriptWord] = []
        var oi = 0, ni = 0
        func flushRun(oldEnd: Int, newEnd: Int) {
            let oldRun = words[oi..<oldEnd]
            let newRun = Array(tokens[ni..<newEnd])
            guard !newRun.isEmpty else { return }
            let (span, equal) = spanForRun(oldRun: oldRun, oldEnd: oldEnd, count: newRun.count, previous: result.last)
            result += Self.spread(newRun, over: span, equalWeights: equal)
        }
        for (o, n) in pairs + [(words.count, tokens.count)] {
            flushRun(oldEnd: o, newEnd: n)
            if o < words.count, n < tokens.count {
                var kept = words[o]
                if kept.text != tokens[n] { kept.text = tokens[n]; kept.isEdited = true }
                result.append(kept)
            }
            oi = o + 1
            ni = n + 1
        }
        return Transcript(language: language, words: result)
    }

    /// Span for a run; `equalWeights` is true when the span came from the fallback duration (1/3 s per word).
    private func spanForRun(oldRun: ArraySlice<TranscriptWord>, oldEnd: Int, count: Int, previous: TranscriptWord?) -> (TimeRange, Bool) {
        if let first = oldRun.first, let last = oldRun.last {
            return (TimeRange(start: first.range.start, end: max(last.range.end, first.range.start)), false)
        }
        // Pure insertion: gap between unchanged neighbours.
        let prevEnd: Time? = previous?.range.end
        let next: Time? = oldEnd < words.count ? words[oldEnd].range.start : nil
        let fallback = TranscriptEditing.fallbackWordDuration * Int64(count)
        switch (prevEnd, next) {
        case let (p?, n?): return (TimeRange(start: p, end: max(n, p)), false)
        case let (p?, nil): return (TimeRange(start: p, duration: fallback), true)
        case let (nil, n?):
            let s = max(Time.zero, n - fallback)
            return (TimeRange(start: s, end: max(n, s)), true)
        case (nil, nil): return (TimeRange(start: .zero, duration: fallback), true)
        }
    }

    /// Splits `span` into contiguous slots proportional to character count. A 1:1 run keeps the slot exactly.
    private static func spread(_ tokens: [String], over span: TimeRange, equalWeights: Bool) -> [TranscriptWord] {
        let weights = tokens.map { equalWeights ? 1 : Int64(max($0.count, 1)) }
        let total = weights.reduce(0, +)
        var out: [TranscriptWord] = []
        var cum: Int64 = 0
        var cursor = span.start
        for (i, token) in tokens.enumerated() {
            cum += weights[i]
            let end = i == tokens.count - 1
                ? span.end
                : span.start + Time(span.duration.value * cum, span.duration.timescale * total)
            out.append(TranscriptWord(text: token, range: TimeRange(start: cursor, end: max(end, cursor)), isEdited: true))
            cursor = max(end, cursor)
        }
        return out
    }

    /// Index pairs of a longest common subsequence, ascending.
    private static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        var out: [(Int, Int)] = []
        while i < n, j < m {
            if a[i] == b[j] { out.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return out
    }
}
