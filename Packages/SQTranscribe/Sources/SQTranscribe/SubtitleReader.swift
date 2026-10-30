import Foundation
import SQCore

/// Imports `.srt`, `.vtt` (WebVTT) and `.ass`/`.ssa` subtitles through one entry point. Styling is ignored: only cue
/// times and text are read (ASS override tags `{...}` and WebVTT markup are stripped).
public enum SubtitleReader {
    public static let fileExtensions = ["srt", "vtt", "ass", "ssa"]

    public enum Format: Sendable { case srt, vtt, ass }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// Format from a file extension (case-insensitive); nil when it is not a subtitle type.
    public static func format(forExtension ext: String) -> Format? {
        switch ext.lowercased() {
        case "srt": return .srt
        case "vtt": return .vtt
        case "ass", "ssa": return .ass
        default: return nil
        }
    }

    public static func parse(data: Data, format: Format, language: String = "und",
                             styleRef: String = "default", animationRef: String = "none") throws -> SRTReader.Document {
        let text = SRTReader.decode(data)
        switch format {
        case .srt: return try SRTReader.parse(text: text, language: language, styleRef: styleRef, animationRef: animationRef)
        case .vtt: return try parseVTT(text: text, language: language, styleRef: styleRef, animationRef: animationRef)
        case .ass: return try parseASS(text: text, language: language, styleRef: styleRef, animationRef: animationRef)
        }
    }

    // MARK: - WebVTT

    public static func parseVTT(text: String, language: String = "und",
                                styleRef: String = "default", animationRef: String = "none") throws -> SRTReader.Document {
        let lines = normalize(text)
        var cues: [SRTReader.Cue] = []
        var i = 0
        // Header: "WEBVTT" optionally followed by text, up to the first blank line.
        if let first = lines.first, first.hasPrefix("WEBVTT") {
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        }
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            // One block up to the next blank line.
            let blockStart = i
            var block: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { block.append(lines[i]); i += 1 }
            let head = block[0].trimmingCharacters(in: .whitespaces)
            if head == "NOTE" || head.hasPrefix("NOTE ") || head.hasPrefix("NOTE\t") || head == "STYLE" || head == "REGION" { continue }
            guard let timingIdx = block.firstIndex(where: { $0.contains("-->") }) else { continue }  // stray text
            let ln = blockStart + timingIdx + 1
            let parts = block[timingIdx].components(separatedBy: "-->")
            guard parts.count == 2 else { throw ParseError(line: ln, message: "malformed timing line") }
            let startText = parts[0].trimmingCharacters(in: .whitespaces)
            // Cue settings (line:, position:, align:) follow the end time and are ignored.
            let endText = parts[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard let start = vttTime(startText) else { throw ParseError(line: ln, message: "malformed start time '\(startText)'") }
            guard let end = vttTime(endText) else { throw ParseError(line: ln, message: "malformed end time '\(endText)'") }
            guard end >= start else { throw ParseError(line: ln, message: "end time before start time") }
            let textLines = block[(timingIdx + 1)...].map { decodeEntities(SRTReader.stripTags($0)).trimmingCharacters(in: .whitespaces) }
            cues.append(SRTReader.Cue(start: start, end: end, lines: textLines))
        }
        return SRTReader.makeDocument(cues: cues, language: language, styleRef: styleRef, animationRef: animationRef)
    }

    /// `[H+:]MM:SS.mmm`.
    static func vttTime(_ s: String) -> Time? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let h: Int64 = parts.count == 3 ? (digits(parts[0]) ?? -1) : 0
        let m = digits(parts[parts.count - 2]) ?? -1
        guard h >= 0, (0..<60).contains(m) else { return nil }
        let sec = parts[parts.count - 1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(sec.count), sec[0].count == 2, let s0 = digits(sec[0]), s0 < 60 else { return nil }
        var ms: Int64 = 0
        if sec.count == 2 {
            guard (1...3).contains(sec[1].count), let f = digits(sec[1]) else { return nil }
            ms = f * (sec[1].count == 1 ? 100 : sec[1].count == 2 ? 10 : 1)
        }
        return Time(((h * 60 + m) * 60 + s0) * 1000 + ms, 1000)
    }

