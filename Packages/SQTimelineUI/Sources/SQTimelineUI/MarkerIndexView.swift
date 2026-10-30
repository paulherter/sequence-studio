import AppKit
import SQCore
import SQUIKit

/// The marker list as a panel body: a search field over a quiet table (color, position, name, length, comment).
/// A click on a row calls `onGo` with the marker's sequence time. All data and filtering is `MarkerIndexModel`.
@MainActor
public final class MarkerIndexView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public private(set) var model = MarkerIndexModel()
    /// A row was chosen: move the playhead there (and bring it on screen).
    public var onGo: ((Time) -> Void)?
    /// "Export CSV" button: the App asks for a file and writes `MarkerCSV`.
    public var onExportCSV: (() -> Void)?

    private let search = SQSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = EmptyStateView(title: "No markers", hint: "Press M to add a marker at the playhead")
    private lazy var exportButton = SQButton(title: "Export CSV", target: self, action: #selector(exportCSV), style: .standard)
    private var rows: [MarkerIndexEntry] = []
    private var suppressGo = false

    private enum Column: String, CaseIterable {
        case color, time, name, length, comment
        var title: String {
            switch self {
            case .color: ""
            case .time: "Time"
            case .name: "Name"
            case .length: "Length"
            case .comment: "Comment"
            }
        }
        var width: CGFloat {
            switch self {
            case .color: 22
            case .time: 84
            case .name: 140
            case .length: 76
            case .comment: 200
            }
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        search.setQuietPlaceholder("Filter markers")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        for c in Column.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            col.width = c.width
            col.minWidth = c == .color ? c.width : 40
            if c == .color { col.maxWidth = c.width }
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        QuietList.style(table, rowHeight: Theme.Row.list)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        SQScrollView.apply(to: scroll)
        for v in [search, scroll, exportButton, empty] as [NSView] { addSubview(v) }
        empty.isHidden = true
        setAccessibilityLabel("Marker list")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.sm
        let h = Theme.Metrics.quietField
        let button = exportButton.intrinsicContentSize.width
        exportButton.frame = CGRect(x: bounds.maxX - pad - button, y: pad, width: button, height: h)
        search.frame = CGRect(x: pad, y: pad, width: max(60, exportButton.frame.minX - pad * 2), height: h)
        let top = pad * 2 + h
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        empty.frame = scroll.frame
    }

    /// Shows the markers of `timeline`; the filters stay.
    public func reload(_ timeline: Timeline) {
        model.reload(timeline)
        refresh()
    }

    /// Selects the row the playhead is in (no `onGo`).
    public func follow(playhead: Time) {
        suppressGo = true
        defer { suppressGo = false }
        if let i = model.currentRow(at: playhead) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.deselectAll(nil)
        }
    }

    private func refresh() {
        rows = model.rows
        suppressGo = true
        table.reloadData()
        suppressGo = false
        empty.isHidden = !rows.isEmpty
        empty.title = model.entries.isEmpty ? "No markers" : "No matches"
        exportButton.isEnabled = !model.entries.isEmpty
    }

    @objc private func exportCSV() { onExportCSV?() }

    public func controlTextDidChange(_ obj: Notification) {
        model.query = search.stringValue
        refresh()
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = FlatSelectionRowView()
        v.showsHover = true
        return v
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id), rows.indices.contains(row) else { return nil }
        let e = rows[row]
        if column == .color { return MarkerDot(color: Theme.Palette.marker(e.color)) }
        let text: String
        switch column {
        case .time: text = model.text(for: e.time)
        case .name: text = e.name.isEmpty ? e.scopeLabel : e.name
        case .length: text = model.durationText(of: e)
        case .comment: text = e.comment
        case .color: text = ""
        }
        let f = NSTextField(labelWithString: text)
        f.font = column == .time || column == .length ? Theme.Typography.caption : Theme.Typography.body
        f.textColor = column == .name ? Theme.Colors.label : Theme.Colors.label2
        f.lineBreakMode = .byTruncatingTail
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressGo, rows.indices.contains(table.selectedRow) else { return }
        onGo?(rows[table.selectedRow].time)
    }
}

/// A marker color as a small round dot, centered in its cell.
@MainActor
private final class MarkerDot: NSView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 8
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
    }
}
