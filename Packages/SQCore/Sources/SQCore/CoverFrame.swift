import Foundation

/// The cover image of an export (a poster frame saved next to the video). The frame is chosen with a sequence marker
/// named "Cover"; without one the first exported frame is used. No file-format field: the marker is the setting.
public enum CoverFrame {
    public static let markerName = "Cover"

    /// Time of the earliest marker named "Cover" (case and surrounding spaces ignored), or nil.
    public static func time(markers: [Marker]) -> Time? {
        markers.filter { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(markerName) == .orderedSame }
            .map(\.time).min()
    }

    /// Index of the cover frame inside the exported frames (frame 0 = `rangeStart`), clamped to the range.
    public static func frameIndex(time: Time?, rangeStart: Time, frameDuration: Time, frameCount: Int) -> Int {
        guard let time, frameCount > 0, frameDuration.value > 0 else { return 0 }
        let rel = time - rangeStart
        if rel.isNegative { return 0 }
        return Int(min(max(rel.frameIndex(frameDuration: frameDuration), 0), Int64(frameCount - 1)))
    }

    /// "Trip" -> "Trip Cover.png".
    public static func fileName(videoStem: String, ext: String) -> String { "\(videoStem) Cover.\(ext)" }
}
