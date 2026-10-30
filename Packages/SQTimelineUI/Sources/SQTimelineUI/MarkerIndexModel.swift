import Foundation
import SQCore

/// The marker list (timeline index): every sequence marker and every clip marker the timeline shows, in time order,
/// with a text filter and a color filter. Pure model; `MarkerIndexView` draws it, the App hosts the view and wires
/// `onGo` (move the playhead) and the CSV export (`SQExport.MarkerCSV`).
public struct MarkerIndexEntry: Sendable, Equatable, Identifiable {
    public enum Scope: Sendable, Equatable {
        case sequence
        case clip(Clip.ID, name: String)
    }
    public var marker: Marker.ID
    public var scope: Scope
    /// Sequence time of the marker.
    public var time: Time
    public var duration: Time
    public var name: String
    public var color: MarkerColor
    public var comment: String
    /// Unique per row: a speed track may show one clip marker several times, a marker id repeats then.
    public var id: String {
        switch scope {
        case .sequence: "s-\(marker.uuidString)"
        case .clip(let c, _): "c-\(c.uuidString)-\(marker.uuidString)-\(time.value)/\(time.timescale)"
        }
    }
    public var scopeLabel: String {
        switch scope {
        case .sequence: "Sequence"
        case .clip(_, let name): name
        }
    }
}

public struct MarkerIndexModel: Sendable, Equatable {
    public private(set) var entries: [MarkerIndexEntry] = []
    /// Case-insensitive match on name, comment and clip name. Empty = every row.
    public var query = ""
    /// nil = every color.
    public var color: MarkerColor?
    public private(set) var frameDuration = Time(1, 30)
    public private(set) var timecodeStart = Time.zero
    public private(set) var display = TimecodeDisplay.timecode

    public init() {}
    public init(timeline: Timeline) { reload(timeline) }

    public mutating func reload(_ timeline: Timeline) {
        frameDuration = timeline.frameDuration
        timecodeStart = timeline.timecodeStart
        display = timeline.timecodeDisplay
        var out = timeline.markers.map {
            MarkerIndexEntry(marker: $0.id, scope: .sequence, time: $0.time, duration: $0.duration,
                             name: $0.name, color: $0.color, comment: $0.comment)
        }
        for track in timeline.tracks {
            for c in track.clips where !(c.markers ?? []).isEmpty {
                for m in c.visibleMarkers(frameDuration: timeline.frameDuration) {
                    out.append(MarkerIndexEntry(marker: m.id, scope: .clip(c.id, name: c.name), time: c.start + m.time,
                                                duration: m.duration, name: m.name, color: m.color, comment: m.comment))
                }
            }
        }
        entries = out.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// The rows the filters leave.
    public var rows: [MarkerIndexEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            if let color, e.color != color { return false }
            guard !q.isEmpty else { return true }
            return e.name.localizedCaseInsensitiveContains(q) || e.comment.localizedCaseInsensitiveContains(q)
                || e.scopeLabel.localizedCaseInsensitiveContains(q)
        }
    }

    /// Colors that occur, in the palette's order (for the color filter).
    public var colorsInUse: [MarkerColor] {
        let used = Set(entries.map(\.color))
        return MarkerColor.allCases.filter(used.contains)
    }

    /// Position text of `time` as the sequence shows it (timecode with its start, or a frame count).
    public func text(for time: Time) -> String {
        let frames = max(0, time.frameIndex(frameDuration: frameDuration)) + timecodeStart.frameIndex(frameDuration: frameDuration)
        switch display {
        case .frames: return String(frames)
        case .timecode: return CMXTimecode(frameDuration: frameDuration).string(frames: frames)
        }
    }

    /// Length text: a plain duration, not shifted by the timecode start. Empty for a point marker.
    public func durationText(of e: MarkerIndexEntry) -> String {
        guard e.duration > .zero else { return "" }
        let frames = max(0, e.duration.frameIndex(frameDuration: frameDuration))
        switch display {
        case .frames: return String(frames)
        case .timecode: return CMXTimecode(frameDuration: frameDuration).string(frames: frames)
        }
    }

    /// Index in `rows` of the last row at or before `time` (the marker the playhead is "in"); nil before the first.
    public func currentRow(at time: Time) -> Int? {
        rows.lastIndex { $0.time <= time }
    }
}
