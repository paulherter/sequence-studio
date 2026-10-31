import Foundation
import SQCore
import SQEditorSession

/// The list's column header: a drag on the left edge of a column resizes it (Name takes what is left), a drag on a title
/// moves the column among the others (Name stays first), a plain click sorts by it and again flips the order. The Mac
/// outline view does the same (`NSTableView` column resize, reorder and sort descriptors); the layout is saved per user.
struct ColumnPress {
    enum Kind: Equatable { case resize(startWidth: CGFloat), move }
    var column: ProjectPanelModel.Column
    var kind: Kind
    var startX: CGFloat
    var dragged = false
}

extension ProjectListView {
    /// Pixels either side of a column's left edge that grab the resize handle.
    static let resizeGrab: CGFloat = 4
    static let columnSlop: CGFloat = 3
    static let maxColumnWidth: CGFloat = 600

    /// The column whose left edge is at `x` (a resize handle), never Name (its left edge is the panel's).
    func resizeColumn(at x: CGFloat) -> ColumnFrame? {
        columnFrames().dropFirst().first { abs($0.minX - x) <= Self.resizeGrab }
    }

    func beginColumnPress(at p: CGPoint) {
        let frames = columnFrames()
        if let f = resizeColumn(at: p.x) {
            columnPress = ColumnPress(column: f.column, kind: .resize(startWidth: f.maxX - f.minX), startX: p.x)
        } else if let f = frames.first(where: { p.x >= $0.minX && p.x < $0.maxX }) {
            columnPress = ColumnPress(column: f.column, kind: .move, startX: p.x)
        }
    }

    func dragColumn(toX x: CGFloat) {
        guard var press = columnPress else { return }
        guard press.dragged || abs(x - press.startX) >= Self.columnSlop else { return }
        press.dragged = true
        columnPress = press
        if case .resize(let start) = press.kind {
            // The edge moves with the pointer: dragging left widens the column.
            let w = min(max(start + (press.startX - x), press.column.minWidth), Self.maxColumnWidth)
            columns.setWidth(w, for: press.column)
        }
    }

    func endColumnPress(atX x: CGFloat) {
        guard let press = columnPress, let model else { columnPress = nil; return }
        columnPress = nil
        switch press.kind {
        case .resize:
            if press.dragged { columns.save(to: defaults) }
            else { sort(by: press.column, model) }
        case .move:
            guard press.dragged, press.column != .name else {
                if !press.dragged { sort(by: press.column, model) }
                return
            }
            let frames = columnFrames()
            let target = frames.firstIndex { x < $0.maxX } ?? frames.count - 1
            let visible = columns.visible
            // Dropping on a column that the narrow panel hides still lands among the visible ones.
            columns.move(press.column, toIndex: min(max(target, 1), visible.count - 1))
            columns.save(to: defaults)
        }
    }

    private func sort(by col: ProjectPanelModel.Column, _ model: ProjectPanelModel) {
        model.setSort(col, ascending: model.sortColumn == col ? !model.sortAscending : true)
    }
}
