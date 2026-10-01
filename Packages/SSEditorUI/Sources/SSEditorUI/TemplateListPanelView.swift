import AppKit
import SSCore
import SSText

extension NSPasteboard.PasteboardType {
    /// An effect dragged from the Effects panel: the effect id.
    public static let sequenceEffectID = NSPasteboard.PasteboardType("com.sequencestudio.effect-id")
    /// A text template dragged from the Library: the `TextTemplateCatalog` entry id as a string.
    public static let sequenceTextTemplate = NSPasteboard.PasteboardType("com.sequencestudio.text-template")
}

/// Simple list with an "Apply" button and double-click, used by the Text and Effects panels.
/// Rows may be dragged out (`dragType`).
@MainActor
public class TemplateListPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var symbol: String
        /// A category heading: not selectable, not draggable.
        public var isHeader: Bool
        public init(id: String, title: String, subtitle: String = "", symbol: String, isHeader: Bool = false) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.isHeader = isHeader
        }
    }

    public var rows: [Row] { didSet { table.reloadData() } }
    /// Double-click or the button.
    public var onApply: ((String) -> Void)?
    fileprivate var dragType: NSPasteboard.PasteboardType?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let button = NSButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    /// Present when the panel is searchable (the Effects panel); typing calls `onSearch`.
    fileprivate let searchField = NSSearchField()
    fileprivate var onSearch: ((String) -> Void)?

    init(rows: [Row], buttonTitle: String, hint: String, label: String, searchable: Bool = false) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        let col = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(apply)
        table.target = self
        table.setAccessibilityLabel(label)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        button.title = buttonTitle
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Theme.Fonts.small
        button.target = self; button.action = #selector(apply)
        self.hint.stringValue = hint
        self.hint.font = Theme.Fonts.small
        self.hint.textColor = Theme.Colors.label3
        addSubview(scroll); addSubview(self.hint)
        if searchable {
            searchField.placeholderString = "Search"
            searchField.controlSize = .small
            searchField.font = Theme.Fonts.small
            searchField.target = self; searchField.action = #selector(searchChanged)
            searchField.setAccessibilityLabel("Search \(label)")
            addSubview(searchField)
        }
        if !buttonTitle.isEmpty { addSubview(button) }
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.md
        let footer: CGFloat = button.superview == nil ? 28 : 52
        hint.frame = CGRect(x: pad, y: 6, width: max(bounds.width - 2 * pad, 0), height: 18)
        button.sizeToFit()
        button.frame.origin = CGPoint(x: pad, y: 28)
        let top: CGFloat = searchField.superview == nil ? 0 : 30
        if top > 0 { searchField.frame = CGRect(x: pad, y: bounds.height - 26, width: max(bounds.width - 2 * pad, 0), height: 22) }
        scroll.frame = CGRect(x: 0, y: footer, width: bounds.width, height: max(bounds.height - footer - top, 0))
    }

    @objc private func searchChanged() { onSearch?(searchField.stringValue) }

    public var selectedID: String? { table.selectedRow >= 0 && !rows[table.selectedRow].isHeader ? rows[table.selectedRow].id : nil }
    public func select(id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    @objc private func apply() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r), !rows[r].isHeader else { return }
        onApply?(rows[r].id)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        if r.isHeader {
            let t = NSTextField(labelWithString: r.title)
            t.font = .systemFont(ofSize: 11, weight: .semibold); t.textColor = Theme.Colors.label2
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xs),
                                         t.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.setAccessibilityLabel(r.title)
            return cell
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: r.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.Colors.label2
        let title = NSTextField(labelWithString: r.title)
        title.font = Theme.Fonts.smallName; title.textColor = Theme.Colors.label
        let sub = NSTextField(labelWithString: r.subtitle)
        sub.font = Theme.Fonts.mini; sub.textColor = Theme.Colors.label3
        let texts = NSStackView(views: r.subtitle.isEmpty ? [title] : [title, sub])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 0
        let stack = NSStackView(views: [icon, texts])
        stack.spacing = Theme.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xs),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        cell.setAccessibilityLabel(r.title)
        return cell
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isHeader }
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].isHeader }
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].isHeader ? 24 : 34 }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let type = dragType, !rows[row].isHeader else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].id, forType: type)
        return item
    }
}

/// Effects panel: the effects that exist so far, grouped like Premiere's bins and searchable. Drag one onto a clip (or
/// double-click for the selection); it then shows in Effect Controls. Categories with no effect are not listed.
@MainActor
public final class EffectsPanelView: TemplateListPanelView {
    public static let roundedCorners = "rounded-corners"

    public struct Entry: Sendable, Hashable {
        public var id: String, title: String, category: String, symbol: String
        public init(id: String, title: String, category: String, symbol: String) {
            self.id = id; self.title = title; self.category = category; self.symbol = symbol
        }
    }
    /// Everything that can be applied today. Audio effects, video transitions and audio transitions have no entry
    /// until the engine can render them.
    public static let catalog: [Entry] = [
        Entry(id: roundedCorners, title: "Rounded Corners", category: "Video Effects", symbol: "app"),
    ]

    /// Rows for a search text: entries whose title or category contain it (case-insensitive), under their category.
    public static func rows(matching query: String, in entries: [Entry] = catalog) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = entries.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.category.lowercased().contains(q) }
        var out: [Row] = []
        var seen: [String] = []
        for e in hits where !seen.contains(e.category) { seen.append(e.category) }
        for c in seen {
            out.append(Row(id: "category-" + c, title: c, symbol: "folder", isHeader: true))
            out += hits.filter { $0.category == c }.map { Row(id: $0.id, title: $0.title, symbol: $0.symbol) }
        }
        return out
    }

    public init() {
        super.init(rows: Self.rows(matching: ""), buttonTitle: "",
                   hint: "Drag onto a clip, or double-click for the selected clips.", label: "Effects", searchable: true)
        dragType = .sequenceEffectID
        onSearch = { [weak self] q in self?.rows = Self.rows(matching: q) }
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
}
