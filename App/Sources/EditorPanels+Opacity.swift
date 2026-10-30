import AppKit
import SQCore
import SQEditorUI

/// Opacity rubber band on video clips: every drag (or Cmd-click that adds a key) is one undo step.
extension EditorPanels {
    func wireOpacityLine() {
        let gesture = TimelineLineGesture(name: "Opacity", replace: { [weak self] clip, name, continues in
            self?.session.replaceClip(clip, name: name, continuesGesture: continues)
        }, end: { [weak self] in self?.session.endGesture() })
        timelineView.onOpacityEdit = { clip, phase in gesture.handle(clip, phase) }
    }
}
