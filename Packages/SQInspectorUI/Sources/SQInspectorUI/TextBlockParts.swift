import AppKit

// Small building blocks of the text block (TextBlockView): the shared row grid, the Appearance row with its detail rows,
// the multi-line text box and the font field adapter. Columns, gaps and heights are `ControlsGrid`'s.

// MARK: Row grid

/// One property row on the Controls grid (`ControlsGrid`): the label in the label column, the controls from the value
/// column to the trailing inset with the grid's one gap between their bounds. Every row is one grid row high.
@MainActor
final class TextBlockRow: NSView, ControlsRowProbing {
    static let labelWidth: CGFloat = ControlsGrid.labelWidth
    static let detailLabelWidth: CGFloat = ControlsGrid.labelWidth
    static let inset: CGFloat = ControlsGrid.trailing
    static let ring: CGFloat = ControlsGrid.labelX - ControlsGrid.trailing

    let label: NSTextField?
    let controls: NSStackView

    override var isFlipped: Bool { true }

    /// An icon in place of the label word (shadow rows): the tooltip names the value.
    private let iconView: NSImageView?
    /// No label: the controls start in the label column (rows of icon groups).
    let fullWidth: Bool

    init(label text: String?, icon: SQIcon? = nil, tip: String? = nil, fullWidth: Bool = false,
         labelWidth: CGFloat = ControlsGrid.labelWidth, controls views: [NSView], height: CGFloat = ControlsGrid.rowHeight) {
        controls = GridStack(views: views)
        self.fullWidth = fullWidth
        if let icon {
            let v = NSImageView(image: icon.image(size: Theme.Typography.symbolInline, color: Theme.Colors.label2))
            v.imageScaling = .scaleNone
            v.imageAlignment = .alignLeft
            v.sqToolTip = tip
            if let tip { v.setAccessibilityLabel(tip) }
            iconView = v
        } else {
            iconView = nil
        }
        if let text, icon == nil {
            let l = NSTextField(labelWithString: text)
            l.font = Theme.Typography.body; l.textColor = Theme.Colors.label2
            l.lineBreakMode = .byTruncatingTail
            label = l
        } else {
            label = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        controls.orientation = .horizontal; controls.spacing = ControlsGrid.gap; controls.alignment = .centerY
        controls.distribution = .fill
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: fullWidth ? ControlsGrid.labelX : ControlsGrid.valueX),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ControlsGrid.trailing),
            // Never wider than the control column (`ControlsGrid.controlColumnMaxX`).
            controls.widthAnchor.constraint(lessThanOrEqualToConstant: ControlsGrid.controlColumnMaxX
                - (fullWidth ? ControlsGrid.labelX : ControlsGrid.valueX)),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let fill = controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ControlsGrid.trailing)
        fill.priority = .defaultHigh
        fill.isActive = true
        if let label { addSubview(label) }
        if let iconView { addSubview(iconView) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The label's bounds are the grid's label column (a constraint would place its alignment rect, 2 pt narrower).
        let frame = ControlsGrid(width: bounds.width).labelFrame(height: bounds.height)
        label?.frame = frame
        iconView?.frame = frame
    }

    var rowProbe: ControlsRowProbe {
        // A plain NSView in the stack is a flexible spacer, not a control.
        let shown = controls.arrangedSubviews.filter { !$0.isHidden && type(of: $0) != NSView.self }
        return ControlsRowProbe(label: label?.frame ?? iconView?.frame, controls: shown.map { convert($0.bounds, from: $0) },
                                fullWidth: fullWidth)
    }
}

/// Two icon groups side by side with a wider break between them (vertical alignment | text direction): one control to the row.
@MainActor
final class IconGroupPair: NSView {
    private let first: NSView, second: NSView
    static let split: CGFloat = 16

    init(_ first: NSView, _ second: NSView) {
        self.first = first; self.second = second
        super.init(frame: .zero)
        addSubview(first); addSubview(second)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let a = first.intrinsicContentSize, b = second.intrinsicContentSize
        return NSSize(width: a.width + Self.split + b.width, height: max(a.height, b.height))
    }

