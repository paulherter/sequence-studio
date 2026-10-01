import AppKit
import SQCore

/// Markers panel: NSTableView with color, name, in, duration, comment. Double-click seeks,
/// text columns edit inline.
@MainActor
public final class MarkersPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public let model: MarkersPanelModel
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private static let columns: [(MarkerColumn, String, CGFloat)] = [
        (.color, "", 28), (.name, "Name", 160), (.inPoint, "In", 90), (.duration, "Duration", 90), (.comment, "Comment", 220),
    ]

    public init(model: MarkersPanelModel = MarkersPanelModel()) {
        self.model = model
        super.init(frame: .zero)
        for (col, title, width) in Self.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = title; c.width = width
            c.minWidth = col == .color ? 28 : 50
            if col == .color { c.maxWidth = 28 }
            table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.Colors.content
        table.gridColor = Theme.Colors.separator
        table.rowHeight = 22
        table.style = .fullWidth
        table.allowsMultipleSelection = false
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        model.onChange = { [weak self] in self?.table.reloadData() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    static func nsColor(_ c: MarkerColorChoice) -> NSColor {
        switch c {
        case .green: Theme.Colors.green
        case .red: Theme.Colors.red
        case .purple: Theme.hex(0xBF5AF2)
        case .orange: Theme.hex(0xFF9F0A)
        case .yellow: Theme.Colors.yellow
        case .white: Theme.hex(0xFFFFFF)
        case .blue: Theme.Colors.accent
        case .cyan: Theme.hex(0x64D2FF)
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let col = MarkerColumn(rawValue: id) else { return nil }
        let rows = model.rows
        guard rows.indices.contains(row) else { return nil }
        let r = rows[row]
        if col == .color {
            let v = NSView()
            v.wantsLayer = true
            let dot = NSView(frame: NSRect(x: 8, y: 6, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = Self.nsColor(r.color).cgColor
            dot.layer?.cornerRadius = 2
            v.addSubview(dot)
            return v
        }
        let f = NSTextField()
        f.isBordered = false; f.drawsBackground = false
        f.font = col == .inPoint || col == .duration ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        f.textColor = Theme.Colors.label
        f.lineBreakMode = .byTruncatingTail
        f.isEditable = col != .color
        f.delegate = self
        f.identifier = NSUserInterfaceItemIdentifier(col.rawValue)
        switch col {
        case .name: f.stringValue = r.name
        case .inPoint: f.stringValue = r.inTimecode
        case .duration: f.stringValue = r.durationTimecode
        case .comment: f.stringValue = r.comment
        case .color: break
        }
        return f
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow, col = table.clickedColumn
        guard row >= 0 else { return }
        // Editable text columns edit inline on double-click; the rest seek.
        if col >= 0, let id = table.tableColumns[col].identifier.rawValue as String?,
           let c = MarkerColumn(rawValue: id), c == .name || c == .comment {
            table.editColumn(col, row: row, with: nil, select: true)
            return
        }
        model.activate(row: row)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let id = f.identifier?.rawValue,
              let col = MarkerColumn(rawValue: id) else { return }
        let row = table.row(for: f)
        guard row >= 0 else { return }
        if !model.commit(row: row, column: col, text: f.stringValue) { table.reloadData() }
    }
}
