import AppKit
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQUIKit

/// Scrolling a list under a resting pointer must leave exactly one row hovered (the one under the pointer). AppKit
/// sends no mouseExited for that, so every row view re-reads the pointer on each scroll step (`ScrollHoverSync`).
@MainActor
struct RowHoverScrollTests {
    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 60 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = LibraryRowView(); v.showsHover = true; return v
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
    }

    @Test func scrollingUnderAnIdlePointerHoversOnlyTheRowUnderIt() {
        let src = Source()
        let table = NSTableView()
        let col = NSTableColumn(identifier: .init("c")); col.width = 200
        table.addTableColumn(col); table.headerView = nil
        table.rowHeight = 20; table.intercellSpacing = .zero
        table.dataSource = src; table.delegate = src
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.documentView = table
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()

        let pointer = NSPoint(x: 100, y: 100)       // window coordinates, resting
        func hoveredRows() -> [Int] {
            (0..<table.numberOfRows).compactMap { r in
                guard let v = table.rowView(atRow: r, makeIfNecessary: false) as? LibraryRowView else { return nil }
                v.syncHover(atWindowPoint: pointer)
                return v.isHovered ? r : nil
            }
        }
        // Scroll in steps; after each step every row re-reads the pointer (the clip view's bounds notification does
        // this in the app). Rows that passed under the pointer must not stay lit.
        var seen = Set<Int>()
        for step in 0..<10 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 20))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
            let hovered = hoveredRows()
            #expect(hovered.count == 1)
            seen.formUnion(hovered)
        }
        #expect(seen.count == 10)
    }

    @Test func pointerOutsideTheRowHoversNothing() {
        let row = FlatSelectionRowView()
        row.showsHover = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        row.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        window.contentView?.addSubview(row)
        row.syncHover(atWindowPoint: NSPoint(x: 50, y: 10))
        #expect(row.isHovered)
        row.syncHover(atWindowPoint: NSPoint(x: 50, y: 60))
        #expect(!row.isHovered)
    }
}
