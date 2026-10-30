import Foundation
import SQCore

extension EffectControlsModel {
    /// Comma / Period (Shift: 10 frames): moves the selected keys (all properties) by `frames` whole frames, one undo
    /// step. Clamped inside the clip; a key never lands on a neighbor (it snaps a frame further, nothing merges).
    /// Returns the delta applied (`.zero` = nothing moved, no edit was sent). The keys stay selected.
    @discardableResult
    public func nudgeSelectedKeys(frames: Int) -> Time {
        guard frames != 0, !selection.isEmpty else { return .zero }
        beginGesture()
        let applied = moveSelection(by: Time.frames(Int64(frames), frameDuration: frameDuration))
        endKeyMove()
        return applied
    }
}
