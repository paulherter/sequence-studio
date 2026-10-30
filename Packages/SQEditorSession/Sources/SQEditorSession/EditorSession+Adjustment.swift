import Foundation
import SQCore

/// Sequence > New Adjustment Layer (W9.6): an Adjustment Layer clip whose effects apply to every track below it.
extension EditorSession {
    /// Places an Adjustment Layer at `time` (default: playhead) on `track`, else on the topmost unlocked video track that is
    /// free there. One undo step; selects the new clip so effects can be dropped on it. A refusal goes to `lastError`.
    @discardableResult
    public func addAdjustmentLayer(at time: Time? = nil, track: Track.ID? = nil, duration: Time = Time(5, 1)) -> Clip.ID? {
        guard let t = activeTimeline, let tl = activeTimelineID else { setError("Open a sequence first."); return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        let duration = max(duration.snapped(to: t.frameDuration), t.frameDuration)
        guard let chosen = Self.generatorTrack(in: t, for: TimeRange(start: start, duration: duration), preferred: track) else {
            setError("There is no video track for the adjustment layer."); return nil
        }
        var newID: Clip.ID?
        do {
            try perform("Add Adjustment Layer") { p in
                newID = try p.addAdjustmentClip(in: tl, at: start, track: chosen, duration: duration)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }
}
