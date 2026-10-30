import Foundation
import SQCore

/// The read-only caption list (time and text, a click seeks): every caption of the timeline in time order.
/// A plain value; build it again when the timeline changes. Editing happens on the caption track, not here.
public struct CaptionListModel: Sendable, Equatable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: CaptionItem.ID
        public var track: CaptionTrack.ID
        public var range: TimeRange
        /// Start as timecode.
        public var time: String
        /// All lines on one row.
        public var text: String
    }

    public private(set) var rows: [Row] = []

    public init() {}

    /// - Parameter visibleOnly: leave out hidden caption tracks.
    public init(timeline: Timeline?, timecode: Timecode, visibleOnly: Bool = false) {
        guard let timeline else { return }
        var out: [Row] = []
        for t in timeline.captionTracks where !visibleOnly || t.isVisible {
            for item in t.items {
                out.append(Row(id: item.id, track: t.id, range: item.range, time: timecode.format(item.range.start),
                               text: item.lines.joined(separator: " ")))
            }
        }
        // One track is already in order; several are merged by start (stable, so equal starts keep track order).
        if timeline.captionTracks.count > 1 {
            out = out.enumerated().sorted { ($0.element.range.start, $0.offset) < ($1.element.range.start, $1.offset) }.map(\.element)
        }
        rows = out
    }

    /// The row spoken at `playhead`: the last row that starts at or before it and has not ended. Binary search.
    public func currentRow(at playhead: Time) -> Int? {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].range.start <= playhead { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        // Rows of several tracks can overlap: look back a few rows for one that still runs.
        while i >= 0, lo - i <= 4 {
            if rows[i].range.contains(playhead) { return i }
            i -= 1
        }
        return nil
    }

    /// Where a click on row `index` seeks to.
    public func seekTime(row index: Int) -> Time? { rows.indices.contains(index) ? rows[index].range.start : nil }
}
