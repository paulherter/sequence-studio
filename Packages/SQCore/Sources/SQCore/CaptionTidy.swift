import Foundation

/// Limits of the one-click "Tidy Captions" pass.
public struct CaptionTidyOptions: Sendable, Hashable {
    /// Most words in one caption.
    public var maxWords: Int
    /// Longest a caption stays on screen before it is split.
    public var maxDuration: Time
    /// A shorter caption grows into the silence after it (never over the next caption).
    public var minDuration: Time
    /// A silence shorter than this between two captions is closed (the earlier caption stays until the next starts).
    public var bridgeGapsUnder: Time
    /// Silence kept between two captions that were bridged or touch (zero: none).
    public var gap: Time

    public init(maxWords: Int = 3, maxDuration: Time = Time(3, 2), minDuration: Time = Time(1, 3),
                bridgeGapsUnder: Time = Time(1, 4), gap: Time = .zero) {
        self.maxWords = max(maxWords, 1); self.maxDuration = maxDuration; self.minDuration = minDuration
        self.bridgeGapsUnder = bridgeGapsUnder; self.gap = gap
    }

    /// Short punchy chunks: 3 words, 1.5 s at most, 1/3 s at least.
    public static let tikTok = CaptionTidyOptions()
}

/// Fast-captions timing pass: splits every caption into short TikTok-style chunks along its word timings, removes
/// overlaps, closes tiny gaps, keeps a minimum duration and snaps to frames. Pure logic, no UI.
public enum CaptionTidy {
    private struct Work {
        var item: CaptionItem
        var range: TimeRange
        var words: [CaptionWord]      // absolute timeline time
    }

    /// Tidies the captions of one track. Empty captions are dropped; the first chunk of a caption keeps its ID, style,
    /// animation and position. The result is sorted, frame-aligned, non-empty and never overlaps.
    public static func tidy(_ items: [CaptionItem], options o: CaptionTidyOptions, frameDuration fd: Time) -> [CaptionItem] {
        var work: [Work] = []
        for item in items.sorted(by: { $0.range.start < $1.range.start }) {
            work += chunks(of: item, options: o)
        }
        guard !work.isEmpty else { return [] }

        // 1. Overlaps (input sorted by start): the earlier caption yields; a caption that starts with the one before it is pushed.
        for i in work.indices.dropLast() {
            let next = work[i + 1].range
            guard next.start < work[i].range.end else { continue }
            if next.start > work[i].range.start {
                work[i].range = TimeRange(start: work[i].range.start, end: next.start)
            } else {
                let s = work[i].range.end
                work[i + 1].range = TimeRange(start: s, end: max(next.end, s + fd))
            }
        }
        // 2. Minimum duration: grow into the silence, never over the next caption.
        for i in work.indices where work[i].range.duration < o.minDuration {
            var e = work[i].range.start + o.minDuration
            if i + 1 < work.count { e = min(e, work[i + 1].range.start - o.gap) }
            if e > work[i].range.end { work[i].range = TimeRange(start: work[i].range.start, end: e) }
        }
        // 3. Close small gaps; keep `gap` where captions touch.
        for i in work.indices.dropLast() {
            let r = work[i].range, next = work[i + 1].range.start
            guard next - r.end < o.bridgeGapsUnder || next - r.end < o.gap else { continue }
            let target = next - o.gap
            if target > r.start, target != r.end { work[i].range = TimeRange(start: r.start, end: target) }
        }
        // 4. Frame grid, then one forward sweep so rounding can never create an overlap or an empty caption.
        var prevEnd = Time.zero
        for i in work.indices {
            let r = work[i].range
            let s = max(r.start.snapped(to: fd), prevEnd)
            let e = max(r.end.snapped(to: fd), s + fd)
            work[i].range = TimeRange(start: s, end: e)
            prevEnd = e
        }
        return work.map { w in
            var item = w.item
            item.range = w.range
            item.words = CaptionTrack.relativeWords(w.words, to: w.range)
            return item
        }
    }

    private static func chunks(of item: CaptionItem, options o: CaptionTidyOptions) -> [Work] {
        let words = item.effectiveWords
        guard !words.isEmpty else { return [] }
        var groups: [[CaptionWord]] = [[]]
        for w in words {
            if let first = groups[groups.count - 1].first, let last = groups[groups.count - 1].last {
                let count = groups[groups.count - 1].count
                if count >= o.maxWords || w.range.end - first.range.start > o.maxDuration
                    || endsSentence(last.text) || (count >= 2 && endsClause(last.text)) {
                    groups.append([])
                }
            }
            groups[groups.count - 1].append(w)
        }
        return groups.enumerated().map { i, g in
            var c = item
            if i > 0 { c.id = UUID() }
            c.lines = [WordSegmentation.join(g.map(\.text))]
            let s = g[0].range.start, e = max(g[g.count - 1].range.end, s)
            return Work(item: c, range: TimeRange(start: s, end: e), words: g)
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let c = text.last(where: { !"\"'”“»«)]".contains($0) }) else { return false }
        return c == "." || c == "!" || c == "?" || c == "…"
    }

    private static func endsClause(_ text: String) -> Bool {
        guard let c = text.last(where: { !"\"'”“»«)]".contains($0) }) else { return false }
        return c == "," || c == ";" || c == ":"
    }
}
