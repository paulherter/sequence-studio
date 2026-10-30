import AppKit

/// Floating palette (Option+Space): search field on top, result list below. Up/Down move, Return applies, Esc or a click
/// elsewhere closes. The window sizes itself to its content. For a transition with selected clips Return swaps the whole
/// content for a Start/End question (Left/Right choose, Return confirms). It only reports the chosen item; the app applies it.
@MainActor
public final class QuickApplyPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        /// Sees every key before the text field does; return true to swallow it.
        var keyHandler: ((NSEvent) -> Bool)?
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, keyHandler?(event) == true { return }
            super.sendEvent(event)
        }
    }

    /// The card: grabbing it anywhere that is not a control drags the whole palette; double-click resets the spot.
    private final class DragCard: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        var onDragEnd: (() -> Void)?
        var onReset: (() -> Void)?
        private var grab: NSPoint?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?(); return }
            guard let w = window else { return }
            grab = NSPoint(x: NSEvent.mouseLocation.x - w.frame.origin.x, y: NSEvent.mouseLocation.y - w.frame.origin.y)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window, let g = grab else { return }
            w.setFrameOrigin(NSPoint(x: NSEvent.mouseLocation.x - g.x, y: NSEvent.mouseLocation.y - g.y))
        }
        override func mouseUp(with event: NSEvent) {
            if grab != nil { grab = nil; onDragEnd?() }
        }
    }

    public let model: QuickApplyModel
    /// Called after the panel closed, with the row the user confirmed.
    public var onChoose: ((QuickApplyItem, TransitionEnd?) -> Void)?
    /// Whether a transition can go to the start or end of selected clips (then Return asks which).
    public var canChooseTransitionEnd: () -> Bool = { false }

    private static let width: CGFloat = 640
    private static let headerHeight: CGFloat = 44
    private static let rowHeight: CGFloat = Theme.Row.menu
    private static let maxRows = 8
    private static let askHeight: CGFloat = 132
    private static let emptyHeight: CGFloat = 72

    private let panel: KeyPanel
    /// Overlay card (no blur / visual effect): `Theme.Overlay.style`.
    private let blur = DragCard()
    private let field = NSTextField()
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let askBox = NSView()
    private let askTitle = NSTextField(labelWithString: "")
    private let emptyState = EmptyStateView(title: "No results", hint: "Try another name, or press Esc to close.")
    private let askHint = NSTextField(labelWithString: "Left = start, Right = end, Down = both, Return confirms, Esc goes back")
    private let startButton = SQButton(title: "Start", target: nil, action: nil)
    private let bothButton = SQButton(title: "Both", target: nil, action: nil)
    private let endButton = SQButton(title: "End", target: nil, action: nil)
    private static let ends: [TransitionEnd] = [.start, .both, .end]
    private var closing = false
    private var resignObserver: NSObjectProtocol?

    public init(model: QuickApplyModel) {
        self.model = model
        let size = NSSize(width: Self.width, height: Self.headerHeight + Self.rowHeight * 8 + 12)
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .fullSizeContentView],
                         backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true   // moved by DragCard (position remembered), not by the window server
        panel.keyHandler = { [weak self] e in MainActor.assumeIsolated { self?.handleKey(e) ?? false } }

        blur.wantsLayer = true
        Theme.Overlay.style(blur.layer)
        panel.contentView = blur
        blur.onDragEnd = { [weak self] in self?.rememberPosition() }
        blur.onReset = { [weak self] in self?.resetPosition() }

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.Typography.display
        field.placeholderString = "Apply effect, transition or preset"
        field.delegate = self
        blur.addSubview(field)

        separator.boxType = .separator
        blur.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = Self.width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        QuietList.style(table, rowHeight: Self.rowHeight)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        blur.addSubview(scroll)
        emptyState.isHidden = true
        blur.addSubview(emptyState)

        askTitle.font = Theme.Typography.titleStrong
        askTitle.alignment = .center
        askTitle.lineBreakMode = .byTruncatingTail
        askHint.font = Theme.Typography.body
        askHint.textColor = Theme.Colors.label2
        askHint.alignment = .center
        for (i, b) in [startButton, bothButton, endButton].enumerated() {
            b.setButtonType(.pushOnPushOff)
            b.target = self
            b.action = #selector(endButtonClicked(_:))
            b.tag = i
            askBox.addSubview(b)
        }
        askBox.addSubview(askTitle)
        askBox.addSubview(askHint)
        askBox.isHidden = true
        blur.addSubview(askBox)

        model.onChange = { [weak self] in self?.reload() }
    }

    @objc private func endButtonClicked(_ sender: SQButton) {
        model.chooseEnd(Self.ends[sender.tag])
        confirm()
    }

    public var isShown: Bool { panel.isVisible }

    /// Shows the palette centered in the upper third of `window` (or the main screen). The top edge stays put when it resizes.
    public func show(over window: NSWindow?) {
        model.reopen()
        field.stringValue = model.query
        hostFrame = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        placeAtSavedOrDefault()
        closing = false
        reload()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)   // the last search is selected: typing replaces it, Delete clears it
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }   // shown twice: one observer
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private var hostFrame: NSRect = .zero

    private func screens() -> [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    /// Remembered top-left (clamped to the screens that exist now) or the default spot over the editor window.
    private func placeAtSavedOrDefault() {
        let size = panel.frame.size
        let raw = QuickApplyPlacement.load() ?? QuickApplyPlacement.defaultTopLeft(in: hostFrame, width: Self.width)
        let tl = QuickApplyPlacement.clamp(topLeft: raw, size: size, screens: screens())
        panel.setFrame(NSRect(x: tl.x, y: tl.y - size.height, width: Self.width, height: size.height), display: false)
    }

    private func rememberPosition() {
        QuickApplyPlacement.save(CGPoint(x: panel.frame.minX, y: panel.frame.maxY))
    }

    private func resetPosition() {
        QuickApplyPlacement.reset()
        placeAtSavedOrDefault()
    }

    public func close() {
        guard !closing else { return }
        closing = true
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        panel.orderOut(nil)
    }

    private func confirm() {
        switch model.confirm(canChooseEnd: canChooseTransitionEnd()) {
        case .none: break
        case .askEnd: reload()
        case .apply(let item, let end):
            close()
            onChoose?(item, end)
        }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        model.select(table.clickedRow)
        confirm()
    }

    /// Up/Down/Return/Esc always; Left/Right only while the start/end question is up (otherwise the field moves its caret).
    /// In the question: Left = start, Right = end, Down = both (the default), Return applies the choice.
    private func handleKey(_ e: NSEvent) -> Bool {
        if !e.modifierFlags.intersection([.command, .option, .control]).isEmpty { return false }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }   // IME composition
        let asking = model.pendingTransition != nil
        switch e.keyCode {
        case 126 where !asking: model.move(-1)
        case 125 where !asking: model.move(1)
        case 123 where asking: model.chooseEnd(.start)
        case 124 where asking: model.chooseEnd(.end)
        case 125 where asking: model.chooseEnd(.both)
        case 36, 76: confirm()
        case 53: if asking { model.cancelEndChoice() } else { close() }
        default: return asking   // no typing while the question is up
        }
        return true
    }

    /// Sizes the window to its content (top edge fixed) and swaps the list for the question.
    private func reload() {
        let asking = model.pendingTransition
        let rows = min(model.results.count, Self.maxRows)
        let noResults = asking == nil && model.results.isEmpty && !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let height: CGFloat
        if let asking {
            height = Self.askHeight
            askTitle.stringValue = "\(asking.title): add at the start, the end or both ends of the selected clips"
            for (b, end) in zip([startButton, bothButton, endButton], Self.ends) { b.state = model.transitionEnd == end ? .on : .off }
        } else {
            height = Self.headerHeight + (rows > 0 ? CGFloat(rows) * Self.rowHeight + 10 : noResults ? Self.emptyHeight : 0)
        }
        let wasAsking = !askBox.isHidden
        field.isHidden = asking != nil
        separator.isHidden = asking != nil || (rows == 0 && !noResults)
        scroll.isHidden = asking != nil || rows == 0
        askBox.isHidden = asking == nil
        emptyState.isHidden = !noResults

        var f = panel.frame
        if abs(f.height - height) > 0.5 {
            f.origin.y += f.height - height
            f.size.height = height
            panel.setFrame(f, display: true)
        }
        let w = Self.width
        blur.frame = NSRect(x: 0, y: 0, width: w, height: height)
        field.frame = NSRect(x: 14, y: height - 38, width: w - 28, height: Theme.Row.controlLarge)
        separator.frame = NSRect(x: 0, y: height - Self.headerHeight, width: w, height: 1)
        scroll.frame = NSRect(x: 0, y: 6, width: w, height: max(0, height - Self.headerHeight - 10))
        askBox.frame = NSRect(x: 0, y: 0, width: w, height: height)
        emptyState.frame = NSRect(x: 0, y: 0, width: w, height: max(0, height - Self.headerHeight))
        askTitle.frame = NSRect(x: 16, y: height - 40, width: w - 32, height: 20)
        startButton.frame = NSRect(x: w / 2 - 160, y: height - 84, width: 100, height: Theme.Row.controlLarge)
        bothButton.frame = NSRect(x: w / 2 - 50, y: height - 84, width: 100, height: Theme.Row.controlLarge)
        endButton.frame = NSRect(x: w / 2 + 60, y: height - 84, width: 100, height: Theme.Row.controlLarge)
        askHint.frame = NSRect(x: 16, y: 12, width: w - 32, height: 16)
        table.tableColumns.first?.width = w
        if wasAsking, asking == nil, panel.isVisible {   // hiding the field resigned it: take focus back
            panel.makeFirstResponder(field)
            field.currentEditor()?.moveToEndOfLine(nil)
        }
        table.reloadData()
        if model.results.indices.contains(model.selectedIndex) {
            table.selectRowIndexes(IndexSet(integer: model.selectedIndex), byExtendingSelection: false)
            table.scrollRowToVisible(model.selectedIndex)
        }
    }

    // MARK: Field

    public func controlTextDidChange(_ obj: Notification) {
        if model.pendingTransition != nil { field.stringValue = model.query; return }
        model.query = field.stringValue
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { model.results.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.results.indices.contains(row) else { return nil }
        let item = model.results[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: item.title)
        title.font = Theme.Typography.title
        title.textColor = Theme.Colors.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = NSTextField(labelWithString: SQL10n.string(model.isRecentRow(item) ? "Recent" : item.category))
        kind.font = Theme.Typography.body
        kind.textColor = Theme.Colors.label2
        kind.setContentHuggingPriority(.required, for: .horizontal)
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [title, spacer, kind])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.Spacing.lg),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { paletteRow() }

    /// The palette is menu-like and the search field keeps the focus, so its selected row always shows the focused fill.
    private func paletteRow() -> FlatSelectionRowView {
        let r = FlatSelectionRowView()
        r.isEmphasized = true
        return r
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0, row != model.selectedIndex { model.select(row) }
    }
}
