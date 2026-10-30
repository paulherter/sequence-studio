import Foundation
import SQCore

/// iTunes Timed Text (.itt): TTML with media-time clock times for video stores and Apple players. Same cues and range
/// handling as `SRTWriter` / `VTTWriter`; `HH:MM:SS.mmm`, UTF-8, LF. One bottom-centered region, white text.
/// shortcut: no per-cue position, color or italics (cue text is plain lines), upgrade when caption looks should be exported.
public enum ITTWriter {
    static func escape(_ line: String) -> String {
        line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func render(_ cues: [SRTCue], language: String, range: RangeSelection) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" ttp:timeBase="media" xml:lang="\(escape(language))">
        <head>
        <styling>
        <style xml:id="s1" tts:fontFamily="sansSerif" tts:fontSize="100%" tts:fontWeight="normal" tts:color="white" tts:textAlign="center"/>
        </styling>
        <layout>
        <region xml:id="bottom" tts:origin="10% 80%" tts:extent="80% 20%" tts:displayAlign="after"/>
        </layout>
        </head>
        <body>
        <div>

        """
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
            out += "<p begin=\"\(VTTWriter.timecode(r.start - offset))\" end=\"\(VTTWriter.timecode(r.end - offset))\" region=\"bottom\" style=\"s1\">"
            out += lines.map(escape).joined(separator: "<br/>") + "</p>\n"
        }
        out += "</div>\n</body>\n</tt>\n"
        return out
    }

    public static func write(_ cues: [SRTCue], language: String, range: RangeSelection, to url: URL) throws {
        try Data(render(cues, language: language, range: range).utf8).write(to: url, options: .atomic)
    }
}
