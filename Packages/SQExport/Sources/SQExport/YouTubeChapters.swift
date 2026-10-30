import Foundation
import SQCore

/// Chapter list in the format YouTube reads from a video description: one `M:SS Title` line per chapter, the first
/// at 0:00. YouTube needs at least three chapters, each at least 10 s long, to turn the list into chapters.
public enum YouTubeChapters {
    public static let minimumChapters = 3
    public static let minimumLengthSeconds = 10

    public struct Result: Sendable, Equatable {
        public var text: String
        /// Plain-language reasons YouTube would not show these as chapters (empty = fine).
        public var warnings: [String]
    }

    static func stamp(_ whole: Int) -> String {
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Named sequence markers in time order, shifted by `rangeStart` (an In/Out export starts at 0:00). Markers before
    /// the range or after `duration` are dropped; a missing 0:00 chapter is added as "Intro".
    public static func make(from markers: [Marker], rangeStart: Time = .zero, duration: Time? = nil) -> Result {
        var items: [(Int, String)] = []
        for m in markers.sorted(by: { $0.time < $1.time }) {
            let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, m.time >= rangeStart else { continue }
            let t = m.time - rangeStart
            if let d = duration, t >= d { continue }
            let sec = Int(t.value / Int64(t.timescale))   // whole seconds, rounded down: YouTube has no sub-second stamps
            if let last = items.last, last.0 == sec { continue }
            items.append((sec, name.replacingOccurrences(of: "\n", with: " ")))
        }
        var warnings: [String] = []
        if items.first?.0 != 0 {
            items.insert((0, "Intro"), at: 0)
            warnings.append("No marker at the start: an \"Intro\" chapter was added at 0:00.")
        }
        if items.count < minimumChapters {
            warnings.append("YouTube needs at least \(minimumChapters) chapters; there are \(items.count).")
        }
        let total = duration.map { Int($0.value / Int64($0.timescale)) }
        for i in items.indices {
            let end = i + 1 < items.count ? items[i + 1].0 : total
            if let e = end, e - items[i].0 < minimumLengthSeconds {
                warnings.append("Chapter \"\(items[i].1)\" is shorter than \(minimumLengthSeconds) s.")
            }
        }
        return Result(text: items.map { "\(stamp($0.0)) \($0.1)" }.joined(separator: "\n"), warnings: warnings)
    }
}
