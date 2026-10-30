import AppKit
import SQCore
import SQEditorUI

/// Keys picked on the timeline: opacity / volume line keys go to the session (nudge keys move them), key-lane glyphs
/// select the keys in Effect Controls (the same nudge keys move those).
extension EditorPanels {
    func wireLineKeys() {
        timelineView.onLineKeyClick = { [weak self] ref, extend in
            guard let self else { return }
            guard let ref else { session.selectLineKeys([]); return }
            session.selectLineKeys(extend ? session.selectedLineKeys.symmetricDifference([ref]) : [ref])
        }
        timelineView.onKeyLaneClick = { [weak self] clip, time, extend in
            _ = self?.effectModel.selectKeyLaneKey(clip: clip, at: time, extend: extend)
        }
    }

    /// The timeline draws the session's selected line keys filled.
    func mirrorLineKeys() {
        timelineView.selectedLineKeys = Set(session.selectedLineKeys.map(\.key))
    }
}
