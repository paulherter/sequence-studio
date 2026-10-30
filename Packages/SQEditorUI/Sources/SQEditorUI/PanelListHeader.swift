import AppKit

/// Column header of the right-column lists (v9 `.tbl th`): 26 high, 11 pt semibold `label3` on `panel`, 8 in
/// (12 on the first column), a hairline below.
@MainActor
enum PanelListHeader {
    static let height: CGFloat = Theme.Row.panelList

    static func style(_ c: NSTableColumn, leadingPad: CGFloat = Theme.Spacing.sm) {
        let old = c.headerCell
        let cell = PanelListHeaderCell(textCell: c.title)
        cell.font = Theme.Typography.listHeader
        cell.alignment = old.alignment
        cell.leadingPad = leadingPad
        c.headerCell = cell
    }

    static func apply(to table: NSTableView) {
        table.headerView?.frame.size.height = height
        for c in table.tableColumns { style(c) }
    }
}

final class PanelListHeaderCell: NSTableHeaderCell {
    var leadingPad: CGFloat = Theme.Spacing.sm

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.Colors.panel.setFill()
        cellFrame.fill()
        Theme.Colors.separator.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let s = NSAttributedString(string: stringValue, attributes: [.font: Theme.Typography.listHeader,
                                                                     .foregroundColor: Theme.Colors.label3])
        let size = s.size()
        let x = alignment == .right ? cellFrame.maxX - Theme.Spacing.sm - size.width : cellFrame.minX + leadingPad
        s.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2))
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let tinted = (ascending ? SQIcon.chevronUp : SQIcon.chevronDown).image(size: 8, color: Theme.Colors.label3)
        let w: CGFloat = (stringValue as NSString).size(withAttributes: [.font: Theme.Typography.listHeader]).width
        let iw: CGFloat = tinted.size.width
        let ih: CGFloat = tinted.size.height
        // Right after the title (left of it in a right-aligned column), so it never covers the text.
        let right: CGFloat = cellFrame.maxX - Theme.Spacing.sm - w - Theme.Spacing.xs - iw
        let left: CGFloat = cellFrame.minX + leadingPad + w + Theme.Spacing.xs
        tinted.draw(in: NSRect(x: alignment == .right ? right : left, y: cellFrame.midY - ih / 2, width: iw, height: ih))
    }
}
