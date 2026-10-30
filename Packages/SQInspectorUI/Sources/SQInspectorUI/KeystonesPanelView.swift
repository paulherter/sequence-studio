import AppKit
import Observation
import SQCore

/// Window > Keystones: the keyframe building blocks. Drag one onto a clip (timeline or Effect Controls); double-click
/// applies it to the selected clip at the playhead. The panel menu ("...") and the context menu save the selected clip's
/// keys as a new keystone; Edit Curve, Use Keyframe Easing and Delete / Reset to Built-in are in the row context menu.
@MainActor
public final class KeystonesPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public let model: KeystonesPanelModel
    /// Double-click or "Apply to Selected Clip".
    public var onApply: ((Keystone) -> Void)?
    /// "Save Keystone from Selected Clip…": save the selected clip's keys as a keystone (the host asks for a name).
    public var onSaveFromClip: (() -> Void)?

    /// v9 `.clist`: 26 pt rows, 8 in from the panel edges, 4 above the first.
    static let rowHeight: CGFloat = Theme.Row.panelList
    private let table = SQMenuTableView()
    private let scroll = NSScrollView()
    private var rows: [Keystone] = []
    private var popover: SQPopover?
    private let emptyState = EmptyStateView(title: "No keystones yet",
                                            hint: "Save the keyframes of a clip as a keystone to reuse them.")

    public init(model: KeystonesPanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)

        let col = NSTableColumn(identifier: .init("keystone"))
        table.addTableColumn(col)
        table.headerView = nil
        QuietList.style(table, rowHeight: Self.rowHeight)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(applySelected)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.sqItems = { [weak self] row in self?.contextItems(row: row) ?? [] }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        observe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func observe() {
        let ks = withObservationTracking { model.keystones } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if ks != rows {
            rows = ks
            table.reloadData()
            if let id = model.selectedID, let i = rows.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes([i], byExtendingSelection: false)
            }
        }
        updateButtons()
    }

    private func updateButtons() {
        emptyState.isHidden = !rows.isEmpty
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = LibraryRowView()          // v9 `.clist .row`: rounded hover and selection, no stripes
        v.selectionRadius = Theme.Radius.control
        v.pillInset = Theme.Spacing.sm
        v.showsHover = true
        return v
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let k = rows[row]
        let cell = (tableView.makeView(withIdentifier: .init("keystoneCell"), owner: nil) as? KeystoneCell) ?? KeystoneCell()
        cell.identifier = .init("keystoneCell")
        cell.configure(k, customised: k.isBuiltIn && model.canDelete(k.id))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        model.selectedID = rows.indices.contains(r) ? rows[r].id : nil
        updateButtons()
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), let s = KeystoneDrag.string(for: rows[row]) else { return nil }
        let item = NSPasteboardItem()
        item.setString(s, forType: .sequenceKeystone)
        return item
    }

    // MARK: Actions

    private var clickedOrSelected: Keystone? {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(r) ? rows[r] : nil
    }

    @objc private func applySelected() { if let k = clickedOrSelected { onApply?(k) } }
    @objc private func saveFromClip() { onSaveFromClip?() }

    /// Delete key: removes the selected keystone (built-ins refuse, see `canDelete`). True when there was one to delete.
    @discardableResult
    public func deleteSelection() -> Bool {
        let r = table.selectedRow
        guard rows.indices.contains(r), model.canDelete(rows[r].id) else { return false }
        model.onDelete?(rows[r].id)
        return true
    }

    private func editCurve(_ k: Keystone) {
        model.selectedID = k.id
        popover?.close()
        let p = EasingCurvePopover.make(source: KeystoneEaseSource(model: model, id: k.id))
        popover = p
        let row = rows.firstIndex(where: { $0.id == k.id }) ?? 0
        p.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .maxX)
    }

    // MARK: Menus

    /// Panel header "...": what the footer "+" did (v9 has no footer), and Apply for the selected keystone.
    public func showOptions(from sender: NSView) {
        var items = [SQMenuItem(title: "Save Keystone from Selected Clip\u{2026}") { [weak self] in self?.saveFromClip() }]
        let r = table.selectedRow
        if rows.indices.contains(r) {
            let k = rows[r]
            items.append(SQMenuItem(title: "Apply to Selected Clip") { [weak self] in self?.onApply?(k) })
        }
        SQContextMenu.popUp(items: items, at: NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
    }

    /// SQ rows for the clicked keystone (or the selected one when the click missed every row).
    func contextItems(row: Int) -> [SQMenuItem] {
        let r = row >= 0 ? row : table.selectedRow
        let save = SQMenuItem(title: "Save Keystone from Selected Clip\u{2026}") { [weak self] in self?.saveFromClip() }
        guard rows.indices.contains(r) else { return [save] }
        let k = rows[r]
        var items = [
            SQMenuItem(title: "Apply to Selected Clip") { [weak self] in self?.onApply?(k) },
            .separator,
            SQMenuItem(title: "Edit Curve\u{2026}") { [weak self] in self?.editCurve(k) },
            SQMenuItem(title: "Use Keyframe Easing", isEnabled: k.easing != nil) { [weak self] in self?.model.setEasing(nil, for: k.id) },
            .separator,
            save,
        ]
        if model.canDelete(k.id) {
            items.append(.separator)    // destructive entry last
            items.append(SQMenuItem(title: k.isBuiltIn ? "Reset to Built-in" : "Delete Keystone") { [weak self] in self?.model.onDelete?(k.id) })
        }
        return items
    }
}

/// One row (v9 `.clist .row`): diamond, name, "changed" chip on an edited built-in, and at the right what it animates.
private final class KeystoneCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let chip = KeystoneChip(text: "changed")
    private let meta = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for v in [icon, title, chip, meta] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.font = Theme.Typography.list
        title.textColor = Theme.Colors.label2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        meta.font = Theme.Typography.list
        meta.textColor = Theme.Colors.label3
        meta.alignment = .right
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        icon.image = Theme.symbol(.diamond, size: 12, label: nil)
        icon.contentTintColor = Theme.Colors.label3
        textField = title
        let pad = 2 * Theme.Spacing.sm          // row 8 in, 8 of padding
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.iconToLabel),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Theme.Spacing.iconToLabel),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            meta.leadingAnchor.constraint(greaterThanOrEqualTo: chip.trailingAnchor, constant: Theme.Spacing.sm),
            meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            meta.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ k: Keystone, customised: Bool) {
        title.stringValue = k.name
        chip.isHidden = !customised
        meta.stringValue = KeystonesPanelModel.subtitle(k)
        sqToolTip = KeystonesPanelModel.subtitle(k)
        setAccessibilityLabel(customised ? k.name + ", changed" : k.name)
    }
}

/// Passive chip (v9 `.chip.xs`): 20 high capsule, `fill`, 11 pt `label2`. Clicks go to the row.
private final class KeystoneChip: NSView {
    private let text: NSAttributedString
    init(text: String) {
        self.text = NSAttributedString(string: text, attributes: [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2])
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: isHidden ? 0 : ceil(text.size().width) + 2 * Theme.Spacing.sm, height: LibraryChip.height) }
    override var isHidden: Bool { didSet { invalidateIntrinsicContentSize() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = text.size()
        text.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }
}
