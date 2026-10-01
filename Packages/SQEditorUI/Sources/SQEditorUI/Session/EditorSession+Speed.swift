import Foundation
import SQCore

extension EditorSession {
    /// Current duration of each sequence of the project (nested clips derive their length limit from it at edit time).
    func nestedDurationLookup() -> (Timeline.ID) -> Time? {
        let durations = Dictionary(uniqueKeysWithValues: project.timelines.map { ($0.id, $0.duration) })
        return { durations[$0] }
    }

    /// Selected clips that can be retimed (media clips and nested sequences; not titles or stills), in track order.
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
        let inner = nestedDurationLookup()
        return attempt("Speed/Duration") { $0.refreshNestedDurations(inner); try $0.apply(change, to: ids) }
    }

    /// Reverse Speed on or off for the selected clips (no dialog).
    @discardableResult
    public func setReversed(_ reversed: Bool) -> Bool {
        let ids = retimableSelection.map(\.id)
        guard !ids.isEmpty else { return false }
        let inner = nestedDurationLookup()
        return attempt("Reverse Speed") { $0.refreshNestedDurations(inner); try $0.apply(SpeedChange(reversed: reversed), to: ids) }
    }
}
