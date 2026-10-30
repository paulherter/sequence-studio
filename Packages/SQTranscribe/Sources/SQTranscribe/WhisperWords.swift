import Foundation
import SQCore

/// One token as whisper.cpp reports it: raw UTF-8 bytes (a character can be split across tokens), position in
/// centiseconds and the token probability.
public struct WhisperToken: Sendable, Equatable {
    public var bytes: [UInt8]
    /// Control tokens ([_BEG_], <|endoftext|>, timestamps): never part of the text.
    public var isSpecial: Bool
    public var startCs: Int64
    public var endCs: Int64
    public var probability: Float

    public init(bytes: [UInt8], isSpecial: Bool, startCs: Int64, endCs: Int64, probability: Float) {
        self.bytes = bytes; self.isSpecial = isSpecial; self.startCs = startCs; self.endCs = endCs; self.probability = probability
    }
}

/// Words out of whisper tokens (portable, so the grouping is tested on the Mac).
public enum WhisperWords {
    /// A token that starts with a space starts a word; a token without one (punctuation, the rest of a word) belongs to the
    /// word before it. The word's time runs from its first to its last token, its confidence is its lowest token probability.
    /// Times never go backwards: start is at least the previous start, end at least its own start.
    public static func words(from tokens: [WhisperToken]) -> [TranscriptWord] {
        struct Open { var bytes: [UInt8] = []; var start: Int64 = 0; var end: Int64 = 0; var p: Float = 1 }
        var out: [TranscriptWord] = []
        var cur: Open?
        var lastStart: Int64 = 0
        func flush() {
            guard let c = cur else { return }
            cur = nil
            let text = String(decoding: c.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let start = max(c.start, lastStart)
            let end = max(c.end, start)
            lastStart = start
            out.append(TranscriptWord(text: text, range: TimeRange(start: Time(start, 100), end: Time(end, 100)), confidence: min(1, max(0, c.p))))
        }
        for t in tokens where !t.isSpecial {
            let startsWord = t.bytes.first.map { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 } ?? false
            if startsWord || cur == nil { flush(); cur = Open(start: t.startCs, end: t.endCs, p: t.probability) }
            guard var c = cur else { continue }
            c.bytes += t.bytes
            c.end = max(c.end, t.endCs)
            c.p = min(c.p, t.probability)
            cur = c
        }
        flush()
        return out
    }
}