    override func layout() {
        super.layout()
        let a = first.intrinsicContentSize, b = second.intrinsicContentSize
        first.frame = NSRect(x: 0, y: (bounds.height - a.height) / 2, width: a.width, height: a.height)
        second.frame = NSRect(x: a.width + Self.split, y: (bounds.height - b.height) / 2, width: b.width, height: b.height)
    }
}

/// A row's controls, side by side with the grid's gap between their BOUNDS. AppKit lays out alignment rects, and a
/// label, pop-up or segmented control is larger than its alignment rect, so two neighbors would end 1 to 5 pt closer
/// than the gap and the first one would start left of the value column. After each pass every arranged view gets its
/// alignment rect as its frame.
@MainActor
final class GridStack: NSStackView {
    private var placed: [ObjectIdentifier: NSRect] = [:]

    override func layout() {
        super.layout()
        for v in arrangedSubviews where !v.isHidden {
            let id = ObjectIdentifier(v)
            if placed[id] == v.frame { continue }       // still where the last pass put it
            let f = v.alignmentRect(forFrame: v.frame)
            v.frame = f
            placed[id] = f
        }
    }
}

// MARK: Appearance row

/// The head of an Appearance row on the Controls grid: checkbox in the toggle column, name in the label column, swatch in
/// value column 0, the main value in value column 1, the Open chevron in the tail column.
@MainActor
final class AppearanceHead: NSView, ControlsRowProbing {
    let check: SQCheckbox, label: NSTextField, well: SQColorWell, value: ScrubField, chevron: IconButton
    var summary: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let summary { addSubview(summary) }
            needsLayout = true
        }
    }

    /// Opt-in: the screen color picker in value column 2 (text layers; the graphic item rows have none).
    var eyedropper: IconButton? {
        didSet {
            oldValue?.removeFromSuperview()
            if let eyedropper { addSubview(eyedropper) }
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    init(check: SQCheckbox, label: NSTextField, well: SQColorWell, value: ScrubField, chevron: IconButton) {
        self.check = check; self.label = label; self.well = well; self.value = value; self.chevron = chevron
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ControlsGrid.rowHeight).isActive = true
        for v in [check, label, well, value, chevron] as [NSView] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, grid = ControlsGrid(width: bounds.width)
        check.frame = grid.toggleBox(Theme.Metrics.checkbox, height: h)
        grid.place(label, height: h)
        well.frame = grid.controlFrame(x: ControlsGrid.valueColumn(0), width: ControlsGrid.valueWidth, height: h,
                                       controlHeight: Theme.Row.swatch.height)
        value.frame = grid.valueFrame(1, height: h)
        chevron.frame = grid.resetFrame(height: h)
        eyedropper?.frame = grid.controlFrame(x: ControlsGrid.valueColumn(2), width: ControlsGrid.resetWidth, height: h)
        let x = ControlsGrid.valueX, lh = ControlsGrid.labelHeight
        summary?.frame = NSRect(x: x, y: ((h - lh) / 2).rounded(), width: max(grid.resetX - ControlsGrid.gap - x, 0), height: lh)
    }

    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(toggle: check.isHidden ? nil : check.frame, label: label.frame,
                         controls: ([well, value] + [eyedropper].compactMap { $0 }).filter { !$0.isHidden }.map(\.frame), tail: chevron.frame)
    }
}

/// Fill / Outline / Background / Shadow / Second Line: checkbox, label, color well, the main value and the Open
/// chevron (`AppearanceHead`); the chevron reveals `detail` (a faint band with hairlines above and below). The open
/// state is remembered.
@MainActor
final class AppearanceRow: NSStackView {
    static let swatchWidth: CGFloat = ControlsGrid.valueWidth
    let key: String
    let check = SQCheckbox(title: "", target: nil, action: nil)
    let well = SQColorWell()
    let value = ScrubField()
    var onLayoutChange: (() -> Void)?

    let head: AppearanceHead
    private let labelField: NSTextField
    private let chevron: IconButton
    private let detailBox = DetailBand()
    private var dimmed = false

    static func defaultsKey(_ k: String) -> String { "sq.textBlock.open.\(k)" }

