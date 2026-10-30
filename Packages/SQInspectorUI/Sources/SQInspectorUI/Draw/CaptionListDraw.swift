import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit

/// The read-only caption list on the shared toolkit: `CaptionReadListView` translated. One row per caption (start time
/// left, text right), the row at the playhead and the selected captions marked, a click seeks. Only the visible rows
/// are drawn, and the list scrolls by itself inside the height its section gives it.
/// Coordinates: points, y down, (0, 0) = the list's top-left.
struct CaptionListDraw {
    private(set) var model = CaptionListModel()
    private(set) var current: Int?
    private(set) var selectedIDs: Set<CaptionItem.ID> = []
    var hovered: Int?
    private(set) var scrollY: CGFloat = 0
    /// Left edge of the time column and the inset of the text's right edge: the Controls grid (label column, trailing).
    var insets: (left: CGFloat, right: CGFloat) = (ControlsGrid.labelX, ControlsGrid.trailing)

    enum Mark: Equatable { case none, playhead, selected }

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit), checked by
    // ControlsMetricsPortableTests; upgrade when SQUIKit's tokens move into a portable file.
    /// `Theme.Row.list`.
    static let rowHeight: CGFloat = 24
    /// `Theme.Inspector.nameWidth`: the time column.
    static let nameWidth: CGFloat = 88
    /// Time column plus the inner gap (`Theme.Inspector.nameWidth + Theme.Inspector.columnGap`).
    static let timeWidth: CGFloat = nameWidth + 6

    var contentHeight: CGFloat { CGFloat(model.rows.count) * Self.rowHeight }

    /// True when the rows changed.
    mutating func setModel(_ m: CaptionListModel) -> Bool {
        guard m != model else { return false }
        model = m
        if hovered.map({ !m.rows.indices.contains($0) }) == true { hovered = nil }
        return true
    }
    mutating func setPlayhead(_ t: Time) { current = model.currentRow(at: t) }
    mutating func setSelected(_ ids: Set<CaptionItem.ID>) { selectedIDs = ids }

    /// Selected (the stronger mark) wins over the playhead row.
    func mark(row i: Int) -> Mark {
        guard model.rows.indices.contains(i) else { return .none }
        if selectedIDs.contains(model.rows[i].id) { return .selected }
        return i == current ? .playhead : .none
    }

    /// The row under `p` (list coordinates, visible part `height` tall).
    func row(at p: CGPoint, height: CGFloat) -> Int? {
        guard p.y >= 0, p.y < height else { return nil }
        let i = Int(floor((p.y + scrollY) / Self.rowHeight))
        return model.rows.indices.contains(i) ? i : nil
    }

    /// Row `i` in list coordinates (scrolled).
    func rect(row i: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: CGFloat(i) * Self.rowHeight - scrollY, width: width, height: Self.rowHeight)
    }

    /// Frames of the time and the text of row `i`, scrolled (layout tests and drawing).
    func columns(row i: Int, width: CGFloat) -> (time: CGRect, text: CGRect) {
        let r = rect(row: i, width: width), textX = insets.left + Self.timeWidth
        return (CGRect(x: insets.left, y: r.minY, width: Self.nameWidth, height: r.height),
                CGRect(x: textX, y: r.minY, width: max(width - textX - insets.right, 0), height: r.height))
    }

    /// The wheel: false when the list cannot move further (the panel scrolls instead).
    mutating func scroll(dy: CGFloat, height: CGFloat) -> Bool {
        let y = min(max(scrollY - dy, 0), max(contentHeight - height, 0))
        guard y != scrollY else { return false }
        scrollY = y
        return true
    }

    /// Keeps the scroll inside the content after the rows or the height changed.
    mutating func clampScroll(height: CGFloat) { scrollY = min(scrollY, max(contentHeight - height, 0)) }

    func draw(_ c: inout Canvas, width: CGFloat, height: CGFloat, theme t: DrawTheme) {
        guard !model.rows.isEmpty, height > 0 else { return }
        let h = Self.rowHeight, fs = CGFloat(DrawTheme.TypeSize.body)
        let first = max(Int(floor(scrollY / h)), 0), last = min(Int(ceil((scrollY + height) / h)), model.rows.count)
        guard first < last else { return }
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        for i in first..<last {
            let r = rect(row: i, width: width), row = model.rows[i], m = mark(row: i)
            switch m {
            case .selected: c.fill(r, t.accentTint)
            case .playhead: c.fill(r, t.selection)
            case .none: if i == hovered { c.fill(r, t.fillHover) }
            }
            let cols = columns(row: i, width: width)
            c.draw(row.time, in: cols.time, fontSize: fs, t.label3)
            c.draw(row.text, in: cols.text, fontSize: fs, m == .none ? t.label2 : t.label)
        }
        c.restoreGState()
    }
}
