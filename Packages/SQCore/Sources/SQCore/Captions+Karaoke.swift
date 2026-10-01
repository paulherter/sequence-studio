import Foundation

/// One spoken word of a caption. Inside a `CaptionItem` the range is relative to the item's start, so moving, rippling
/// and tail-trimming a caption keep its words right without touching them (a head trim shifts them by the trimmed
/// amount). `Caption.words` of a transcript (SQTranscribe) are in source time and are made relative on creation.
public struct CaptionWord: Sendable, Hashable, Codable {
    public var text: String
    public var range: TimeRange
    public init(text: String, range: TimeRange) { self.text = text; self.range = range }
}

/// The karaoke word highlight (the TikTok look): the word being spoken is drawn in the highlight colour.
/// Stored on the caption track; the colour is plain sRGB so SQCore needs no colour type.
public struct KaraokeStyle: Sendable, Hashable, Codable {
    public var red: Double, green: Double, blue: Double
    /// True: words already spoken stay in the highlight colour (a progressive fill); false: only the current word.
    public var keepSpoken: Bool

    public init(red: Double = 1, green: Double = 0.86, blue: Double = 0.1, keepSpoken: Bool = false) {
        self.red = min(1, max(0, red)); self.green = min(1, max(0, green)); self.blue = min(1, max(0, blue))
        self.keepSpoken = keepSpoken
    }
}

/// A colour key of the karaoke highlight: from `time` on, word `activeWord` is lit (nil: none).
public struct KaraokeKey: Sendable, Hashable {
    public var time: Time
    public var activeWord: Int?
}

extension CaptionItem {
    /// The words of the text, across all lines.
    public var tokens: [String] { lines.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) } }

    /// True when the stored word timings still match the text (editing a word keeps them, adding or removing one does not).
    public var hasWordTimings: Bool { !words.isEmpty && words.count == tokens.count }

    /// Moves the stored word origin when the start of the caption moves by `delta` without the speech moving (head trim).
    public mutating func shiftWordOrigin(by delta: Time) {
        guard !words.isEmpty, delta != .zero else { return }
        words = words.map { CaptionWord(text: $0.text, range: TimeRange(start: $0.range.start - delta, end: $0.range.end - delta)) }
    }

    /// One timed word per word of the text (absolute timeline time, clamped into the caption): the stored timings while
    /// they match, else the range spread over the words
    /// by their length (so captions typed by hand highlight too). Always rational.
    public var effectiveWords: [CaptionWord] {
        let toks = tokens
        guard !toks.isEmpty else { return [] }
        if hasWordTimings {
            func clamp(_ t: Time) -> Time { min(max(t, range.start), range.end) }
            return zip(toks, words).map { tok, w in
                let a = clamp(range.start + w.range.start), b = max(clamp(range.start + w.range.end), a)
                return CaptionWord(text: tok, range: TimeRange(start: a, end: b))
            }
        }
        let total = Int64(toks.reduce(0) { $0 + max($1.count, 1) })
        let d = range.duration
        var cum: Int64 = 0
        return toks.map { tok in
            let a = cum; cum += Int64(max(tok.count, 1))
            func at(_ n: Int64) -> Time { range.start + Time(d.value * n, d.timescale * total) }
            return CaptionWord(text: tok, range: TimeRange(start: at(a), end: at(cum)))
        }
    }

    /// Per-word colour keys: each word lights up when it starts and stays lit until the next one starts (a pause keeps
    /// the spoken word on); the last key switches everything off at the end of the last word.
    public var karaokeKeys: [KaraokeKey] {
        let w = effectiveWords
        guard !w.isEmpty else { return [] }
        var keys: [KaraokeKey] = []
        var last: Time?
        for (i, word) in w.enumerated() {
            let t = max(word.range.start, last ?? word.range.start)
            keys.append(KaraokeKey(time: t, activeWord: i)); last = t
        }
        keys.append(KaraokeKey(time: max(w[w.count - 1].range.end, last ?? .zero), activeWord: nil))
        return keys
    }

    /// The lit word at timeline time `t` (nil before the first word, after the last one and outside the caption).
    public func activeWord(at t: Time) -> Int? {
        guard range.contains(t) else { return nil }
        var result: Int?
        for k in karaokeKeys { if k.time <= t { result = k.activeWord } else { break } }
        return result
    }
}
