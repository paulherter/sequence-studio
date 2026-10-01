import AppKit
import SSEditorUI

/// Builds the main menu from `EditorMenus` (structure) and `CommandMap` (key equivalents).
/// Every binding is a real key equivalent so macOS shows and right-aligns it. Plain keys (J K L, I O, Space, arrows...)
/// are still handled by `KeyRouter` from key events (it needs key-up for J/K/L); the local key monitor consumes those
/// events before the menu sees them. When the monitor lets one through (typing in a text field, list arrows) the
/// item is disabled by `AppController.validateMenuItem`, so it cannot fire twice or steal typing.
/// Commands that are not wired yet are left out (no dead items); the text editing commands stay (a field handles them).
@MainActor
enum MenuBuilder {
    static func build(target: AppController, map: CommandMap) -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem(target: target, map: map))
        for spec in EditorMenus.all {
            let menu = NSMenu(title: spec.title)
            menu.autoenablesItems = true
            addItems(spec.items, to: menu, target: target, map: map)
            if spec.title == "File" { extendFile(menu, target: target) }
            if spec.title == "Window" {
                windowMenu(menu, target: target, map: map)
                NSApp.windowsMenu = menu
            }
            tidy(menu)
            let host = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            host.submenu = menu
            main.addItem(host)
        }
        // An empty Help menu still gets macOS's menu search field, which finds every item of every menu.
        let help = NSMenu(title: "Help")
        let helpHost = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpHost.submenu = help
        main.addItem(helpHost)
        NSApp.helpMenu = help
        return main
    }

    /// Wired and worth a menu item.
    static func isVisible(_ c: EditorCommand) -> Bool {
        if EditorMenus.alwaysShown.contains(c) { return true }
        if c == .tool(.zoom) { return false }          // the Zoom tool is not implemented yet
        return AppController.isSupported(c)
    }

    private static func addItems(_ items: [MenuSpec.Item], to menu: NSMenu, target: AppController, map: CommandMap) {
        for item in items {
            switch item {
            case .separator: menu.addItem(.separator())
            case .command(let c):
                if isVisible(c) { menu.addItem(menuItem(for: c, target: target, map: map)) }
            case .submenu(let title, let sub):
                let m = NSMenu(title: title)
                m.autoenablesItems = true
                addItems(sub, to: m, target: target, map: map)
                tidy(m)
                guard !m.items.isEmpty else { continue }
                let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                host.submenu = m
                menu.addItem(host)
            }
        }
    }

    /// Drops leading, trailing and doubled separators left behind by hidden items.
    private static func tidy(_ menu: NSMenu) {
        var i = 0
        while i < menu.items.count {
            let it = menu.items[i]
            let prevIsSep = i == 0 || menu.items[i - 1].isSeparatorItem
            if it.isSeparatorItem && prevIsSep { menu.removeItem(at: i) } else { i += 1 }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// Premiere's Window menu: Workspaces submenu, one checkable item per panel (toggles it), then the plain commands.
    private static func windowMenu(_ menu: NSMenu, target: AppController, map: CommandMap) {
        var head: [NSMenuItem] = []
        let ws = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        ws.submenu = target.mainWorkspaceSubmenu
        head.append(ws)
        head.append(.separator())
        for p in EditorMenus.windowPanels {
            let item = NSMenuItem(title: EditorCommand.panelTitle(p), action: #selector(AppController.windowPanelItem(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = p
            if let b = map.binding(for: .focusPanel(p)), let k = KeyMapping.keyEquivalent(for: b.key) {
                item.keyEquivalent = k
                item.keyEquivalentModifierMask = KeyMapping.modifierMask(b.modifiers)
            }
            head.append(item)
        }
        head.append(.separator())
        for (i, item) in head.enumerated() { menu.insertItem(item, at: i) }
        // macOS window commands (no Cmd+M: that is Export).
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
    }

    private static func appMenuItem(target: AppController, map: CommandMap) -> NSMenuItem {
        let menu = NSMenu(title: "Sequence Studio")
        menu.addItem(NSMenuItem(title: "About Sequence Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(for: .preferences, target: target, map: map))
        menu.addItem(menuItem(for: .keyboardShortcuts, target: target, map: map))
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Sequence Studio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(hide)
        let others = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(others)
        menu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sequence Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let item = NSMenuItem(title: "Sequence Studio", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Open Recent goes right after Open Project.
    private static func extendFile(_ menu: NSMenu, target: AppController) {
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        target.recentMenu.delegate = target
        recent.submenu = target.recentMenu
        if let i = menu.items.firstIndex(where: { ($0.representedObject as? EditorCommand) == .openProject }) {
            menu.insertItem(recent, at: i + 1)
        } else {
            menu.addItem(recent)
        }
    }

    static func menuItem(for c: EditorCommand, target: AppController, map: CommandMap) -> NSMenuItem {
        let item = NSMenuItem(title: c.title, action: #selector(AppController.menuCommand(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = c
        guard let b = map.binding(for: c) else { return item }
        if let k = KeyMapping.keyEquivalent(for: b.key) {
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = KeyMapping.modifierMask(b.modifiers)   // [] for plain keys: macOS right-aligns them
        }
        return item
    }
}
