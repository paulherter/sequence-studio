import AppKit
import CoreText
import SQCore

/// Read-only caption list: one row per caption, start time left, text right; the row at the playhead is marked, a
/// click seeks there. Nothing here edits (captions are corrected on the caption track). Rows are drawn, not views, and
/// only the visible ones: 2,000 captions cost the same as 20.
///
/// Placement: the Controls column, as its last section ("All Captions"), full width, any height from three rows up.
/// Feed it with `setModel` when the timeline changes and `setPlayhead` on playhead moves; `onSeek` gets the click.
@MainActor
public final class CaptionReadListView: NSView {
    public private(set) var model = CaptionListModel()
    public var onSeek: ((Time) -> Void)?

    private let scroll = NSScrollView()
    private let rowsView = RowsView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = rowsView
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
        rowsView.onClick = { [weak self] i in
            guard let self, let t = model.seekTime(row: i) else { return }
            onSeek?(t)
        }
        setAccessibilityLabel("All Captions")
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public func setModel(_ m: CaptionListModel) {
        guard m != model else { return }
        model = m
        rowsView.rows = m.rows
        rowsView.selected = Set(m.rows.indices.filter { selectedIDs.contains(m.rows[$0].id) })
        layoutRows()
    }

    /// How a row is marked: selected (the stronger mark) wins over the playhead row.
    enum Mark: Equatable { case none, playhead, selected }

    /// Marks the rows of the selected captions (the track selection).
    public func setSelected(_ ids: Set<CaptionItem.ID>) {
        let rows = Set(model.rows.indices.filter { ids.contains(model.rows[$0].id) })
        guard rows != rowsView.selected || ids != selectedIDs else { return }
        let changed = rows.symmetricDifference(rowsView.selected)
        selectedIDs = ids
        rowsView.selected = rows
        for i in changed { rowsView.setNeedsDisplay(rowsView.rect(row: i)) }
    }
    private var selectedIDs: Set<CaptionItem.ID> = []

    /// Rows marked as selected (tests).
    var selectedRows: Set<Int> { rowsView.selected }
    func mark(row i: Int) -> Mark { rowsView.mark(row: i) }

    /// Marks the row at the playhead. Only the two rows that change are redrawn, and nothing when the row is the same,
    /// so this is free during playback.
    public func setPlayhead(_ t: Time) {
        let row = model.currentRow(at: t)
        guard row != rowsView.current else { return }
        let old = rowsView.current
        rowsView.current = row
        for i in [old, row].compactMap({ $0 }) { rowsView.setNeedsDisplay(rowsView.rect(row: i)) }
    }

    /// Left edge of the time column and the inset of the text's right edge. The Controls column puts both on its grid
    /// (label column, trailing inset); the selection fill still spans the row.
    public var insets: (left: CGFloat, right: CGFloat) {
        get { rowsView.insets }
        set {
            guard newValue != rowsView.insets else { return }
            rowsView.insets = newValue
            rowsView.needsDisplay = true
        }
    }

    /// Frames of the time and the text of row `index` in the list's own coordinates, unscrolled (layout tests).
    func columns(row index: Int) -> (time: CGRect, text: CGRect) { rowsView.columns(row: index) }

    /// The row that is marked as current (tests).
    public var currentRow: Int? { rowsView.current }

    /// Height that shows every row (a host without its own scrolling can clamp it).
    public var contentHeight: CGFloat { CGFloat(model.rows.count) * Theme.Row.list }

