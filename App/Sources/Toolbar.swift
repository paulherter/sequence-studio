import AppKit
import SQEditorUI

/// Compact unified toolbar (Premiere's slim header, FEEDBACK-4 item 25): Import on the left, Edit | Color centred,
/// workspace name and Export on the right. Icons only, no labels under them, so the bar is one slim row.
/// Panels are shown and hidden from the Window menu; workspaces live there too; export progress is the ring in the status bar.
/// Real NSToolbar items (Liquid Glass groups on macOS 26); state is pushed in by `sync(store:)`.
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let importItem = NSToolbarItem.Identifier("sq.import")
    static let pageItem = NSToolbarItem.Identifier("sq.page")
    static let exportItem = NSToolbarItem.Identifier("sq.export")
    static let workspaceItem = NSToolbarItem.Identifier("sq.workspace")

    unowned let controller: AppController
    private var pageGroup: NSToolbarItemGroup?
    let toolbar = NSToolbar(identifier: "sq.main.v3")
    /// Menu of the workspace item; the controller fills it with the workspace list.
    let workspaceMenu = NSMenu(title: "Workspace")
    private var workspacePopup: NSPopUpButton?

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
            // A pull-down popup (first menu item = the button title, never listed) instead of NSMenuToolbarItem, which
            // dropped the first workspace from the list once the title changed. The menu is rebuilt by the controller.
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 24), pullsDown: true)
            pop.menu = workspaceMenu
            pop.bezelStyle = .texturedRounded
            pop.controlSize = .small
            pop.toolTip = "Workspace"
            pop.setAccessibilityLabel("Workspace")
            workspacePopup = pop
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Workspace"
            i.view = pop
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

    /// Pushes the current page into the Edit | Color switch.
    func sync(store: WorkspaceStore) {
        pageGroup?.selectedIndex = store.page == .color ? 1 : 0
    }
}