    // MARK: - ASS / SSA

    public static func parseASS(text: String, language: String = "und",
                                styleRef: String = "default", animationRef: String = "none") throws -> SRTReader.Document {
        let lines = normalize(text)
        var inEvents = false
        var sawEvents = false
        var columns: [String] = []
        var cues: [SRTReader.Cue] = []
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inEvents = line.lowercased() == "[events]"
                sawEvents = sawEvents || inEvents
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                columns = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }   // Comment:, Picture:, ...
            guard let startCol = columns.firstIndex(of: "start"), let endCol = columns.firstIndex(of: "end"),
                  let textCol = columns.firstIndex(of: "text") else {
                throw ParseError(line: idx + 1, message: "Dialogue before a Format line with Start, End and Text")
            }
            // Text is the last column and may itself contain commas.
            let fields = line.dropFirst(9).split(separator: ",", maxSplits: columns.count - 1, omittingEmptySubsequences: false)
            guard fields.count == columns.count else { throw ParseError(line: idx + 1, message: "wrong number of fields") }
            let startText = fields[startCol].trimmingCharacters(in: .whitespaces)
            let endText = fields[endCol].trimmingCharacters(in: .whitespaces)
            guard let start = assTime(startText) else { throw ParseError(line: idx + 1, message: "malformed start time '\(startText)'") }
            guard let end = assTime(endText) else { throw ParseError(line: idx + 1, message: "malformed end time '\(endText)'") }
            guard end >= start else { throw ParseError(line: idx + 1, message: "end time before start time") }
            let body = String(fields[textCol])
            if body.contains("\\p1") { continue }   // vector drawing, not text
            cues.append(SRTReader.Cue(start: start, end: end, lines: assText(body)))
        }
        guard sawEvents else { throw ParseError(line: 1, message: "no [Events] section, this does not look like an ASS file") }
        cues.sort { $0.start < $1.start }
        return SRTReader.makeDocument(cues: cues, language: language, styleRef: styleRef, animationRef: animationRef)
    }

    /// `H:MM:SS.cc` (centiseconds, tolerates 1 to 3 fraction digits).
    static func assTime(_ s: String) -> Time? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let sec = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(sec.count), let h = digits(parts[0]), let m = digits(parts[1]), m < 60,
              let s0 = digits(sec[0]), s0 < 60 else { return nil }
        var ms: Int64 = 0
        if sec.count == 2 {
            guard (1...3).contains(sec[1].count), let f = digits(sec[1]) else { return nil }
            ms = f * (sec[1].count == 1 ? 100 : sec[1].count == 2 ? 10 : 1)
        }
        return Time(((h * 60 + m) * 60 + s0) * 1000 + ms, 1000)
    }

    /// Strips `{...}` override blocks, turns `\N` / `\n` into line breaks and `\h` into a space.
    static func assText(_ s: String) -> [String] {
        var out = ""
        var inBrace = false
        var it = s.makeIterator()
        while let ch = it.next() {
            if inBrace { if ch == "}" { inBrace = false }; continue }
            if ch == "{" { inBrace = true; continue }
            if ch == "\\" {
                guard let n = it.next() else { break }
                switch n {
                case "N", "n": out.append("\n")
                case "h": out.append(" ")
                default: out.append("\\"); out.append(n)
                }
                continue
            }
            out.append(ch)
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Shared

    private static func digits(_ x: Substring) -> Int64? {
        guard !x.isEmpty, x.count <= 9, x.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(x)
    }

    private static func normalize(_ text: String) -> [String] {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lrm;", with: "")
            .replacingOccurrences(of: "&rlm;", with: "").replacingOccurrences(of: "&amp;", with: "&")
    }
}
