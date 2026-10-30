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
        let only = selection
        return attempt("Speed", coalescing: speedGestureKey) { t in
            t.refreshNestedDurations(inner)
            // Fast Cut: main clips ripple V1 whatever the Ripple setting says; attached clips move with their host.
            if t.isFastCut { try t.magneticApply(change, to: ids) } else { try t.editing(only: only) { try $0.apply(change, to: ids) } }
        }
    }

    /// Speed field gesture: the changes between begin and end are one undo step.
    public func beginSpeedGesture() { gestureCounter += 1; speedGestureKey = "speed:\(gestureCounter)" }
    public func endSpeedGesture() { speedGestureKey = nil }

    /// Clip > Reverse Clip: the selected retimable clips play backwards (or forwards again). The first clip decides the
    /// direction, so a mixed selection ends uniform. Constant and animated speed, linked partners and Fast Cut ripple go
    /// through `setReversed` (one undo step).
    @discardableResult
    public func toggleReverseSelection() -> Bool {
        guard let first = retimableSelection.first else { return false }
        return setReversed(!first.reversed)
    }

    /// Reverse Clip is available for this selection.
    public var canReverseSelection: Bool { canSetSpeed }

    /// Reverse Speed on or off for the selected clips (no dialog).
    @discardableResult
    public func setReversed(_ reversed: Bool) -> Bool {
        let ids = retimableSelection.map(\.id)
        guard !ids.isEmpty else { return false }
        let inner = nestedDurationLookup()
        let only = selection
        return attempt("Reverse Speed") { t in
            t.refreshNestedDurations(inner)
            let change = SpeedChange(reversed: reversed)
            if t.isFastCut { try t.magneticApply(change, to: ids) } else { try t.editing(only: only) { try $0.apply(change, to: ids) } }
        }
    }
}
