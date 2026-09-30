import Foundation
import SSCore

public enum TranscriptEditing {
    /// Duration given to each inserted word when there is no gap to fill
    /// (inserted at the start or end of a transcript, or into an empty one): 1/3 s per word.
    public static let fallbackWordDuration = Time(1, 3)

    /// Minimum time per inserted word in a gap between unchanged neighbours. A smaller gap
    /// (including zero) is widened by sharing time with the neighbours.
    public static let minInsertedWordDuration = Time(1, 100)

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
    /// Edge cases: when the gap between the neighbours is zero or smaller than
    /// `TranscriptEditing.minInsertedWordDuration` per inserted word, the neighbours' time is shared with
    /// the inserted words proportionally by character count (neighbours keep their outer start/end);
    /// inserts at the start/end use `TranscriptEditing.fallbackWordDuration` per word
    /// (at the start the run ends at the first word's start, clamped at zero).
    public func applyingText(_ newText: String) -> Transcript {
        let tokens = TranscriptEditing.tokenise(newText)
        let oldKeys = words.map { TranscriptEditing.normalise($0.text) }
        let newKeys = tokens.map(TranscriptEditing.normalise)
        let pairs = Self.lcsPairs(oldKeys, newKeys)

        var result: [TranscriptWord] = []
        var oi = 0, ni = 0
        var pendingNextStart: Time?
        func flushRun(oldEnd: Int, newEnd: Int) {
            let oldRun = words[oi..<oldEnd]
            let newRun = Array(tokens[ni..<newEnd])
            guard !newRun.isEmpty else { return }
            if oldRun.isEmpty, oldEnd < words.count, let prev = result.last {
                let next = words[oldEnd]
                let gap = next.range.start - prev.range.end
                let needed = TranscriptEditing.minInsertedWordDuration * Int64(newRun.count)
                let span = TimeRange(start: prev.range.start, end: next.range.end)
                if (gap < needed) && (span.duration > Time.zero) {
                    let weights = [Int64(max(prev.text.count, 1))] + newRun.map { Int64(max($0.count, 1)) } + [Int64(max(next.text.count, 1))]
                    let total = weights.reduce(0, +)
                    var bounds: [Time] = [span.start]
                    var cum: Int64 = 0
                    for wgt in weights.dropLast() {
                        cum += wgt
                        bounds.append(span.start + Time(span.duration.value * cum, span.duration.timescale * total))
                    }
                    bounds.append(span.end)
                    result[result.count - 1].range = TimeRange(start: bounds[0], end: bounds[1])
                    for (k, token) in newRun.enumerated() {
                        result.append(TranscriptWord(text: token, range: TimeRange(start: bounds[k + 1], end: bounds[k + 2]), isEdited: true))
                    }
                    pendingNextStart = bounds[newRun.count + 1]
                    return
                }
            }
            let (span, equal) = spanForRun(oldRun: oldRun, oldEnd: oldEnd, count: newRun.count, previous: result.last)
            result += Self.spread(newRun, over: span, equalWeights: equal)
        }
        for (o, n) in pairs + [(words.count, tokens.count)] {
            flushRun(oldEnd: o, newEnd: n)
            if o < words.count, n < tokens.count {
                var kept = words[o]
                if kept.text != tokens[n] { kept.text = tokens[n]; kept.isEdited = true }
                if let s = pendingNextStart { kept.range = TimeRange(start: s, end: kept.range.end); pendingNextStart = nil }
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
