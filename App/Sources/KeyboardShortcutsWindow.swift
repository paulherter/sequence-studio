import AppKit
import SQEditorUI

/// Keyboard Shortcuts L modal (Cmd+Option+K, 860 x 640 in the shared modal shell): the Mac keyboard colored by command group, and below it every command
/// with its shortcut. Shortcuts are remappable: select a command, "Set Shortcut…" and press the keys, or click a key
/// on the keyboard picture and "Assign to Key". Conflicts are shown before anything changes. Changes go to `onChange`,
/// which saves them to `sq.keymap` and applies them to the menus and the key router.
@MainActor
final class KeyboardShortcutsWindowController: NSObject, NSSearchFieldDelegate {
    private var sheet: SQModalSheet?
    private var content: NSView?
    /// The window of the modal while it shows.
    private var window: NSWindow? { sheet?.window }
    /// The card while the modal shows (render harness).
    var cardView: NSView? { sheet?.window.scrim.card }
    private let search = SQSearchField()
    private let table = ShortcutList()
    private let countLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "Click a key to see what it does.")
    private let layout = KeyboardLayoutView()
    private let presetPopup = SQPopup()
    private let layoutPopup = SQPopup()
    private let keysNote = NSTextField(labelWithString: "Keys follow your keyboard layout.")
    private let modifierControl = SQSegmented(labels: ["⌃", "⌥", "⇧", "⌘"], segmentWidth: 30)
    private let setButton = SQButton(title: "Set Shortcut…", target: nil, action: nil, style: .accent)
    private let assignButton = SQButton(title: "Assign to Key", target: nil, action: nil)
    private let removeButton = SQButton(title: "Remove", target: nil, action: nil)
    private let resetButton = SQButton(title: "Reset to Defaults", target: nil, action: nil)
    /// Body height of the L modal: 640 minus header 56 and footer 68.
    static let bodyHeight: CGFloat = SQDialogMetrics.lBodyHeight

    var config: KeymapConfig
    private let onChange: (KeymapConfig) -> Void
    private var allRows: [KeymapRow]
    private(set) var rows: [KeymapRow]
    private var captureMonitor: Any?
    private var capturing = false

    init(config: KeymapConfig, onChange: @escaping (KeymapConfig) -> Void) {
        self.config = config
        self.onChange = onChange
        allRows = KeymapRow.build(config.map)
        rows = allRows
        super.init()
    }

    /// Opens the modal over the main window; a second call while it shows does nothing.
    func show(over explicitHost: NSWindow? = nil) {
        guard sheet == nil, let host = explicitHost ?? NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if content == nil { build() }
        guard let body = content else { return }
        body.removeFromSuperview()
        let width = Theme.Modal.widthL
        let title = SQDialogText(.title, "Keyboard Shortcuts", width: width - SQDialogMetrics.sidePad * 2)
        let done = SQButton(title: "Done", target: self, action: #selector(close), style: .accent)
        done.horizontalPadding = SQDialogMetrics.buttonPadding
        done.boxHeight = SQDialogMetrics.buttonHeight
        done.setContentHuggingPriority(.required, for: .horizontal)
        done.keyEquivalent = "\r"
        for b in [setButton, assignButton, removeButton] {
            b.boxHeight = SQDialogMetrics.buttonHeight
            b.horizontalPadding = SQDialogMetrics.buttonPadding
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        let footer = SQDialog.footerRow(left: [setButton, assignButton, removeButton], right: [done])
        let card = SQDialog.cardContent(title: title, note: nil, body: body, footer: footer, width: width)
        let m = SQModalSheet(card: card) { [weak self] in self?.close() }
        sheet = m
        m.present(over: host)
        m.window.makeFirstResponder(search)
    }

    @objc func close() {
        endCapture()
        sheet?.dismiss()
        sheet = nil
    }

    /// Render harness: the board's state (⌘ held, key K picked, "Add Edit" selected in the list).
    func applyRenderState() {
        modifierControl.setSelected(true, forSegment: 3)
        layout.model = KeyboardLayoutModel(map: config.map, modifiers: currentModifiers)
        layout.selectedKey = .char("k")
        if let i = rows.firstIndex(where: { $0.listing.command == "Add Edit" }) { table.selectedIndex = i }
        keySelected()
    }

    // MARK: Build

    private func build() {
        table.onSelect = { [weak self] in self?.updateButtons() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Colors.content      // the board's darker well (drawn, so a view capture shows it too)
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        SQScrollView.apply(to: scroll)
        scroll.hasHorizontalScroller = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = Theme.Colors.content.cgColor
        scroll.layer?.cornerRadius = Theme.Radius.well
        scroll.layer?.masksToBounds = true
        table.autoresizingMask = [.width]

        presetPopup.addItem(withTitle: config.baseTitle)
        presetPopup.sqItems = { [weak self] in self?.templateMenuItems() ?? [] }   // templates, own sets, import, save, export
        layoutPopup.addItems(withTitles: KeyboardLayout.Style.allCases.map(\.title))
        layoutPopup.target = self
        layoutPopup.action = #selector(layoutChanged(_:))
        let style = KeyboardLayout.Style.saved()
        layout.style = style
        layoutPopup.selectItem(at: KeyboardLayout.Style.allCases.firstIndex(of: style) ?? 0)
        modifierControl.segmentWidth = 0
        modifierControl.allowsMultipleSelection = true
        modifierControl.target = self
        modifierControl.action = #selector(modifiersChanged(_:))
        modifierControl.sqToolTip = "Show keys with these modifiers"
        layout.onSelect = { [weak self] _ in self?.keySelected() }
        search.placeholderString = "Search"
        search.delegate = self
        countLabel.font = Theme.Typography.body
        countLabel.textColor = Theme.Colors.label3
        for l in [infoLabel, keysNote] { l.font = Theme.Typography.body; l.textColor = Theme.Dialog.hintColor }
        infoLabel.lineBreakMode = .byTruncatingTail
        for b in [setButton, assignButton, removeButton] { b.boxHeight = Theme.Metrics.quietButton + 4; b.horizontalPadding = Theme.Spacing.lg }
        for (b, sel) in [(setButton, #selector(setShortcut)), (assignButton, #selector(assignToKey)),
                         (removeButton, #selector(removeShortcut)), (resetButton, #selector(resetAll))] {
            b.target = self; b.action = sel
        }

        // Legend: five columns, 28 between columns, 4 between the two rows.
        let groups = KeyGroup.allCases.filter { $0 != .other }
        let items: [NSView] = groups.map { g in
            let dot = LegendDot(color: KeyboardLayoutView.color(g))
            let name = NSTextField(labelWithString: g.title)
            name.font = Theme.Typography.body; name.textColor = Theme.Colors.label2
            let st = NSStackView(views: [dot, name]); st.spacing = Theme.Spacing.iconToLabel; st.alignment = .centerY
            return st
        }
        let columns = 5
        let gridRows = stride(from: 0, to: items.count, by: columns).map { start in
            Array(items[start..<min(start + columns, items.count)]) + (0..<max(0, start + columns - items.count)).map { _ in NSView() }
        }
        let legend = NSGridView(views: gridRows)
        legend.columnSpacing = 28; legend.rowSpacing = Theme.Spacing.xs
        legend.xPlacement = .leading; legend.yPlacement = .center

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [presetPopup, layoutPopup, resetButton, spacer, modifierControl])
        top.distribution = .fill; top.spacing = Theme.Spacing.sm; top.alignment = .centerY
        presetPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        layoutPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        countLabel.alignment = .right

        let content = NSView()
        for v in [top, layout, legend, infoLabel, keysNote, search, countLabel, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v)
        }
        let pad = Theme.Spacing.lg
                NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.sm),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            top.heightAnchor.constraint(equalToConstant: Theme.Metrics.quietButton),
            // The picture is 840 wide and draws its own 16 pt padding: it spans the 860 card edge to edge.
            layout.topAnchor.constraint(equalTo: top.bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            legend.topAnchor.constraint(equalTo: layout.bottomAnchor, constant: Theme.Spacing.md - 1),
            legend.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            infoLabel.centerYAnchor.constraint(equalTo: layout.bottomAnchor, constant: 53.5),
            infoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            infoLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            keysNote.centerYAnchor.constraint(equalTo: infoLabel.centerYAnchor, constant: 11),
            keysNote.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            search.topAnchor.constraint(equalTo: layout.bottomAnchor, constant: 78),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            search.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -Theme.Spacing.sm),
            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            countLabel.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            countLabel.widthAnchor.constraint(equalToConstant: 110),
            search.heightAnchor.constraint(equalToConstant: Theme.Metrics.quietField),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: Theme.Spacing.sm),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            content.heightAnchor.constraint(equalToConstant: Self.bodyHeight),
        ])
        self.content = content
        syncUI()
        table.items = rows.map(\.listing)
    }

    // MARK: State

    private var selectedRow: KeymapRow? {
        let i = table.selectedIndex
        return rows.indices.contains(i) ? rows[i] : nil
    }

    private var currentModifiers: KeyModifiers {
        var m: KeyModifiers = []
        if modifierControl.isSelected(forSegment: 0) { m.insert(.control) }
        if modifierControl.isSelected(forSegment: 1) { m.insert(.option) }
        if modifierControl.isSelected(forSegment: 2) { m.insert(.shift) }
        if modifierControl.isSelected(forSegment: 3) { m.insert(.command) }
        return m
    }

    /// Refresh everything that depends on the map.
    func syncUI() {
        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: config.baseTitle)
        presetPopup.selectItem(at: 0)
        resetButton.isEnabled = config.isModified
        layout.model = KeyboardLayoutModel(map: config.map, modifiers: currentModifiers)
        refilter()
        updateButtons()
        keySelected()
    }

    private func refilter() {
        let keep = selectedRow?.command
        allRows = KeymapRow.build(config.map)
        rows = KeymapRow.filter(allRows, query: search.stringValue)
        table.items = rows.map(\.listing)
        table.selectedIndex = keep.flatMap { k in rows.firstIndex(where: { $0.command == k }) } ?? -1
        countLabel.stringValue = rows.count == allRows.count ? "\(rows.count) shortcuts" : "\(rows.count) of \(allRows.count)"
    }

    private func updateButtons() {
        let row = selectedRow
        setButton.isEnabled = row != nil
        removeButton.isEnabled = row?.entry != nil
        assignButton.isHidden = layout.selectedKey == nil
        removeButton.isHidden = row?.entry == nil
        assignButton.isEnabled = row != nil
        if let k = layout.selectedKey {
            assignButton.title = "Assign to " + KeyboardListing.text(for: KeyBinding(k, currentModifiers))
        } else {
            assignButton.title = "Assign to Key"
        }
    }

    private func keySelected() {
        if let k = layout.selectedKey { infoLabel.stringValue = layout.model.summary(for: k) }
        updateButtons()
    }

    // MARK: Actions

    @objc private func layoutChanged(_ sender: SQPopup) {
        let style = KeyboardLayout.Style.allCases[max(0, sender.indexOfSelectedItem)]
        layout.style = style
        UserDefaults.standard.set(style.rawValue, forKey: KeyboardLayout.Style.defaultsKey)
        layout.selectedKey = nil
        infoLabel.stringValue = "Click a key to see what it does."
        updateButtons()
    }

    @objc private func modifiersChanged(_ sender: Any?) {
        layout.model = KeyboardLayoutModel(map: config.map, modifiers: currentModifiers)
        keySelected()
    }

    @objc private func setShortcut() {
        guard selectedRow != nil, !capturing else { return }
        capturing = true
        infoLabel.stringValue = "Press the new shortcut (Esc cancels)."
        setButton.isEnabled = false
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.capturing else { return event }
            if event.keyCode == 53 { self.endCapture(); return nil }   // Esc
            guard let ke = KeyMapping.keyEvent(from: event, capture: true) else { return nil }
            let row = self.selectedRow
            self.endCapture()
            if let row { self.attempt(row, binding: ke.binding) }
            return nil
        }
    }

    private func endCapture() {
        capturing = false
        if let m = captureMonitor { NSEvent.removeMonitor(m) }
        captureMonitor = nil
        keySelected()
    }

    @objc private func assignToKey() {
        guard let row = selectedRow, let k = layout.selectedKey else { return }
        attempt(row, binding: KeyBinding(k, currentModifiers))
    }

    @objc private func removeShortcut() {
        guard let e = selectedRow?.entry else { return }
        config.set(map: Keymap.unbind(e, in: config.map))
        commit()
    }

    @objc private func resetAll() {
        let a = SQDialog()
        a.messageText = SQL10n.format("Reset all shortcuts to the %@ defaults?", config.baseTitle)
        a.informativeText = SQL10n.format("Every shortcut you changed on top of “%@” goes back.", config.baseTitle)
        a.addButton("Reset")
        a.addButton("Cancel", role: .cancel)
        guard a.runModal() == .first else { return }
        config.resetOverrides()
        commit()
    }

    /// Binds the row's command to `binding`: in the row's own scope (Everywhere for a command without a key).
    /// Same-scope conflicts and shadowing are shown first; a reserved key is refused.
    private func attempt(_ row: KeymapRow, binding: KeyBinding) {
        let scope = row.entry?.scope ?? .global
        let map = config.map
        let conflicts = Keymap.conflicts(of: row.command, binding: binding, scope: scope, in: map)
        if conflicts.contains(where: { $0.kind == .reserved }) {
            let a = SQDialog()
            a.messageText = "That shortcut is not available"
            a.informativeText = conflicts[0].message(for: binding)
            a.addButton("OK")
            a.runModal()
            return
        }
        if !conflicts.isEmpty {
            let a = SQDialog()
            let hard = conflicts.contains { $0.kind == .sameScope }
            a.messageText = hard ? "Replace the existing shortcut?" : "This shortcut overlaps another one"
            a.informativeText = conflicts.map { $0.message(for: binding) }.joined(separator: "\n")
                + (hard ? "\n\nThe other command loses this key." : "")
            a.addButton(hard ? "Replace" : "Assign Anyway")
            a.addButton("Cancel", role: .cancel)
            guard a.runModal() == .first else { return }
        }
        guard let new = Keymap.assign(row.command, to: binding, scope: scope, in: map, moving: row.entry) else { return }
        config.set(map: new)
        commit()
    }

    func commit() {
        onChange(config)
        syncUI()
    }

    func controlTextDidChange(_ obj: Notification) {
        rows = KeymapRow.filter(allRows, query: search.stringValue)
        table.items = rows.map(\.listing)
        table.selectedIndex = -1
        updateButtons()
        countLabel.stringValue = rows.count == allRows.count ? "\(rows.count) shortcuts" : "\(rows.count) of \(allRows.count)"
    }
}

