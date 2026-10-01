import AppKit
import SQCore
import SQEditorUI

extension EditorPanels {
    /// Right-click on a caption segment in the timeline.
    func captionMenu() -> NSMenu {
        let items = TimelineContextMenu.captionItems(timeline: timelineView.timeline, captionSelection: timelineView.captionSelection,
                                                     playhead: session.playhead)
        return TimelineContextMenu.makeMenu(items: items) { [weak self] action in
            guard let self else { return }
            switch action {
            case .editCaption: if let id = session.captionSelection.first { timelineView.onEditCaptionText?(id) }
            case .splitCaption: session.splitCaption()
            case .mergeCaptions: session.mergeSelectedCaptions()
            case .delete: session.deleteSelectedCaptions()
            default: break
            }
        }
    }
}
