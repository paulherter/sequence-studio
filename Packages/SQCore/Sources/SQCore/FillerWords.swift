import Foundation

/// Filler-word detection on the timed caption words (the project's transcript data): "um", "uh", "äh", "ähm" and the like become
/// frame-aligned cuts for the same ripple path as Remove Silences. The list depends on the language: German "um" is a real word.
public enum FillerWords {
    /// Sounds that are never a real word in the languages we know (also the whole list for a language without its own).
    static let neutral: Set<String> = ["uh", "uhh", "uhm", "hm", "hmm", "hmmm", "mm", "mmm", "mhm", "äh", "ähh", "ähm", "ähhm", "öh", "öhm", "ehm"]
    static let own: [String: Set<String>] = [
        "en": ["um", "umm", "er", "erm"],
        "de": ["äm", "ämm"],
        "fr": ["euh", "euhh"],
    ]

    /// Words of `language` (BCP-47, only the language part counts) that count as filler.
    public static func list(for language: String) -> Set<String> {
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
        return neutral.union(own[base] ?? [])
    }

    /// `text` without punctuation around it, lowercased.
    static func normalised(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    public static func isFiller(_ text: String, language: String) -> Bool { list(for: language).contains(normalised(text)) }

    public static func count(words: [CaptionWord], language: String) -> Int { words.filter { isFiller($0.text, language: language) }.count }

    /// Cuts for the filler words among `words` (timeline time): each from the nearest frame to its start to the nearest frame to
    /// its end, sorted, touching ones joined, shorter than a frame dropped.
    public static func cuts(words: [CaptionWord], language: String, frameDuration: Time) -> [TimeRange] {
        guard frameDuration > .zero else { return [] }
        let half = Time(frameDuration.value, frameDuration.timescale * 2)
        func nearest(_ t: Time) -> Time { frameDuration * (t + half).frameIndex(frameDuration: frameDuration) }
        let raw = words.filter { isFiller($0.text, language: language) }.compactMap { w -> TimeRange? in
            let a = nearest(w.range.start), b = nearest(w.range.end)
            return b - a >= frameDuration ? TimeRange(start: a, duration: b - a) : nil
        }
        return SilenceRemoval.normalized(raw)
    }

    public struct Scan: Sendable, Equatable {
        /// Filler words found (before cuts joined neighbors).
        public var count: Int
        public var cuts: [TimeRange]
        /// Captions with text but no word timings: their words are only spread over the caption, so they are left alone.
        public var untimedCaptions: Int
        public init(count: Int = 0, cuts: [TimeRange] = [], untimedCaptions: Int = 0) {
            self.count = count; self.cuts = cuts; self.untimedCaptions = untimedCaptions
        }
        public var total: Time { cuts.reduce(Time.zero) { $0 + $1.duration } }
    }

    /// Fillers in the timed words of every visible caption track of `timeline`.
    public static func scan(_ timeline: Timeline, language: String) -> Scan {
        var words: [CaptionWord] = []
        var untimed = 0
        for track in timeline.captionTracks where track.isVisible {
            for item in track.items where !item.tokens.isEmpty {
                if item.hasWordTimings { words += item.effectiveWords } else { untimed += 1 }
            }
        }
        let found = cuts(words: words, language: language, frameDuration: timeline.frameDuration)
        return Scan(count: count(words: words, language: language), cuts: found, untimedCaptions: untimed)
    }
}
