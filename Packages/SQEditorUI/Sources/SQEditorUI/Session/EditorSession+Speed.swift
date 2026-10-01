import Foundation
import SQCore

extension EditorSession {
    /// Selected clips that have a constant speed (media clips; not nested sequences, titles or stills), in track order.
    public var retimableSelection: [Clip] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && Timeline.canRetime($0) }
    }

    /// Speed/Duration is available for this selection.
    public var canSetSpeed: Bool { !retimableSelection.isEmpty }

    /// Model for the Speed/Duration dialog; nil without a retimable selection.
    public func speedDialogModel() -> SpeedDialogModel? {
        let clips = retimableSelection
        guard !clips.isEmpty, let fd = activeTimeline?.frameDuration else { return nil }
        return SpeedDialogModel(clips: clips, frameDuration: fd)
    }

    /// Applies a Speed/Duration result to the selected retimable clips (linked partners change with them) as ONE undo step.
    @discardableResult
    public func applySpeed(_ change: SpeedChange) -> Bool {
        let ids = retimableSelection.map(\.id)
        guard !ids.isEmpty else { return false }
        return attempt("Speed/Duration") { try $0.apply(change, to: ids) }
    }

    /// Reverse Speed on or off for the selected clips (no dialog).
    @discardableResult
    public func setReversed(_ reversed: Bool) -> Bool {
        let ids = retimableSelection.map(\.id)
        guard !ids.isEmpty else { return false }
        return attempt("Reverse Speed") { try $0.apply(SpeedChange(reversed: reversed), to: ids) }
    }
}
