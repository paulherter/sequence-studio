import Foundation
import SSCore

/// Imports `.srt` subtitles as captions plus an approximate word-level transcript, so imported
/// subtitles can be edited like a recognised transcript.
public enum SRTReader {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        /// 1-based line number in the (line-ending-normalised) input.
        public var line: Int
        public var message: String
        public var description: String { "SRT line \(line): \(message)" }
    }

    public struct Document: Sendable, Hashable {
        public var captions: [Caption]
        public var transcript: Transcript
    }

    public static func parse(data: Data, language: String = "und",
                             styleRef: String = "default", animationRef: String = "none") throws -> Document {
        try parse(text: decode(data), language: language, styleRef: styleRef, animationRef: animationRef)
    }

    public static func parse(text: String, language: String = "und",
                             styleRef: String = "default", animationRef: String = "none") throws -> Document {
        var normalized = text
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var words: [TranscriptWord] = []
        var captions: [Caption] = []
        var i = 0
        while i < lines.count {
            let raw = lines[i].trimmingCharacters(in: .whitespaces)
            guard raw.contains("-->") else { i += 1; continue }   // blanks, indices, stray text
            let (start, end) = try parseTimes(raw, line: i + 1)
            i += 1
            var textLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.contains("-->") { break }   // next cue without blank separator
                textLines.append(stripTags(l).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            // A trailing pure-number line belongs to the next cue (missing blank line).
            if let last = textLines.last, i < lines.count, lines[i].contains("-->"),
               !last.isEmpty, last.allSatisfy(\.isNumber) { textLines.removeLast() }
            textLines = textLines.filter { !$0.isEmpty }
            let cueWords = textLines.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            guard !cueWords.isEmpty else { continue }

            let first = words.count
            let total = Int64(cueWords.reduce(0) { $0 + $1.count })
            let duration = end - start
            var cum: Int64 = 0
            var prev = start
            for w in cueWords {
                cum += Int64(w.count)
                let next = cum == total ? end : start + Time(duration.value * cum, duration.timescale * total)
                words.append(TranscriptWord(text: w, range: TimeRange(start: prev, end: next), isEdited: false))
                prev = next
            }
            captions.append(Caption(
                lines: textLines, range: TimeRange(start: start, end: end),
                firstWordID: words[first].id, lastWordID: words[words.count - 1].id,
                wordIndices: first..<words.count, styleRef: styleRef, animationRef: animationRef))
        }
        return Document(captions: captions, transcript: Transcript(language: language, words: words))
    }

    // MARK: - Internals

    private static func decode(_ data: Data) -> String {
        let b = [UInt8](data.prefix(3))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if b.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func parseTimes(_ s: String, line: Int) throws -> (Time, Time) {
        let parts = s.components(separatedBy: "-->")
        guard parts.count == 2 else { throw ParseError(line: line, message: "malformed timestamp line") }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        // Ignore positional settings after the end time ("X1:0 Y1:0 ...").
        let endText = parts[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let start = timestamp(startText) else { throw ParseError(line: line, message: "malformed start time '\(startText)'") }
        guard let end = timestamp(endText) else { throw ParseError(line: line, message: "malformed end time '\(endText)'") }
        guard end >= start else { throw ParseError(line: line, message: "end time before start time") }
        return (start, end)
    }

    /// `H+:MM:SS` with `,` or `.` and 1-3 fraction digits, or no fraction.
    private static func timestamp(_ s: String) -> Time? {
        func digits(_ x: Substring) -> Int64? {
            guard !x.isEmpty, x.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(x)
        }
        let hms = s.split(separator: ":", omittingEmptySubsequences: false)
        guard hms.count == 3, hms[0].count <= 3, hms[1].count == 2,
              let h = digits(hms[0]), let m = digits(hms[1]), m < 60 else { return nil }
        let secParts = hms[2].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        guard (1...2).contains(secParts.count), secParts[0].count == 2,
              let sec = digits(secParts[0]), sec < 60 else { return nil }
        var ms: Int64 = 0
        if secParts.count == 2 {
            let frac = secParts[1]
            guard frac.count <= 3, let f = digits(frac) else { return nil }
            ms = f * (frac.count == 1 ? 100 : frac.count == 2 ? 10 : 1)
        }
        return Time(((h * 60 + m) * 60 + sec) * 1000 + ms, 1000)
    }

    /// Removes `<...>` tags (i, b, u, font, ...) and `{\an8}`-style override blocks.
    private static func stripTags(_ s: String) -> String {
        var out = ""
        var close: Character?
        for ch in s {
            if let c = close {
                if ch == c { close = nil }
            } else if ch == "<" {
                close = ">"
            } else if ch == "{" {
                close = "}"
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