    private(set) var isOpen: Bool {
        didSet {
            detailBox.isHidden = !isOpen
            chevron.setSymbol(isOpen ? .chevronDown : .chevronRight, tint: Theme.Colors.label3)
            UserDefaults.standard.set(isOpen, forKey: Self.defaultsKey(key))
            onLayoutChange?()
        }
    }

    init(key: String, title: String, hasCheck: Bool) {
        self.key = key
        isOpen = UserDefaults.standard.object(forKey: Self.defaultsKey(key)) as? Bool ?? false
        labelField = NSTextField(labelWithString: title)
        chevron = IconButton(symbol: .chevronRight, label: SQL10n.format("Open %@", SQL10n.string(title)), handler: {})
        head = AppearanceHead(check: check, label: labelField, well: well, value: value, chevron: chevron)
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 0
        check.setAccessibilityLabel(SQL10n.format("Enable %@", SQL10n.string(title)))
        check.sqToolTip = SQL10n.format("Enable %@", SQL10n.string(title))
        check.isHidden = !hasCheck
        labelField.font = Theme.Typography.body
        labelField.lineBreakMode = .byTruncatingTail
        value.isPlain = true
        chevron.handler = { [weak self] in self?.toggle() }
        chevron.setSymbol(isOpen ? .chevronDown : .chevronRight, tint: Theme.Colors.label3)
        chevron.sqToolTip = SQL10n.format("Open %@", SQL10n.string(title))
        addArrangedSubview(head)
        addArrangedSubview(detailBox)
        for v in [head, detailBox] as [NSView] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        detailBox.isHidden = !isOpen
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Detail rows (revealed by the chevron).
    var detail: DetailBand { detailBox }

    func toggle() { isOpen.toggle() }

    /// A row without detail rows (a plain switch): no chevron, no color or value slot.
    func makeSwitchOnly() {
        chevron.isHidden = true
        well.isHidden = true
        value.isHidden = true
    }

    /// Adds the eyedropper button after the value: `pick` runs when it is pressed.
    func addEyedropper(tip: String, pick: @escaping () -> Void) {
        let b = IconButton(symbol: .eyedropper, label: tip, handler: pick)
        b.sqToolTip = tip
        head.eyedropper = b
    }

    /// Second Line shows a text summary where the others show swatch and value.
    func setSummary(_ v: NSView) { head.summary = v }

    /// Layer on or off: the checkbox, the color and value dim when off (board `.offr`).
    func set(on: Bool, color: NSColor?, value v: Double?) {
        check.state = on ? .on : .off
        if let color, !well.isActive { well.color = color }
        if let v, !value.isDragging, !value.isEditing { value.value = v }
        well.isEnabled = on; value.isEnabled = on
        head.eyedropper?.isEnabled = on
        setDimmed(!on)
    }

    /// Multi-select: the layer is on in some clips and off in others (dash in the checkbox; the shown clip's state still
    /// decides whether color and value can be edited) and / or its color differs (empty swatch). Call after `set`.
    func setMixed(on mixedOn: Bool, color mixedColor: Bool) {
        if mixedOn { check.state = .mixed }
        if well.isMixed != mixedColor { well.isMixed = mixedColor }
    }

    func setDimmed(_ off: Bool) {
        dimmed = off
        labelField.textColor = off ? Theme.Colors.label3 : Theme.Colors.label2
        well.alphaValue = off ? 0.35 : 1
        value.alphaValue = off ? 0.6 : 1
        head.eyedropper?.alphaValue = off ? 0.35 : 1
    }
}

/// The opened detail rows: a faint band (white 3 %) with hairlines above and below. No padding: its rows keep the grid's
/// row pitch.
@MainActor
final class DetailBand: NSView {
    private let stack = NSStackView()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func append(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.white(0.03).setFill(); bounds.fill()
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: Text box

/// The multi-line text box (radius 8, min height 40): from the grid's label column to the trailing inset.
@MainActor
final class TextBoxView: NSView, NSTextViewDelegate {
    var onBegin: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onEnd: (() -> Void)?
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private static let boxHeight: CGFloat = 52
    /// The box's outer bounds (the layout test reads them).
    var boxFrame: NSRect {
        NSRect(x: ControlsGrid.labelX, y: 2, width: max(bounds.width - ControlsGrid.labelX - ControlsGrid.trailing, 0), height: Self.boxHeight)
    }

    override var isFlipped: Bool { true }
    var string: String { textView.string }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.boxHeight + ControlsGrid.gap).isActive = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.font = Theme.Typography.body
        textView.textColor = Theme.Colors.label
        textView.insertionPointColor = Theme.Colors.accent
        textView.isRichText = false
        textView.allowsUndo = false          // the clip's undo stack owns edits
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ControlsGrid.labelX + 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ControlsGrid.trailing - 1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            scroll.heightAnchor.constraint(equalToConstant: Self.boxHeight - 2),
        ])
        setAccessibilityLabel("Text")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Puts the caret at the end of the text (Return on a text layer in a list).
    func focus() {
        guard let w = window else { return }
        w.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func setString(_ s: String) {
        guard textView.window?.firstResponder !== textView, textView.string != s else { return }
        textView.string = s
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: boxFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.overlay, yRadius: Theme.Radius.overlay)
        Theme.Colors.field.setFill(); p.fill()
        (textView.window?.firstResponder === textView ? Theme.Colors.accentRing : Theme.Colors.fieldEdge).setStroke()
        p.lineWidth = 1; p.stroke()
    }

