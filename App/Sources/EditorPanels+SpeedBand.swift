import AppKit
import SQCore
import SQEditorUI

/// Time Remapping speed band: every drag is one undo step; right-click on a key or transition offers its delete.
extension EditorPanels {
    func wireSpeedBand() {
        timelineView.onSpeedEdit = { [weak self] edit in self?.session.applySpeedEdit(edit) }
    }

    func speedKeyMenu(clip: Clip.ID, hit: SpeedBandKeyHit) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: hit.title, action: nil, keyEquivalent: "")
        item.target = SpeedKeyMenuTarget.shared
        item.action = #selector(SpeedKeyMenuTarget.fire(_:))
        item.representedObject = { [weak self] in self?.session.deleteSpeedKey(clip: clip, hit: hit); () } as () -> Void
        menu.addItem(item)
        return menu
    }
}

@MainActor
final class SpeedKeyMenuTarget: NSObject {
    static let shared = SpeedKeyMenuTarget()
    @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}