    public override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        rowsView.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(contentHeight, scroll.contentSize.height))
        rowsView.needsDisplay = true
    }

    /// Clicks row `index` (tests).
    func click(row index: Int) { rowsView.onClick?(index) }
    /// Lines shaped so far (tests: a redraw of rows already seen shapes nothing).
    var shapedCount: Int { rowsView.shapedCount }
    /// Draws every row once into an offscreen context (tests).
    func drawForTest() {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        layoutSubtreeIfNeeded()
        cacheDisplay(in: bounds, to: rep)
    }

    private final class RowsView: NSView {
        var rows: [CaptionListModel.Row] = []
        var current: Int?
        var selected: Set<Int> = []
        func mark(row i: Int) -> Mark { selected.contains(i) ? .selected : (i == current ? .playhead : .none) }
        var hovered: Int? { didSet { if oldValue != hovered { for i in [oldValue, hovered].compactMap({ $0 }) { setNeedsDisplay(rect(row: i)) } } } }
        var onClick: ((Int) -> Void)?
        private var area: NSTrackingArea?

        override var isFlipped: Bool { true }

        func rect(row i: Int) -> CGRect {
            CGRect(x: 0, y: CGFloat(i) * Theme.Row.list, width: bounds.width, height: Theme.Row.list)
        }
        private func row(at p: CGPoint) -> Int? {
            let i = Int(floor(p.y / Theme.Row.list))
            return rows.indices.contains(i) ? i : nil
        }

        /// Time column: the widest timecode plus the inner gap (the Controls grid's label column plus its gap).
        private static let timeWidth: CGFloat = Theme.Inspector.nameWidth + Theme.Inspector.columnGap
        var insets: (left: CGFloat, right: CGFloat) = (Theme.Spacing.sm, Theme.Spacing.sm)

        private var textX: CGFloat { insets.left + Self.timeWidth }
        private var textRoom: CGFloat { max(bounds.width - textX - insets.right, 0) }

        func columns(row i: Int) -> (time: CGRect, text: CGRect) {
            let r = rect(row: i)
            return (CGRect(x: insets.left, y: r.minY, width: Theme.Inspector.nameWidth, height: r.height),
                    CGRect(x: textX, y: r.minY, width: textRoom, height: r.height))
        }

        /// A shaped (and, for the text, truncated) line. The key is all that shapes it: the text, the room it has and
        /// the font. The color is not part of it: it comes from the context at draw time.
        private struct LineKey: Hashable {
            let text: String
            let room: Int
            let font: NSFont
        }
        private var shaped: [LineKey: CTLine] = [:]
        private static let shapedLimit = 4000
        private(set) var shapedCount = 0

        private func line(_ text: String, font: NSFont, room: CGFloat?) -> CTLine {
            let key = LineKey(text: text, room: room.map { Int($0.rounded(.down)) } ?? -1, font: font)
            if let l = shaped[key] { return l }
            if shaped.count >= Self.shapedLimit { shaped.removeAll(keepingCapacity: true) }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
            var l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            if let room {
                let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
                l = CTLineCreateTruncatedLine(l, Double(key.room), .end, dots) ?? l
            }
            shaped[key] = l
            shapedCount += 1
            return l
        }

        override func draw(_ dirtyRect: NSRect) {
            guard !rows.isEmpty, let cg = NSGraphicsContext.current?.cgContext else { return }
            let h = Theme.Row.list
            let first = max(Int(floor(dirtyRect.minY / h)), 0), last = min(Int(ceil(dirtyRect.maxY / h)), rows.count)
            guard first < last else { return }
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let timeFont = Theme.Typography.tabularBody, textFont = Theme.Typography.body
            let drop = (textFont.capHeight / 2).rounded()
            let textX = self.textX, room = textRoom
            // Resolved per draw, so the list follows an appearance change.
            let timeColor = Theme.Colors.label3.cgColor, textColor = Theme.Colors.label2.cgColor, currentColor = Theme.Colors.label.cgColor
            for i in first..<last {
                let r = rect(row: i), row = rows[i]
                let mark = self.mark(row: i)
                if mark == .selected { Theme.State.selectedFocused.setFill(); r.fill() }
                else if mark == .playhead { Theme.Colors.selection.setFill(); r.fill() }
                else if i == hovered { Theme.State.rowHover.setFill(); r.fill() }
                let baseline = r.midY + drop
                cg.textPosition = CGPoint(x: insets.left, y: baseline)
                cg.setFillColor(timeColor)
                CTLineDraw(line(row.time, font: timeFont, room: nil), cg)
                cg.textPosition = CGPoint(x: textX, y: baseline)
                cg.setFillColor(mark == .none ? textColor : currentColor)
                CTLineDraw(line(row.text, font: textFont, room: room), cg)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }
        override func mouseMoved(with event: NSEvent) { hovered = row(at: convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { hovered = nil }
        override func mouseDown(with event: NSEvent) {
            if let i = row(at: convert(event.locationInWindow, from: nil)) { onClick?(i) }
        }
    }
}
