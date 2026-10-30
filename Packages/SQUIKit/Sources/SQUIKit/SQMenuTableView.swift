import AppKit

/// Table whose right-click (and ctrl-click) opens SQ rows built by its panel for the clicked row; no NSMenu involved.
/// `sqItems` gets the row under the pointer (-1 on empty space). A click on an unselected row selects it first.
@MainActor
open class SQMenuTableView: NSTableView {
    public var sqItems: ((Int) -> [SQMenuItem])?

    open override func menu(for event: NSEvent) -> NSMenu? {
        // The global right-click routing and the table's own `rightMouseDown` both ask: build and show once.
        guard let sqItems, !SQMenuController.shared.isOpen else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        let items = sqItems(row)
        if !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
}
