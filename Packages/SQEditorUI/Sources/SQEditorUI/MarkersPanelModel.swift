import Foundation
import SQCore

/// Marker colours as in Premiere's marker dialog (stored on `Marker`).
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
        switch column {
        case .name: onEdit?(.rename(id, text))
        case .comment: onEdit?(.setComment(id, text))
        case .color:
            guard let c = MarkerColorChoice(rawValue: text.lowercased()) else { return false }
            onEdit?(.setColor(id, c))
        case .inPoint:
            guard let t = Self.parseTimecode(text, frameDuration: frameDuration) else { return false }
            onEdit?(.move(id, t))
        case .duration:
            guard let t = Self.parseTimecode(text, frameDuration: frameDuration) else { return false }
            onEdit?(.setDuration(id, t))
        }
        return true
    }

    // MARK: Timecode (non-drop, HH:MM:SS:FF)

    static func framesPerSecond(_ fd: Time) -> Int64 {
        max(1, (fd.timescale + fd.value - 1) / max(1, fd.value))
    }

    public static func timecode(_ t: Time, frameDuration fd: Time) -> String {
        let fps = framesPerSecond(fd)
        let total = max(0, t.frameIndex(frameDuration: fd))
        let f = total % fps, secs = total / fps
        return String(format: "%02lld:%02lld:%02lld:%02lld", secs / 3600, (secs / 60) % 60, secs % 60, f)
    }

    /// Accepts `HH:MM:SS:FF`, `MM:SS:FF`, `SS:FF` or a plain frame count.
    public static func parseTimecode(_ text: String, frameDuration fd: Time) -> Time? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 4, !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        let v = parts.map { $0! }
        guard v.allSatisfy({ $0 <= 999_999_999 }) else { return nil }       // keeps the frame maths below Int64 overflow
        let fps = framesPerSecond(fd)
        let frames: Int64
        if v.count == 1 { frames = v[0] } else {
            guard v[v.count - 1] < fps else { return nil }
            var secs: Int64 = 0
            for p in v.dropLast() { secs = secs * 60 + p }
            frames = secs * fps + v[v.count - 1]
        }
        return fd * frames
    }
}
