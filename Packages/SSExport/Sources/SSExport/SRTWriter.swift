import Foundation
import SSCore
import SSTranscribe

/// One subtitle cue on the sequence timeline. `lines` are kept exactly as segmented.
public struct SRTCue: Sendable, Hashable {
    public var lines: [String]
    public var range: TimeRange
    public init(lines: [String], range: TimeRange) { self.lines = lines; self.range = range }
}

/// SubRip (.srt) output. UTF-8, CRLF line endings (the SubRip convention; every common player accepts it).
/// Timecodes come from rational `Time` with integer arithmetic only: milliseconds are rounded to nearest, ties up.
public enum SRTWriter {
    public static func cues(from captions: [Caption]) -> [SRTCue] {
        captions.map { SRTCue(lines: $0.lines, range: $0.range) }
    }

    /// `HH:MM:SS,mmm` (hours grow past two digits if needed). Negative times clamp to zero.
    public static func timecode(_ t: Time) -> String {
        let ms = max(0, milliseconds(t))
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        func p(_ v: Int128, _ w: Int) -> String { let d = String(v); return String(repeating: "0", count: max(0, w - d.count)) + d }
        return "\(p(h, 2)):\(p(m, 2)):\(p(s, 2)),\(p(f, 3))"
    }

    /// Nearest millisecond, ties toward +infinity.
    static func milliseconds(_ t: Time) -> Int128 {
        let num = Int128(t.value) * 2000 + Int128(t.timescale)
        let den = Int128(t.timescale) * 2
        var q = num / den
        if num % den != 0 && (num < 0) != (den < 0) { q -= 1 }
        return q
    }

    /// Renders cues clipped to `range` and shifted so the range start is 00:00:00,000.
    /// Dropped: cues outside the range, without any non-blank line, or empty after rounding to milliseconds.
    /// Blank lines inside a cue are removed (a blank line would end the cue in SRT). Indices restart at 1.
    public static func render(_ cues: [SRTCue], range: RangeSelection) -> String {
        var out = ""
        var index = 0
        for cue in cues {
            let lines = cue.lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { continue }
            var r = cue.range
            var offset = Time.zero
            if case .inOut(let window) = range {
                guard let clipped = r.intersection(window) else { continue }
                r = clipped
                offset = window.start
            }
            let start = max(0, milliseconds(r.start - offset)), end = max(0, milliseconds(r.end - offset))
            guard end > start else { continue }
            index += 1
            out += "\(index)\r\n\(timecode(r.start - offset)) --> \(timecode(r.end - offset))\r\n"
            out += lines.joined(separator: "\r\n") + "\r\n\r\n"
        }
        return out
    }

    public static func write(_ cues: [SRTCue], range: RangeSelection, to url: URL) throws {
        try Data(render(cues, range: range).utf8).write(to: url, options: .atomic)
    }
}