/// Flat own list (replaces NSTableView): 28 pt rows, full-width `selection` fill, Theme fonts, arrow-key navigation.
@MainActor
final class ShortcutList: NSView {
    var items: [KeyboardListing.Row] = [] { didSet { resize(); needsDisplay = true; updateEmpty() } }
    private func updateEmpty() {
        if empty.superview == nil { empty.frame = bounds; empty.autoresizingMask = [.width, .height]; addSubview(empty) }
        empty.isHidden = !items.isEmpty
    }
    var selectedIndex = -1 { didSet { needsDisplay = true; if selectedIndex >= 0 { scrollToVisible(rowRect(selectedIndex)) } } }
    var onSelect: () -> Void = {}
    private let rowHeight = Theme.Row.list
    private var hoverIndex = -1 { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private let empty = EmptyStateView(title: "No matching shortcuts", hint: "Try another name or key")
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let i = Int(convert(event.locationInWindow, from: nil).y / rowHeight)
        hoverIndex = items.indices.contains(i) ? i : -1
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = -1 }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func rowRect(_ i: Int) -> NSRect { NSRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight) }
    private func resize() {
        let h = max(CGFloat(items.count) * rowHeight, enclosingScrollView?.contentSize.height ?? 0)
        setFrameSize(NSSize(width: enclosingScrollView?.contentSize.width ?? frame.width, height: h))
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); needsDisplay = true }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); resize() }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(items.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let scopeW: CGFloat = 190, keyW: CGFloat = 90, pad = Theme.Spacing.md
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        for i in first...last {
            let r = rowRect(i)
            if i == selectedIndex { (window?.firstResponder === self ? Theme.Selection.fillFocused : Theme.Selection.fill).setFill(); r.fill() }
            else if i == hoverIndex { Theme.Selection.hover.setFill(); r.fill() }
            func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, w: CGFloat) {
                let h = font.boundingRectForFont.height
                NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
                    .draw(in: NSRect(x: x, y: r.minY + (rowHeight - h) / 2, width: max(w, 0), height: h))
            }
            let it = items[i]
            let keyX = r.maxX - pad - scopeW - keyW
            text(it.command, Theme.Typography.body, Theme.Colors.label, x: pad, w: keyX - pad - Theme.Spacing.sm)
            text(it.shortcut, Theme.Typography.body, Theme.Colors.label2, x: keyX, w: keyW)
            text(it.scope, Theme.Typography.body, Theme.Colors.label3, x: r.maxX - pad - scopeW, w: scopeW)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let i = Int(convert(event.locationInWindow, from: nil).y / rowHeight)
        selectedIndex = items.indices.contains(i) ? i : -1
        onSelect()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125 where selectedIndex < items.count - 1: selectedIndex += 1; onSelect()
        case 126 where selectedIndex > 0: selectedIndex -= 1; onSelect()
        case 125, 126: break
        default: super.keyDown(with: event)
        }
    }
}

/// Legend dot of a command group (8 pt circle).
@MainActor
private final class LegendDot: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(ovalIn: bounds).fill() }
}
