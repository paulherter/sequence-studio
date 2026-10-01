import AppKit
import SQCore
import SQEditorUI

/// Opacity rubber band on video clips: every drag (or Cmd-click that adds a key) is one undo step.
extension EditorPanels {
    func wireOpacityLine() {
        var first = true
        timelineView.onOpacityEdit = { [weak self] clip, phase in
            guard let self else { return }
            switch phase {
            case .began: first = true
            case .changed:
                session.replaceClip(clip, name: "Opacity", continuesGesture: !first)
                first = false
            case .ended: break
            }
        }
    }
}
