import AppKit
import SSCore
import SSText

extension NSPasteboard.PasteboardType {
    /// A text template dragged from the Text panel: the `TextTemplateCatalog` entry id as a string.
    /// An effect dragged from the Effects panel: the effect id (`EffectsPanelView.roundedCorners`, ...).
    static let sequenceEffectID = NSPasteboard.PasteboardType("com.sequencestudio.effect-id")
    static let sequenceTextTemplate = NSPasteboard.PasteboardType("com.sequencestudio.text-template")
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
        public init(id: String, title: String, subtitle: String = "", symbol: String) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol
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

    init(rows: [Row], buttonTitle: String, hint: String, label: String) {
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
        scroll.frame = CGRect(x: 0, y: footer, width: bounds.width, height: max(bounds.height - footer, 0))
    }

    public var selectedID: String? { table.selectedRow >= 0 ? rows[table.selectedRow].id : nil }
    public func select(id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    @objc private func apply() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r) else { return }
        onApply?(rows[r].id)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
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

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let type = dragType else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].id, forType: type)
        return item
    }
}

/// Text panel: title templates. Drag one onto the timeline, or double-click to place it at the playhead.
@MainActor
public final class TextPanelView: TemplateListPanelView {
    public init() {
        super.init(rows: TextTemplateCatalog.all.map {
            Row(id: $0.id, title: $0.name, subtitle: "Title", symbol: "textformat")
        }, buttonTitle: "Add to Timeline", hint: "Drag onto the timeline or double-click.", label: "Text templates")
        dragType = .sequenceTextTemplate
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
}

/// Effects panel: the effects that exist so far. Drag one onto a clip (or double-click for the selection); it then shows in Effect Controls.
@MainActor
public final class EffectsPanelView: TemplateListPanelView {
    public static let roundedCorners = "rounded-corners"

    public init() {
        super.init(rows: [Row(id: Self.roundedCorners, title: "Rounded Corners", subtitle: "Video", symbol: "app")],
                   buttonTitle: "", hint: "Drag onto a clip, or double-click for the selected clips.", label: "Effects")
        dragType = .sequenceEffectID
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
}
