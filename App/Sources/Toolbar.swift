import AppKit
import SSEditorUI

/// Unified toolbar: Import | (space) Edit | Color | (space) panel toggles, workspace menu, tasks, Export.
/// Real NSToolbar items (Liquid Glass groups on macOS 26); state is pushed in by `sync(store:)`.
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let importItem = NSToolbarItem.Identifier("ss.import")
    static let pageItem = NSToolbarItem.Identifier("ss.page")
    static let panelsItem = NSToolbarItem.Identifier("ss.panels")
    static let workspaceItem = NSToolbarItem.Identifier("ss.workspace")
    static let tasksItem = NSToolbarItem.Identifier("ss.tasks")
    static let exportItem = NSToolbarItem.Identifier("ss.export")

    /// Panels with a toggle in the toolbar, in order.
    static let togglePanels: [PanelID] = [.project, .effectControls, .library, .effects]
    private static let toggleSymbols: [PanelID: String] = [
        .project: "folder", .effectControls: "slider.horizontal.3", .library: "books.vertical", .effects: "sparkles",
    ]

    unowned let controller: AppController
    private var pageGroup: NSToolbarItemGroup?
    private var panelGroup: NSToolbarItemGroup?
    private var workspaceToolbarItem: NSMenuToolbarItem?
    let toolbar = NSToolbar(identifier: "ss.main")

    init(controller: AppController) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItem, .flexibleSpace, Self.pageItem, .flexibleSpace,
         Self.panelsItem, Self.workspaceItem, Self.tasksItem, Self.exportItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.importItem:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Import"
            i.toolTip = "Import Media (⌘I)"
            i.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
            i.target = controller; i.action = #selector(AppController.toolbarImport(_:))
            return i
        case Self.pageItem:
            let g = NSToolbarItemGroup(itemIdentifier: id, titles: ["Edit", "Color"], selectionMode: .selectOne,
                                       labels: ["Edit", "Color"], target: controller,
                                       action: #selector(AppController.toolbarPage(_:)))
            g.label = "Workspace page"
            g.selectedIndex = 0
            pageGroup = g
            return g
        case Self.panelsItem:
            let images = Self.togglePanels.map {
                NSImage(systemSymbolName: Self.toggleSymbols[$0] ?? "square", accessibilityDescription: EditorCommand.panelTitle($0)) ?? NSImage()
            }
            let g = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectAny,
                                       labels: Self.togglePanels.map(EditorCommand.panelTitle), target: controller,
                                       action: #selector(AppController.toolbarPanels(_:)))
            g.label = "Panels"
            panelGroup = g
            return g
        case Self.workspaceItem:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Workspaces"
            i.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Workspaces")
            i.showsIndicator = true
            i.menu = controller.workspaceMenu
            workspaceToolbarItem = i
            return i
        case Self.tasksItem:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Tasks"
            i.toolTip = "Export queue"
            i.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Tasks")
            i.target = controller; i.action = #selector(AppController.toolbarTasks(_:))
            return i
        case Self.exportItem:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Export"
            i.toolTip = "Export… (⌘M)"
            i.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            i.style = .prominent
            i.target = controller; i.action = #selector(AppController.toolbarExport(_:))
            return i
        default:
            return nil
        }
    }

    /// Pushes the current workspace state into the page switch and the panel toggles.
    func sync(store: WorkspaceStore, workspace: Workspace) {
        pageGroup?.selectedIndex = store.page == .color ? 1 : 0
        for (i, p) in Self.togglePanels.enumerated() {
            panelGroup?.setSelected(workspace.isVisible(p), at: i)
            panelGroup?.subitems[i].isEnabled = workspace.allPanels.contains(p)
        }
        workspaceToolbarItem?.menu = controller.workspaceMenu
    }
}
