import Foundation
import SQCore

/// Marker list as CSV: one row per sequence marker and per clip marker shown on the timeline, in time order.
/// Columns: Scope, Name, Color, In, Out, Duration, Comment. Times are timecode (drop frame for 29.97 / 59.94) of the
/// sequence, shifted by the sequence's timecode start. Text cells that a spreadsheet would run as a formula (first
/// character `=`, `+`, `-`, `@`, tab or CR) get a leading `'`. UTF-8 with CRLF line ends (RFC 4180).
public enum MarkerCSV {
    public struct Row: Sendable, Equatable {
        public var scope: String
        public var name: String
        public var color: String
        public var time: Time
        public var duration: Time
        public var comment: String
        public init(scope: String, name: String, color: String, time: Time, duration: Time, comment: String) {
            self.scope = scope; self.name = name; self.color = color
            self.time = time; self.duration = duration; self.comment = comment
        }
    }

    public static let header = ["Scope", "Name", "Color", "In", "Out", "Duration", "Comment"]

    /// Sequence markers (scope "Sequence") and visible clip markers (scope "Clip: <clip name>"), sorted by time.
    public static func rows(for timeline: Timeline) -> [Row] {
        var out = timeline.markers.map {
            Row(scope: "Sequence", name: $0.name, color: $0.color.rawValue, time: $0.time, duration: $0.duration, comment: $0.comment)
        }
        for track in timeline.tracks {
            for c in track.clips where !(c.markers ?? []).isEmpty {
                for m in c.visibleMarkers(frameDuration: timeline.frameDuration) {
                    out.append(Row(scope: "Clip: \(c.name)", name: m.name, color: m.color.rawValue,
                                   time: c.start + m.time, duration: m.duration, comment: m.comment))
                }
            }
        }
        // Stable: equal times keep sequence markers first, then clips in track order.
        return out.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    public static func render(_ rows: [Row], frameDuration: Time, timecodeStart: Time = .zero) -> String {
        let clock = CMXTimecode(frameDuration: frameDuration)
        let base = timecodeStart.frameIndex(frameDuration: frameDuration)
        func tc(_ t: Time) -> String { clock.string(frames: base + max(0, t.frameIndex(frameDuration: frameDuration))) }
        var lines = [header.map(cell).joined(separator: ",")]
        for r in rows {
            let cells = [r.scope, r.name, r.color, tc(r.time), tc(r.time + r.duration),
                         durationText(r.duration, frameDuration, clock), r.comment]
            lines.append(cells.map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A duration is a length: shown from 00:00:00:00, not shifted by the timecode start.
    private static func durationText(_ d: Time, _ fd: Time, _ clock: CMXTimecode) -> String {
        clock.string(frames: max(0, d.frameIndex(frameDuration: fd)))
    }

    /// One cell: formula-guarded, quoted when it holds a comma, quote, or line break.
    static func cell(_ text: String) -> String {
        var s = text
        if let f = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(f) { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func export(_ timeline: Timeline) -> InterchangeExport {
        InterchangeExport(text: render(rows(for: timeline), frameDuration: timeline.frameDuration, timecodeStart: timeline.timecodeStart),
                          warnings: [])
    }
}
