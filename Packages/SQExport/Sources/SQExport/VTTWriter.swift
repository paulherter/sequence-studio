import Foundation
import SQCore

/// WebVTT (.vtt) output: the same cues and range handling as `SRTWriter`, `HH:MM:SS.mmm` timecodes, LF line ends.
/// `&` and `<` in cue text are escaped (a raw `<` would start a tag), `-->` inside text is broken up.
public enum VTTWriter {
    public static func timecode(_ t: Time) -> String { SRTWriter.timecode(t).replacingOccurrences(of: ",", with: ".") }

    static func escape(_ line: String) -> String {
        line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "-->", with: "-&gt;")
    }

    public static func render(_ cues: [SRTCue], range: RangeSelection) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues.enumerated().sorted(by: { ($0.element.range.start, $0.offset) < ($1.element.range.start, $1.offset) }).map(\.element) {
            let lines = cue.lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { continue }
            var r = cue.range
            var offset = Time.zero
            if case .inOut(let window) = range {
                guard let clipped = r.intersection(window) else { continue }
                r = clipped; offset = window.start
            }
            guard SRTWriter.milliseconds(r.end - offset) > max(0, SRTWriter.milliseconds(r.start - offset)) else { continue }
            out += "\(timecode(r.start - offset)) --> \(timecode(r.end - offset))\n"
            out += lines.map(escape).joined(separator: "\n") + "\n\n"
        }
        return out
    }

    public static func write(_ cues: [SRTCue], range: RangeSelection, to url: URL) throws {
        try Data(render(cues, range: range).utf8).write(to: url, options: .atomic)
    }
}
