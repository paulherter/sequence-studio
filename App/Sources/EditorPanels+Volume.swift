import AppKit
import SQCore
import SQEditorUI

/// Volume rubber band: every drag is one undo step; right-click on a key offers Delete Keyframe.
extension EditorPanels {
    func wireVolumeLine() {
        var first = true
        timelineView.onVolumeEdit = { [weak self] clip, phase in
            guard let self else { return }
            switch phase {
            case .began: first = true
            case .changed:
                session.replaceClip(clip, name: "Volume", continuesGesture: !first)
                first = false
            case .ended: break
            }
        }
    }

    func volumeKeyMenu(clip: Clip.ID, key: UUID) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Delete Keyframe", action: nil, keyEquivalent: "")
        item.target = VolumeMenuTarget.shared
        item.action = #selector(VolumeMenuTarget.deleteKey(_:))
        item.representedObject = { [weak self] in
            guard let self, var c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else { return }
            c.removeVolumeKey(key)
            session.replaceClip(c, name: "Delete Keyframe", continuesGesture: false)
        } as () -> Void
        menu.addItem(item)
        return menu
    }
}

@MainActor
final class VolumeMenuTarget: NSObject {
    static let shared = VolumeMenuTarget()
    @objc func deleteKey(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}
