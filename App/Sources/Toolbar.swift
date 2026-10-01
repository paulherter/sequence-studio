import AppKit
import SSEditorUI

/// Compact unified toolbar (Premiere's slim header, FEEDBACK-4 item 25): Import on the left, Edit | Color centred,
/// workspace name and Export on the right. Icons only, no labels under them, so the bar is one slim row.
/// Panels are shown and hidden from the Window menu; workspaces live there too; export progress is the ring in the status bar.
/// Real NSToolbar items (Liquid Glass groups on macOS 26); state is pushed in by `sync(store:)`.
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let importItem = NSToolbarItem.Identifier("ss.import")
    static let pageItem = NSToolbarItem.Identifier("ss.page")
    static let exportItem = NSToolbarItem.Identifier("ss.export")
    static let workspaceItem = NSToolbarItem.Identifier("ss.workspace")

    unowned let controller: AppController
    private var pageGroup: NSToolbarItemGroup?
    let toolbar = NSToolbar(identifier: "ss.main.v3")
    /// Menu of the workspace item; the controller fills it with the workspace list.
    let workspaceMenu = NSMenu(title: "Workspace")
    private var workspaceButton: NSMenuToolbarItem?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItem, .flexibleSpace, Self.pageItem, .flexibleSpace, Self.workspaceItem, Self.exportItem]
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
        case Self.workspaceItem:
            let m = NSMenuToolbarItem(itemIdentifier: id)
            m.label = "Workspace"
            m.toolTip = "Workspace"
            m.menu = workspaceMenu
            m.showsIndicator = true
            m.title = controller.store.current.name
            workspaceButton = m
            return m
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

    /// Pushes the current page into the Edit | Color switch.
    func sync(store: WorkspaceStore) {
        pageGroup?.selectedIndex = store.page == .color ? 1 : 0
        workspaceButton?.title = store.current.name
    }
}
