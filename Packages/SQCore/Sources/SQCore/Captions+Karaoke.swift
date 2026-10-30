import Foundation

/// One spoken word of a caption. Inside a `CaptionItem` the range is relative to the item's start, so moving, rippling
/// and tail-trimming a caption keep its words right without touching them (a head trim shifts them by the trimmed
/// amount). `Caption.words` of a transcript (SQTranscribe) are in source time and are made relative on creation.
public struct CaptionWord: Sendable, Hashable, Codable {
    public var text: String
    public var range: TimeRange
    /// How sure the recognizer was about this word, 0...1 (nil: unknown, never written to the file). Editing the text by
    /// hand clears it (the editor confirmed the word); splitting, merging and retiming keep it.
    public var confidence: Float?
    public init(text: String, range: TimeRange, confidence: Float? = nil) {
        self.text = text; self.range = range; self.confidence = confidence
    }

    /// Words below this confidence are marked in the caption editor so mistakes are found fast.
    public static let unsureBelow: Float = 0.5
    /// True when the recognizer reported a confidence under `unsureBelow`.
    public var isUnsure: Bool { Self.isUnsure(confidence: confidence) }
    /// The one rule for every surface (timeline, transcript panel): nil (hand-typed or none reported) is never unsure.
    public static func isUnsure(confidence: Float?) -> Bool { confidence.map { $0 < unsureBelow } ?? false }
}

/// The karaoke word highlight (the TikTok look): the word being spoken is drawn in the highlight color.
/// Stored on the caption track; the color is plain sRGB so SQCore needs no color type.
public struct KaraokeStyle: Sendable, Hashable, Codable {
    public var red: Double, green: Double, blue: Double
    /// True: words already spoken stay in the highlight color (a progressive fill); false: only the current word.
    public var keepSpoken: Bool

    public init(red: Double = 1, green: Double = 0.86, blue: Double = 0.1, keepSpoken: Bool = false) {
        self.red = min(1, max(0, red)); self.green = min(1, max(0, green)); self.blue = min(1, max(0, blue))
        self.keepSpoken = keepSpoken
    }
}

/// A color key of the karaoke highlight: from `time` on, word `activeWord` is lit (nil: none).
public struct KaraokeKey: Sendable, Hashable {
    public var time: Time
    public var activeWord: Int?
}

extension CaptionItem {
    /// The words of the text, across all lines.
    public var tokens: [String] { lines.flatMap { WordSegmentation.words($0) } }

    /// True when the stored word timings still match the text (editing a word keeps them, adding or removing one does not).
    public var hasWordTimings: Bool { !words.isEmpty && words.count == tokens.count }

    /// Moves the stored word origin when the start of the caption moves by `delta` without the speech moving (head trim).
    public mutating func shiftWordOrigin(by delta: Time) {
        guard !words.isEmpty, delta != .zero else { return }
        words = words.map { CaptionWord(text: $0.text, range: TimeRange(start: $0.range.start - delta, end: $0.range.end - delta), confidence: $0.confidence) }
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
                return CaptionWord(text: tok, range: TimeRange(start: a, end: b), confidence: w.text == tok ? w.confidence : nil)
            }
        }
        let total = Int64(toks.reduce(0) { $0 + max($1.count, 1) })
        let d = range.duration
        var cum: Int64 = 0
        return toks.map { tok in
            let a = cum; cum += Int64(max(tok.count, 1))
            // Huge timescales round (see Time(reducing:)): clamp so a word never ends before it starts.
            func at(_ n: Int64) -> Time {
                n == total ? range.end : min(max(range.start + Time.scaled(d, by: n, over: total), range.start), range.end)
            }
            let s = at(a)
            return CaptionWord(text: tok, range: TimeRange(start: s, end: max(at(cum), s)))
        }
    }

    /// Per-word color keys: each word lights up when it starts and stays lit until the next one starts (a pause keeps
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
