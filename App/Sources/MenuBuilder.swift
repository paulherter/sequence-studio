import AppKit
import SSEditorUI

/// Builds the main menu from `EditorMenus` (structure) and `CommandMap` (key equivalents).
/// Every binding is a real key equivalent so macOS shows and right-aligns it. Plain keys (J K L, I O, Space, arrows...)
/// are still handled by `KeyRouter` from key events (it needs key-up for J/K/L); the local key monitor consumes those
/// events before the menu sees them. When the monitor lets one through (typing in a text field, list arrows) the
/// item is disabled by `AppController.validateMenuItem`, so it cannot fire twice or steal typing.
@MainActor
enum MenuBuilder {
    static func build(target: AppController, map: CommandMap) -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem(target: target))
        for spec in EditorMenus.all {
            let menu = NSMenu(title: spec.title)
            menu.autoenablesItems = true
            for item in spec.items {
                switch item {
                case .separator: menu.addItem(.separator())
                case .command(let c): menu.addItem(menuItem(for: c, target: target, map: map))
                }
            }
            if spec.title == "File" { extendFile(menu, target: target) }
            if spec.title == "Window" {
                windowMenu(menu, target: target, map: map)
                NSApp.windowsMenu = menu
            }
            let host = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            host.submenu = menu
            main.addItem(host)
        }
        return main
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
    }

    private static func appMenuItem(target: AppController) -> NSMenuItem {
        let menu = NSMenu(title: "Sequence Studio")
        menu.addItem(NSMenuItem(title: "About Sequence Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppController.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        menu.addItem(settings)
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

    private static func extendFile(_ menu: NSMenu, target: AppController) {
        let open = NSMenuItem(title: "Open Project…", action: #selector(AppController.openProject(_:)), keyEquivalent: "o")
        open.target = target
        menu.insertItem(open, at: 0)
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(AppController.saveProjectAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = target
        if let i = menu.items.firstIndex(where: { ($0.representedObject as? EditorCommand) == .save }) {
            menu.insertItem(saveAs, at: i + 1)
        } else {
            menu.addItem(saveAs)
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