    func textDidBeginEditing(_ notification: Notification) { needsDisplay = true; onBegin?() }
    func textDidChange(_ notification: Notification) { onChange?(textView.string) }
    func textDidEndEditing(_ notification: Notification) { needsDisplay = true; onEnd?() }
}

// MARK: Font field adapter

/// The font control of the text block: families in, the picked family out. `TextFontPopup` is the current popup; the
/// typeable capsule (`SQFontField`) conforms to this and replaces it in `TextBlockView.makeFontControl()`.
@MainActor
protocol TextFontControl: NSView {
    var families: [String] { get set }
    var selectedFamily: String? { get set }
    var onPick: ((String) -> Void)? { get set }
    /// Live preview while arrowing through the list (and the restore on Esc): not an edit, no undo step.
    var onPreview: ((String) -> Void)? { get set }
    /// The editing session ended (after a pick, on Esc, or when focus left).
    var onEnd: (() -> Void)? { get set }
}

/// `SQFontField` behind the adapter protocol: Up/Down preview, Return/click picks, Esc restores.
@MainActor
final class SQFontFieldControl: NSView, TextFontControl {
    let field: SQFontField
    var onPick: ((String) -> Void)?
    var onPreview: ((String) -> Void)? { didSet { field.onPreview = onPreview } }
    var onEnd: (() -> Void)? { didSet { field.onEnd = onEnd } }
    var families: [String] = []
    var selectedFamily: String? { didSet { if selectedFamily != oldValue { field.fontName = selectedFamily ?? "" } } }

    init() {
        field = SQFontField(fontName: "")
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor), field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor), field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        field.familiesProvider = { [weak self] in self?.families ?? [] }
        field.onCommit = { [weak self] name in self?.onPick?(name) }
        field.sqToolTip = "Font"
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: SQFontField.height) }
}

/// The font popup behind the adapter protocol.
@MainActor
final class TextFontPopup: NSView, TextFontControl {
    private let popup = TextPanelMenuButton()
    var onPick: ((String) -> Void)?
    var onPreview: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var families: [String] = [] { didSet { if families != oldValue { rebuild() } } }
    var selectedFamily: String? { didSet { if selectedFamily != oldValue { rebuild() } } }

    init() {
        super.init(frame: .zero)
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor), popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor), popup.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        popup.sqToolTip = "Font"
        popup.onSelect = { [weak self] i in
            guard let self, let t = popup.titles[safe: i] else { return }
            onPick?(t)
        }
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { popup.intrinsicContentSize }

    private func rebuild() { popup.setItems(families, selected: selectedFamily.flatMap { families.firstIndex(of: $0) } ?? -1) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
