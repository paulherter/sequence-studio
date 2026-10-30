import AppKit
import SQCore
import SQEditorUI

/// Item lanes of an opened Graphic clip in the timeline: a move or trim of an item's bar is one undo step; the lane
/// selection and the item selection of the monitor and Controls are the same selection.
extension EditorPanels {
    func wireItemLanes() {
        let gesture = TimelineLineGesture(name: "Item Range", replace: { [weak self] clip, name, continues in
            self?.session.replaceClip(clip, name: name, continuesGesture: continues)
        }, end: { [weak self] in self?.session.endGesture() })
        timelineView.onItemLaneEdit = { clip, phase in gesture.handle(clip, phase) }
        timelineView.onItemLaneReorder = { [weak self] clip, ids, index in
            self?.session.editGraphics(clip, name: "Reorder Layer") { $0.move(ids, toIndex: index) }
        }
        timelineView.onItemLaneMoveOut = { [weak self] clip, ids, dest, copy in
            guard let self, let landed = session.moveGraphicsLayers(ids, from: clip, to: dest, copy: copy) else { return }
            session.select(clips: [landed.clip], captions: [])
            graphics.sync()
            graphics.select(Set(landed.layers))
        }
        timelineView.onItemLanesMakeGraphic = { [weak self] id in
            guard let self else { return }
            session.select(clips: [id], captions: [])
            session.makeGraphic()
        }
        timelineView.onItemLaneSelect = { [weak self] clip, items in
            guard let self else { return }
            if session.singleSelectedClip?.id != clip { session.select(clips: [clip], captions: []) }
            graphics.sync()
            graphics.select(items)
        }
    }

    /// The item selection changed in the monitor, the Graphics panel or Controls: the lanes show it.
    func syncItemLaneSelection() {
        timelineView.setItemSelection(clip: graphics.clip?.id, items: graphics.selectedLayers)
    }
}
