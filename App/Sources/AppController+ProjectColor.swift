import AppKit
import SQCore
import SQEditorUI

/// W9.3 Window > Project Input Color Space: the camera / Log / HDR default for untagged footage of the project
/// (same setting as "Project input" in the color inspector, one undo step).
extension AppController {
    static func projectInputColorMenu(target: AppController) -> NSMenuItem {
        let menu = NSMenu(title: SQL10n.string("Project Input Color Space"))
        let none = NSMenuItem(title: SQL10n.string("None (as tagged)"), action: #selector(setProjectInputColorItem(_:)), keyEquivalent: "")
        none.target = target
        menu.addItem(none)
        menu.addItem(.separator())
        for id in ColorSpaceID.allCases {
            let item = NSMenuItem(title: id.displayName, action: #selector(setProjectInputColorItem(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = id
            menu.addItem(item)
        }
        let host = NSMenuItem(title: SQL10n.string("Project Input Color Space"), action: nil, keyEquivalent: "")
        host.submenu = menu
        return host
    }

    @objc func setProjectInputColorItem(_ sender: NSMenuItem) {
        session.setProjectInputColorSpace(sender.representedObject as? ColorSpaceID)
    }
}
