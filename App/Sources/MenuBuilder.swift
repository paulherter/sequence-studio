import AppKit
import SQCore
import SQEditorSession
import SQEditorUI

/// Builds the main menu from `EditorMenus` (structure) and `CommandMap` (key equivalents).
/// Every binding is a real key equivalent so macOS shows and right-aligns it. Plain keys (J K L, I O, Space, arrows...)
/// are still handled by `KeyRouter` from key events (it needs key-up for J/K/L); the local key monitor consumes those
/// events before the menu sees them. When the monitor lets one through (typing in a text field, list arrows) the
/// item is disabled by `AppController.validateMenuItem`, so it cannot fire twice or steal typing.
/// Commands that are not wired yet are left out (no dead items); the text editing commands stay (a field handles them).
@MainActor
enum MenuBuilder {
    static func build(target: AppController, map: CommandMap) -> NSMenu {
        // The board's Edit menu ends with Find…: keep macOS from appending Start Dictation… and Emoji & Symbols.
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        // Same for AutoFill (heuristic controller) and Writing Tools (no documented key: the SQ bridge also drops both items).
        UserDefaults.standard.set(false, forKey: "NSAutoFillHeuristicControllerEnabled")
        UserDefaults.standard.set(true, forKey: "NSDisabledWritingToolsMenuItem")
        let main = NSMenu()
        main.addItem(appMenuItem(target: target, map: map))
        for spec in EditorMenus.visible {
            let menu = NSMenu(title: SQL10n.string(spec.title))
            menu.autoenablesItems = true
            addItems(spec.items, to: menu, target: target, map: map)
            if spec.title == "File" { extendFile(menu, target: target) }
            if spec.title == "Sequence" { extendSequence(menu, target: target) }
            if spec.title == "Clip" { extendClip(menu, target: target) }
            if spec.title == "Window" {
                windowMenu(menu, target: target, map: map)
                NSApp.windowsMenu = menu
            }
            tidy(menu)
            let host = NSMenuItem(title: SQL10n.string(spec.title), action: nil, keyEquivalent: "")
            host.submenu = menu
            main.addItem(host)
        }
        // An empty Help menu still gets macOS's menu search field, which finds every item of every menu.
        let help = NSMenu(title: SQL10n.string("Help"))
        let helpHost = NSMenuItem(title: SQL10n.string("Help"), action: nil, keyEquivalent: "")
        // Support group first, then a separator (Discord is left out while its URL is nil).
        var group: [(String, Selector, String, Bool)] = []
        for e in SupportLinks.entries {
            let sel: Selector
            switch e {
            case .support: sel = #selector(AppController.openSupportPage(_:))
            case .discord: sel = #selector(AppController.openDiscord(_:))
            case .github: sel = #selector(AppController.openGitHub(_:))
            }
            group.append((e.helpTitle, sel, e.symbol, e == .support))
        }
        for (title, sel, symbol, tinted) in group {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = target
            if let icon = SQIcon(rawValue: symbol) {
                item.image = tinted ? icon.image(size: 14, color: Theme.Colors.support) : icon.image(size: 14)
            }
            help.addItem(item)
        }
        help.addItem(.separator())
        help.addItem(menuItem(for: .keyboardShortcuts, target: target, map: map))
        for (title, sel) in [("Send Feedback…", #selector(AppController.sendFeedback(_:))),
                             ("Reveal Logs and Reports", #selector(AppController.revealLogs(_:))),
                             ("Welcome Tour…", #selector(AppController.showWelcomeItem(_:))),
                             ("Check for Updates…", #selector(AppController.checkForUpdatesItem(_:)))] {
            let item = NSMenuItem(title: SQL10n.string(title), action: sel, keyEquivalent: "")
            item.target = target
            help.addItem(item)
        }
        helpHost.submenu = help
        main.addItem(helpHost)
        NSApp.helpMenu = help
        return main
    }

    /// Wired and worth a menu item.
    static func isVisible(_ c: EditorCommand) -> Bool {
        if EditorMenus.alwaysShown.contains(c) { return true }
        return CommandRouting.isSupported(c)
    }

    private static func addItems(_ items: [MenuSpec.Item], to menu: NSMenu, target: AppController, map: CommandMap) {
        for item in items {
            switch item {
            case .separator: menu.addItem(.separator())
            case .command(let c):
                if isVisible(c) { menu.addItem(menuItem(for: c, target: target, map: map)) }
            case .submenu(let title, let sub):
                let m = NSMenu(title: SQL10n.string(title))
                m.autoenablesItems = true
                addItems(sub, to: m, target: target, map: map)
                tidy(m)
                guard !m.items.isEmpty else { continue }
                let host = NSMenuItem(title: SQL10n.string(title), action: nil, keyEquivalent: "")
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
        let ws = NSMenuItem(title: SQL10n.string("Workspaces"), action: nil, keyEquivalent: "")
        ws.submenu = target.mainWorkspaceSubmenu
        head.append(ws)
        head.append(.separator())
        func panelItem(_ p: PanelID) -> NSMenuItem {
            let item = NSMenuItem(title: EditorCommand.localizedPanelTitle(p), action: #selector(AppController.windowPanelItem(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = p
            if let b = map.binding(for: .focusPanel(p)), let k = KeyMapping.keyEquivalent(for: b.key) {
                item.keyEquivalent = k
                item.keyEquivalentModifierMask = KeyMapping.modifierMask(b.modifiers)
            }
            return item
        }
        for p in EditorMenus.primaryWindowPanels {
            head.append(panelItem(p))
            if p == .timeline { head.append(toolStripItem()) }
        }
        let more = NSMenu(title: SQL10n.string("More Panels"))
        EditorMenus.secondaryWindowPanels.forEach { more.addItem(panelItem($0)) }
        head.append(submenuHost("More Panels", more))
        head.append(.separator())
        for (i, item) in head.enumerated() { menu.insertItem(item, at: i) }
        // macOS window commands (no Cmd+M: that is Export), kept in one submenu so the menu stays short.
        menu.addItem(.separator())
        let windows = NSMenu(title: SQL10n.string("App Windows"))
        windows.addItem(NSMenuItem(title: SQL10n.string("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: ""))
        windows.addItem(NSMenuItem(title: SQL10n.string("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windows.addItem(.separator())
        let history = NSMenuItem(title: SQL10n.string("History"), action: #selector(AppController.showHistory(_:)), keyEquivalent: "")
        history.target = target
        windows.addItem(history)
        let start = NSMenuItem(title: SQL10n.string("Start Window"), action: #selector(AppController.showStartWindowItem(_:)), keyEquivalent: "")
        start.target = target
        windows.addItem(start)
        windows.addItem(.separator())
        windows.addItem(NSMenuItem(title: SQL10n.string("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        menu.addItem(submenuHost("App Windows", windows))
    }

    private static func submenuHost(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let host = NSMenuItem(title: SQL10n.string(title), action: nil, keyEquivalent: "")
        host.submenu = sub
        return host
    }

    /// The submenu the spec declares under `title` (nil when every item in it is hidden).
    private static func submenu(_ title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.submenu != nil && $0.title == SQL10n.string(title) }?.submenu
    }

    /// Window > Tools: shows or hides the tool strip (check = visible). Own target so it needs nothing from AppController.
    private static let toolStripTarget = ToolStripMenuTarget()
    private static func toolStripItem() -> NSMenuItem {
        let item = NSMenuItem(title: SQL10n.string("Tools"), action: #selector(ToolStripMenuTarget.toggle(_:)), keyEquivalent: "")
        item.target = toolStripTarget
        item.state = ToolStripPrefs.visible ? .on : .off
        return item
    }

    private static func appMenuItem(target: AppController, map: CommandMap) -> NSMenuItem {
        let menu = NSMenu(title: SQL10n.string("Sequence Studio"))
        let about = NSMenuItem(title: SQL10n.string("About Sequence Studio"), action: #selector(AppController.showAbout(_:)), keyEquivalent: "")
        about.target = target
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(menuItem(for: .preferences, target: target, map: map))
        menu.addItem(menuItem(for: .keyboardShortcuts, target: target, map: map))
        menu.addItem(.separator())
        let hide = NSMenuItem(title: SQL10n.string("Hide Sequence Studio"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(hide)
        let others = NSMenuItem(title: SQL10n.string("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(others)
        menu.addItem(NSMenuItem(title: SQL10n.string("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: SQL10n.string("Quit Sequence Studio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let item = NSMenuItem(title: SQL10n.string("Sequence Studio"), action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Open Recent goes right after Open Project; the stateful project items join File > Project.
    private static func extendFile(_ menu: NSMenu, target: AppController) {
        let recent = NSMenuItem(title: SQL10n.string("Open Recent"), action: nil, keyEquivalent: "")
        target.recentMenu.delegate = target
        recent.submenu = target.recentMenu
        if let i = menu.items.firstIndex(where: { ($0.representedObject as? EditorCommand) == .openProject }) {
            menu.insertItem(recent, at: i + 1)
        } else {
            menu.addItem(recent)
        }
        let project = submenu(EditorMenus.projectSubmenuTitle, in: menu) ?? {
            let m = NSMenu(title: SQL10n.string(EditorMenus.projectSubmenuTitle))
            menu.addItem(submenuHost(EditorMenus.projectSubmenuTitle, m))
            return m
        }()
        addShellItems(project, target: target)
    }

    /// Autosave Versions, Reconnect Media and Style Kit (File > Project); thin: the logic is in `EditorSession+Shell`.
    private static func addShellItems(_ menu: NSMenu, target: AppController) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let versions = NSMenuItem(title: SQL10n.string("Autosave Versions"), action: nil, keyEquivalent: "")
        target.autosaveMenu.delegate = target
        versions.submenu = target.autosaveMenu
        // Control-Command-S: Command-S is Save, Shift is Save As, Option is Save a Copy; no other command uses Control+S+Command.
        let checkpoint = NSMenuItem(title: SQL10n.string("Save Checkpoint…"), action: #selector(AppController.saveCheckpointItem(_:)), keyEquivalent: "s")
        checkpoint.keyEquivalentModifierMask = [.control, .command]
        checkpoint.target = target
        let relink = NSMenuItem(title: SQL10n.string("Reconnect Media…"), action: #selector(AppController.relinkMediaItem(_:)), keyEquivalent: "")
        relink.target = target
        // Style Kit (brand fonts, colors, caption style) lives with the project file, not in Window (A9).
        let kit = NSMenu(title: SQL10n.string("Style Kit"))
        for (title, sel) in [("Import Style Kit…", #selector(AppController.importStyleKit(_:))),
                             ("Export Style Kit…", #selector(AppController.exportStyleKit(_:))),
                             ("Use Brand Caption Style", #selector(AppController.useKitCaptionStyle(_:)))] {
            let item = NSMenuItem(title: SQL10n.string(title), action: sel, keyEquivalent: "")
            item.target = target
            kit.addItem(item)
        }
        let checklist = NSMenuItem(title: SQL10n.string("Import Checklist…"), action: #selector(AppController.showImportChecklist(_:)), keyEquivalent: "")
        checklist.target = target
        for item in [checkpoint, versions, relink, checklist, submenuHost("Style Kit", kit)] { menu.addItem(item) }
    }

    /// Clip > Replace and Fit > Pixel Aspect (source setting of the selected Project items; same call as their context menu).
    private static func extendClip(_ menu: NSMenu, target: AppController) {
        target.pixelAspectMenu.owner = target
        let sub = NSMenu(title: SQL10n.string("Pixel Aspect"))
        sub.autoenablesItems = true
        target.pixelAspectMenu.makeItems().forEach(sub.addItem)
        let host = submenuHost("Pixel Aspect", sub)
        (submenu("Replace and Fit", in: menu) ?? menu).addItem(host)
    }

    /// Sequence > Format (change, duplicate, templates, input color) after Sequence Settings, and the New layers.
    private static func extendSequence(_ menu: NSMenu, target: AppController) {
        func item(_ title: String, _ sel: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: SQL10n.string(title), action: sel, keyEquivalent: "")
            i.target = target
            return i
        }
        let format = NSMenu(title: SQL10n.string("Format"))
        format.addItem(item("Change Format…", #selector(AppController.changeFormatItem(_:))))
        format.addItem(item("Duplicate as Format…", #selector(AppController.duplicateAsFormatItem(_:))))
        format.addItem(.separator())
        // Templates and the project input color belong to the sequence, not to Window (A9, E11).
        format.addItem(item("New Sequence from Template…", #selector(AppController.newSequenceFromTemplate(_:))))
        format.addItem(item("Save Sequence as Template…", #selector(AppController.saveSequenceAsTemplate(_:))))
        format.addItem(AppController.projectInputColorMenu(target: target))
        let at = menu.items.firstIndex(where: { ($0.representedObject as? EditorCommand) == .sequenceSettings }).map { $0 + 1 } ?? 0
        menu.insertItem(submenuHost("Format", format), at: min(at, menu.items.count))
        // New Shape (W5.2), Graphics Clip (GFX design layer), Adjustment Layer (W9.6), Color Matte: layers at the playhead.
        let layer = NSMenu(title: SQL10n.string("Layer"))
        let shapes = NSMenu(title: SQL10n.string("New Shape"))
        for k in ShapeKind.allCases {
            let i = item(k.title, #selector(AppController.newShapeItem(_:)))
            i.representedObject = k.rawValue
            shapes.addItem(i)
        }
        layer.addItem(submenuHost("New Shape", shapes))
        layer.addItem(item("New Graphics Clip", #selector(AppController.newGraphicsClipItem(_:))))
        layer.addItem(item("New Adjustment Layer", #selector(AppController.newAdjustmentLayerItem(_:))))
        layer.addItem(item("New Color Matte…", #selector(AppController.newColorMatteItem(_:))))
        (submenu("New", in: menu) ?? menu).addItem(submenuHost("Layer", layer))
    }

    static func menuItem(for c: EditorCommand, target: AppController, map: CommandMap) -> NSMenuItem {
        let item = NSMenuItem(title: SQL10n.string(c.title), action: #selector(AppController.menuCommand(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = c
        item.sqHelp = c.menuHelp
        guard let b = map.binding(for: c) else { return item }
        if let k = KeyMapping.keyEquivalent(for: b.key) {
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = KeyMapping.modifierMask(b.modifiers)   // [] for plain keys: macOS right-aligns them
        }
        // The key text SQ menus draw: AppKit rewrites keyEquivalent per keyboard layout ("/" became "ß"), the binding is layout independent.
        item.identifier = NSUserInterfaceItemIdentifier(SQMenuShortcut.hintPrefix + KeyMapping.hint(for: b))
        return item
    }
}


/// Target of Window > Tools: `ToolStripPrefs.visible.toggle()`, check mark follows the preference.
@MainActor
final class ToolStripMenuTarget: NSObject, NSMenuItemValidation {
    @objc func toggle(_ sender: NSMenuItem) { ToolStripPrefs.visible.toggle() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggle(_:)) { item.state = ToolStripPrefs.visible ? .on : .off }
        return true
    }
}
