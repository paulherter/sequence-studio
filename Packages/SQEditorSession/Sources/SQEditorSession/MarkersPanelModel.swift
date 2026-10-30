import Foundation
import SQCore

/// Marker colors as in Premiere's marker dialog (stored on `Marker`).
public typealias MarkerColorChoice = MarkerColor

/// One table row. `color`, `duration` and `comment` are display values; they fall back to defaults
/// until `Marker` stores them (file format bump), then `MarkersPanelModel.rows` reads them.
public struct MarkerRow: Sendable, Equatable, Identifiable {
    public var id: Marker.ID
    public var color: MarkerColorChoice
    public var name: String
    public var time: Time
    public var inTimecode: String
    public var duration: Time
    public var durationTimecode: String
    public var comment: String
}

public enum MarkerColumn: String, Sendable, CaseIterable {
    case color, name, inPoint, duration, comment
}

/// Non-UI state of the Markers panel. The host applies `onEdit` to the timeline (via History).
@MainActor
public final class MarkersPanelModel {
    public enum Edit: Sendable, Equatable {
        case rename(Marker.ID, String)
        case setComment(Marker.ID, String)
        case setColor(Marker.ID, MarkerColorChoice)
        case setDuration(Marker.ID, Time)
        case move(Marker.ID, Time)
    }

    public private(set) var markers: [Marker] = []
    public private(set) var frameDuration: Time = Time(1, 30)
    public var onSeek: ((Time) -> Void)?
    public var onEdit: ((Edit) -> Void)?
    public var onChange: (() -> Void)?

    public init() {}

    public func update(markers: [Marker], frameDuration: Time) {
        self.markers = markers.sorted { $0.time < $1.time }
        self.frameDuration = frameDuration
        onChange?()
    }

    public var rows: [MarkerRow] {
        markers.map { m in
            MarkerRow(id: m.id, color: m.color, name: m.name, time: m.time,
                      inTimecode: Self.timecode(m.time, frameDuration: frameDuration),
                      duration: m.duration, durationTimecode: Self.timecode(m.duration, frameDuration: frameDuration),
                      comment: m.comment)
        }
    }

    /// Double-click on a row: seek the playhead to the marker.
    public func activate(row: Int) {
        guard markers.indices.contains(row) else { return }
        onSeek?(markers[row].time)
    }

    /// Inline edit commit. Returns false when the text is not valid for that column.
    @discardableResult
    public func commit(row: Int, column: MarkerColumn, text: String) -> Bool {
        guard markers.indices.contains(row) else { return false }
        let id = markers[row].id
        let current = rows[row]
        switch column {
        case .name: if text != current.name { onEdit?(.rename(id, text)) }
        case .comment: if text != current.comment { onEdit?(.setComment(id, text)) }
        case .color:
            guard let c = MarkerColorChoice(rawValue: text.lowercased()) else { return false }
            if c != current.color { onEdit?(.setColor(id, c)) }
        case .inPoint:
            guard let t = Self.parseTimecode(text, frameDuration: frameDuration) else { return false }
            if text != current.inTimecode { onEdit?(.move(id, t)) }        // the shown value is frame-floored: unchanged text moves nothing
        case .duration:
            guard let t = Self.parseTimecode(text, frameDuration: frameDuration) else { return false }
            if text != current.durationTimecode { onEdit?(.setDuration(id, t)) }
        }
        return true
    }

    // MARK: Timecode (the monitor's: drop-frame at 29.97 / 59.94, else non-drop)

    public static func timecode(_ t: Time, frameDuration fd: Time) -> String {
        Timecode(frameDuration: fd, dropFrame: true).format(max(t, .zero))
    }

    /// Accepts `HH:MM:SS:FF`, `MM:SS:FF`, `SS:FF` (`;` before the frames for drop-frame) or a plain frame count.
    public static func parseTimecode(_ text: String, frameDuration fd: Time) -> Time? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let frames = Int64(s), frames <= 999_999_999 else { return nil }     // keeps the maths below overflow
            return fd * frames
        }
        guard !s.hasPrefix("-"), let t = Timecode(frameDuration: fd, dropFrame: true).parse(s) else { return nil }
        return t
    }
}
