import AppKit
import SQCore
import SQEditorUI

extension EditorPanels {
    /// Move into Sync / Slip into Sync items (plus a separator) for the top of the clip menu when the clip under the pointer is out of sync.
    func syncMenuItems(at p: CGPoint) -> [SQMenuItem] {
        let tv = timelineView
        guard case .clip(let id, _) = tv.geometry.hitTest(p, in: tv.timeline), tv.timeline.syncOffsets()[id] != nil else { return [] }
        return [SQMenuItem(title: "Move into Sync") { [weak self] in self?.session.moveIntoSync(id) },
                SQMenuItem(title: "Slip into Sync") { [weak self] in self?.session.slipIntoSync(id) },
                .separator]
    }
}
