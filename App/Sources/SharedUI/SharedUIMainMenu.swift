import AppKit
import SQDrawShell
import SQUIKit

/// The Mac system menu bar of the shared UI: the shell's menus (`ShellHost.menus()`, the same trees Windows draws in its
/// window) as NSMenus, rebuilt each time a menu opens so titles, enabled and checked states are current. Rows carry their
/// shortcut as a real key equivalent (read back from the row's text, `KeyBindingText.parseMac`), but keys reach the shell's
/// key map through `SharedUIView.performKeyEquivalent` first, so a shortcut runs once; a click runs the row's action.
/// Hide and Quit are the system's own (Cmd-H, Cmd-Q pass the view).
@MainActor
final class SharedUIMainMenu: NSObject, NSMenuDelegate {
    private let shell: ShellHost
    private let quitTarget: SharedUIController
    let main = NSMenu()

    init(shell: ShellHost, quitTarget: SharedUIController) {
        self.shell = shell
        self.quitTarget = quitTarget
        super.init()
        rebuild()
    }

    /// Top-level titles once (they never change); each submenu fills itself when it opens.
    private func rebuild() {
        main.removeAllItems()
        for (i, m) in shell.menus().enumerated() {
            let top = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: m.title)
            sub.delegate = self
            sub.identifier = NSUserInterfaceItemIdentifier("sq.menu.\(i)")
            top.submenu = sub
            main.addItem(top)
            fill(sub, with: m.items, isAppMenu: i == 0)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let id = menu.identifier?.rawValue, id.hasPrefix("sq.menu."), let i = Int(id.dropFirst(8)) else { return }
        let menus = shell.menus()
        guard menus.indices.contains(i) else { return }
        fill(menu, with: menus[i].items, isAppMenu: i == 0)
    }

    private func fill(_ menu: NSMenu, with items: [SQMenuItem], isAppMenu: Bool) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in items { menu.addItem(Self.nsItem(item, isAppMenu: isAppMenu, quitTarget: quitTarget)) }
    }

    static func nsItem(_ item: SQMenuItem, isAppMenu: Bool = false, quitTarget: AnyObject? = nil) -> NSMenuItem {
        switch item.kind {
        case .separator: return .separator()
        case .header, .caption:
            let h = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            return h
        case .action: break
        }
        // The system's Hide and Quit (Quit still asks to save through `applicationShouldTerminate`).
        if isAppMenu, item.title.hasPrefix("Hide ") {
            return NSMenuItem(title: item.title, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        }
        if isAppMenu, item.title == SQL10n.string("Hide Others") {
            let o = NSMenuItem(title: item.title, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            o.keyEquivalentModifierMask = [.command, .option]
            return o
        }
        if isAppMenu, item.title == SQL10n.string("Show All") {
            return NSMenuItem(title: item.title, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        }
        if isAppMenu, item.title.hasPrefix("Quit ") {
            let q = NSMenuItem(title: item.title, action: #selector(SharedUIController.quitFromMenu(_:)), keyEquivalent: "q")
            q.target = quitTarget
            return q
        }
        let n = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        if let sub = item.submenu {
            let m = NSMenu(title: item.title)
            m.autoenablesItems = false
            for s in sub { m.addItem(nsItem(s, quitTarget: quitTarget)) }
            n.submenu = m
            n.isEnabled = item.isEnabled && !sub.isEmpty
            return n
        }
        if let action = item.action {
            let box = ActionBox(action)
            n.target = box
            n.action = #selector(ActionBox.run(_:))
            n.representedObject = box          // the item keeps its target alive
        }
        n.isEnabled = item.isEnabled && item.action != nil
        n.state = item.isChecked ? .on : .off
        n.toolTip = item.help
        if let b = KeyBindingText.parseMac(item.shortcut), let key = KeyMapping.keyEquivalent(for: b.key) {
            n.keyEquivalent = key
            n.keyEquivalentModifierMask = KeyMapping.modifierMask(b.modifiers)
        }
        return n
    }
}

/// An NSMenuItem target running a shared menu row's closure.
@MainActor
final class ActionBox: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}
