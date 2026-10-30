import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// The Fast Cut skimmer, translated from TimelineView+Skimmer.swift and `Skimmer` (main-actor bound there, so its
/// four-line rule is repeated here for the nonisolated panel); `onSkim` becomes `.skim`.
extension TimelinePanel {
    /// `updateSkimmer(pointer:)`: shows, moves or hides the line; tells the host once per frame change.
    mutating func updateSkimmer(pointer: CGPoint?) -> [TimelineAction] {
        guard timeline.isFastCut || skimmerTime != nil else { return [] }
        // `Skimmer.time`: Fast Cut, no gesture, no playback, not the razor, and the pointer over the track lanes.
        var t: Time?
        if timeline.isFastCut, !isDragging, !isPlaying, toolState.timelineTool != .razor, let p = pointer,
           p.x >= TimelineGeometry.contentOriginX, p.y >= TimelineGeometry.rulerHeight, p.y < size.height - Self.zoomBarHeight {
            t = geometry.time(atX: p.x)
        }
        guard t != skimmerTime else { return [] }
        skimmerTime = t
        return [.skim(t)]
    }

    /// The 2 pt line over the tracks in `Theme.Colors.skimmer`.
    func drawSkimmer(_ cv: inout Canvas) {
        guard let t = skimmerTime else { return }
        let ruler = TimelineGeometry.rulerHeight
        // `Skimmer.lineRect` / `Theme.PlayheadSkin.lineFrame`: 2 pt, centered on the frame's x, ruler to zoom bar.
        cv.fill(CGRect(x: geometry.x(for: t).rounded() - 1, y: ruler, width: 2, height: max(size.height - Self.zoomBarHeight - ruler, 0)),
                DrawColor(hex: 0xFFE566))                               // `Theme.Colors.skimmer`
    }
}
