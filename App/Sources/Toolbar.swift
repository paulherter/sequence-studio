import AppKit
import SSEditorUI

/// Unified toolbar, exactly DESIGN screen 1: Import on the left, Edit | Color centred, Export on the right.
/// Panels are shown and hidden from the Window menu; workspaces live there too; export progress is the ring in the status bar.
/// Real NSToolbar items (Liquid Glass groups on macOS 26); state is pushed in by `sync(store:)`.
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let importItem = NSToolbarItem.Identifier("ss.import")
    static let pageItem = NSToolbarItem.Identifier("ss.page")
    static let exportItem = NSToolbarItem.Identifier("ss.export")

    unowned let controller: AppController
    private var pageGroup: NSToolbarItemGroup?
    let toolbar = NSToolbar(identifier: "ss.main.v2")

    init(controller: AppController) {
        self.controller = controller
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.importItem, .flexibleSpace, Self.pageItem, .flexibleSpace, Self.exportItem]
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
