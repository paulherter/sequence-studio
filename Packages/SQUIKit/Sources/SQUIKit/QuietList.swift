import AppKit

/// V1 Quiet list chrome shared by the panels (docs/DESIGN-SPEC.md §2): no system alternating rows, no focus ring,
/// no grid, flat full-width selection fill, header from Theme tokens.
extension Theme.Metrics {
    /// Rows that carry a thumbnail (Library list); same height as the Effects rows.
    public static let mediaRow: CGFloat = Theme.Row.thumb
    /// Column header strip of table views.
    public static let columnHeader: CGFloat = Theme.Row.columnHeader
}

@MainActor
public enum QuietList {
    /// Turns the system table chrome off. `rowHeight` comes from `Theme.Metrics`.
    public static func style(_ table: NSTableView, rowHeight: CGFloat, background: NSColor = .clear) {
        table.rowHeight = rowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.focusRingType = .none
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.backgroundColor = background
        if table.headerView != nil { styleHeader(table) }
    }

    /// Header cells drawn with `QuietHeaderCell` in the panel color with a 1 px separator.
    public static func styleHeader(_ table: NSTableView) {
        table.headerView?.frame.size.height = Theme.Metrics.columnHeader
        for c in table.tableColumns { styleColumn(c) }
    }

    public static func styleColumn(_ c: NSTableColumn) {
        let old = c.headerCell
        let cell = QuietHeaderCell(textCell: c.title)
        cell.font = Theme.Typography.caption
        cell.alignment = old.alignment
        c.headerCell = cell
    }
}

/// Column header: `panel` fill, `label3` mini text, a hairline `separator` below, sort arrow in `label3`.
final class QuietHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.Colors.panel.setFill()
        cellFrame.fill()
        Theme.Colors.separator.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let s = NSAttributedString(string: stringValue, attributes: [.font: Theme.Typography.caption,
                                                                     .foregroundColor: Theme.Colors.label3])
        let h = s.size().height
        s.draw(at: NSPoint(x: cellFrame.minX + Theme.Spacing.xs, y: cellFrame.midY - h / 2))
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let name: SQIcon = ascending ? .chevronUp : .chevronDown
        guard let img = Theme.symbol(name, size: 8) else { return }
        let tinted = SQButton.tinted(img, Theme.Colors.label3)
        let r = NSRect(x: cellFrame.maxX - tinted.size.width - Theme.Spacing.xs, y: cellFrame.midY - tinted.size.height / 2,
                       width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: r)
    }
}
