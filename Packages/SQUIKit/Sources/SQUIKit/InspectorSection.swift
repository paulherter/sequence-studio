import AppKit

/// Header band of an inspector section (INTERACTION-AUDIT "InspectorSection"; replaces Effect Controls'
/// `SectionHeaderRow`, `TextPanelSection` and `ColorSectionHeader` when those panels migrate):
/// THE one disclosure component (design artifact v11, sq.css `.sec`, Parts "Panel parts"): 24 pt row on the panel color,
/// drawn chevron (down open, right closed, `label3`, 1.2 stroke) in the 16 pt slot, `bodyStrong` title at `nameX`, optional
/// enable box and trailing accessories (reset button, menu) right-aligned, `separator` hairline on TOP (`showsTopLine`).
/// The WHOLE row is the hit area (click anywhere toggles, no other behavior). Opening fades the body in over `Motion.fast` (120 ms).
/// States: hover fills the whole row (`State.controlHover`, .16), `isSelected` uses `Selection.fill`, a disabled toggle dims the title.
public final class InspectorSectionHeader: NSView, ControlsRowProbing {
    public let titleLabel: NSTextField
    public let chevron: IconButton
    /// Hairline above the row (every section but the first of a panel). Default on.
    public var showsTopLine = true { didSet { if oldValue != showsTopLine { needsDisplay = true } } }
    /// Fills the row with the panel color (default). Off on a dialog / popover surface that has its own color.
    public var drawsBackground = true { didSet { if oldValue != drawsBackground { needsDisplay = true } } }
    public let enableToggle: SQCheckbox?
    private var accessories: [NSView] = []
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    public var onToggleExpanded: (@MainActor (Bool) -> Void)?
    /// Owned by `InspectorSection` (shows / hides its body) so callers keep `onToggleExpanded` for themselves.
    var sectionHook: (@MainActor (Bool) -> Void)?
    public var onToggleEnabled: (@MainActor (Bool) -> Void)?

    public var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = SQL10n.string(newValue); updateChevron() }
    }
    public var isExpanded: Bool { didSet { if oldValue != isExpanded { updateChevron() } } }
    public var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    public var isEnabledToggleOn: Bool {
        get { enableToggle?.state == .on }
        set { enableToggle?.state = newValue ? .on : .off; updateTitleColour() }
    }

    public init(title: String, hasEnableToggle: Bool = false, isExpanded: Bool = true) {
        titleLabel = NSTextField(labelWithString: SQL10n.string(title))
        enableToggle = hasEnableToggle ? SQCheckbox(target: nil, action: nil) : nil
        self.isExpanded = isExpanded
        chevron = SectionChevron(frame: .zero)
        super.init(frame: .zero)
        chevron.handler = { [weak self] in self?.toggleExpanded() }
        titleLabel.font = Theme.Typography.bodyStrong
        titleLabel.textColor = Theme.Colors.label
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(chevron)
        addSubview(titleLabel)
        if let enableToggle {
            enableToggle.state = .on
            enableToggle.target = self
            enableToggle.action = #selector(enableChanged)
            enableToggle.setAccessibilityLabel(SQL10n.format("Enable %@", SQL10n.string(title)))
            enableToggle.sqToolTip = SQL10n.format("Enable %@", SQL10n.string(title))
            addSubview(enableToggle)
        }
        updateChevron()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.Inspector.headerHeight) }

    /// The one quiet summary text of a closed or open header ("Clean White", "In: Fade"): body size in `label3`, one line,
    /// right-aligned next to the title's tail. Every header that shows a summary builds it here (`addAccessory`).
    public static func makeSummaryLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = Theme.Typography.body
        label.textColor = Theme.Colors.label3
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .right
        return label
    }

    /// Adds a trailing control (right to left in call order), e.g. an `IconButton` reset.
    public func addAccessory(_ view: NSView) {
        accessories.append(view)
        addSubview(view)
        needsLayout = true
    }

    public func toggleExpanded() {
        isExpanded.toggle()
        sectionHook?(isExpanded)
        onToggleExpanded?(isExpanded)
    }

    @objc private func enableChanged() {
        updateTitleColour()
        onToggleEnabled?(isEnabledToggleOn)
    }

    private func updateChevron() {
        chevron.image = SectionChevron.image(open: isExpanded)
        chevron.contentTintColor = Theme.Colors.label3
        let name = SQL10n.format(isExpanded ? "Collapse %@" : "Expand %@", SQL10n.string(title))
        chevron.sqToolTip = name
        chevron.setAccessibilityLabel(name)
    }

    private func updateTitleColour() {
        titleLabel.textColor = enableToggle == nil || isEnabledToggleOn ? Theme.Colors.label : Theme.State.disabledText
    }

    public override func layout() {
        super.layout()
        let h = bounds.height, slot = Theme.Inspector.iconSlot
        chevron.frame = NSRect(x: Theme.Inspector.ringX - (slot - KeyframeToggleView.slot) / 2, y: 0, width: slot, height: h)
        var x = bounds.width - Theme.Inspector.trailing
        let lh = Theme.Inspector.labelHeight
        for a in accessories {
            if let label = a as? NSTextField, !label.isEditable {
                // A quiet text (v9 `.khead .sum`): as wide as its text, on the title's line. Measured from the string: a
                // truncating label's own size came out short ("Ti…" for "Title").
                guard !label.stringValue.isEmpty else {      // no text: no width and no gap, still at the tail edge
                    label.frame = NSRect(x: x, y: ((h - lh) / 2).rounded(), width: 0, height: lh)
                    continue
                }
                let text = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? Theme.Typography.body]).width) + 4
                let w = min(text, max(x - Theme.Inspector.nameX - 80, 0))
                x -= w
                label.frame = NSRect(x: x, y: ((h - lh) / 2).rounded(), width: w, height: lh)
                x -= ControlsGrid.gap
                continue
            }
            let w = max(a.sqLayoutSize.width, slot)
            x -= w
            a.frame = NSRect(x: x, y: 0, width: w, height: h)
            x -= ControlsGrid.gap
        }
        if let enableToggle {
            let box = Theme.Metrics.checkbox
            x -= box
            enableToggle.frame = NSRect(x: x, y: ((h - box) / 2).rounded(), width: box, height: box)
            x -= ControlsGrid.gap
        }
        titleLabel.frame = NSRect(x: Theme.Inspector.nameX, y: ((h - lh) / 2).rounded(),
                                  width: max(x - Theme.Inspector.nameX, 0), height: lh)
    }

    public var rowProbe: ControlsRowProbe {
        ControlsRowProbe(toggle: chevron.frame, label: titleLabel.frame, tail: accessories.first { !$0.isHidden }?.frame ?? enableToggle?.frame)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    /// Scrolling under a resting pointer sends no mouseExited: re-read the pointer on every scroll step (`ScrollHoverSync`).
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in self?.hovering = p != nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { toggleExpanded() }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if drawsBackground { Theme.Colors.panel.setFill(); bounds.fill() }
        if isSelected { Theme.Selection.fill.setFill(); bounds.fill() } else if hovering { Theme.State.controlHover.setFill(); bounds.fill() }
        guard showsTopLine else { return }
        Theme.Separator.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Separator.width).fill()
    }
}

/// The section chevron: an `IconButton` that draws the board's 5 pt chevron and never shows a hover pill
/// (the whole header row carries the hover).
private final class SectionChevron: IconButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .imageOnly
        title = ""
        target = self
        action = #selector(fireChevron)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fireChevron() { handler?() }
    override var fillColor: NSColor? { nil }

    /// Open = pointing down, closed = pointing right (sq.css `.cv.o` / `.cv`): 5 x 5 corner rotated, 1.2 stroke. Template image.
    static func image(open: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            let p = NSBezierPath()
            if open {
                p.move(to: NSPoint(x: r.midX - 2.5, y: r.midY + 1.25))
                p.line(to: NSPoint(x: r.midX, y: r.midY - 1.25))
                p.line(to: NSPoint(x: r.midX + 2.5, y: r.midY + 1.25))
            } else {
                p.move(to: NSPoint(x: r.midX - 1.25, y: r.midY + 2.5))
                p.line(to: NSPoint(x: r.midX + 1.25, y: r.midY))
                p.line(to: NSPoint(x: r.midX - 1.25, y: r.midY - 2.5))
            }
            p.lineWidth = 1.2
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// A collapsible inspector section: `header` plus `body` (vertical stack the panel fills with `InspectorRow`s).
/// The open state is remembered under `sq.inspector.open.<key>` when `key` is given.
public final class InspectorSection: NSStackView {
    public let header: InspectorSectionHeader
    public let body = NSStackView()
    public let key: String?
    /// The fixed height of `header` (a caller may change `.constant`, e.g. 25 with the top line inside the row).
    public private(set) var headerHeightConstraint: NSLayoutConstraint!
    /// Called after the body is shown or hidden (the panel re-lays out its scroll content).
    public var onLayoutChange: (@MainActor () -> Void)?

    public static func defaultsKey(_ key: String) -> String { "sq.inspector.open.\(key)" }

    public var isExpanded: Bool { header.isExpanded }

    public init(title: String, key: String? = nil, hasEnableToggle: Bool = false, defaultOpen: Bool = true) {
        self.key = key
        let stored = key.flatMap { UserDefaults.standard.object(forKey: Self.defaultsKey($0)) as? Bool }
        header = InspectorSectionHeader(title: title, hasEnableToggle: hasEnableToggle, isExpanded: stored ?? defaultOpen)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.isHidden = !header.isExpanded
        addArrangedSubview(header)
        addArrangedSubview(body)
        for v in [header, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        headerHeightConstraint = header.heightAnchor.constraint(equalToConstant: Theme.Inspector.headerHeight)
        headerHeightConstraint.isActive = true
        header.sectionHook = { [weak self] open in self?.expansionChanged(open) }
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private func expansionChanged(_ open: Bool) {
        body.isHidden = !open
        if open { fadeInBody() }
        if let key { UserDefaults.standard.set(open, forKey: Self.defaultsKey(key)) }
        onLayoutChange?()
    }

    /// Opening fades the body in over `Motion.fast` (state is already final; reduced motion skips it).
    private func fadeInBody() {
        let d = Theme.Motion.duration(Theme.Motion.fast)
        guard d > 0, window != nil else { return }
        body.wantsLayer = true
        body.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = d
            ctx.timingFunction = Theme.Motion.Curve.easeOut.timingFunction
            body.animator().alphaValue = 1
        }
    }

    /// A section sits flush against its neighbors in a stack: the only thing between two sections is the header's one
    /// separator line, whatever spacing the stack gives its other children.
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let stack = superview as? NSStackView, stack.orientation == .vertical else { return }
        let siblings = stack.arrangedSubviews.filter { $0 !== self }
        if let previous = siblings.last { stack.setCustomSpacing(0, after: previous) }
        stack.setCustomSpacing(0, after: self)
    }

    /// Adds a row to the body, full width. A plain horizontal stack of buttons (an icon row, "Add Effect…") is snapped to
    /// the grid: first control in the label column, the grid's one gap between bounds, one row high.
    public func addRow(_ row: NSView) {
        if type(of: row) == NSStackView.self, let stack = row as? NSStackView, stack.orientation == .horizontal {
            stack.spacing = ControlsGrid.gap
            stack.edgeInsets.left = ControlsGrid.labelX; stack.edgeInsets.right = ControlsGrid.trailing
            stack.alignment = .centerY
            stack.heightAnchor.constraint(equalToConstant: ControlsGrid.rowHeight).isActive = true
        }
        body.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
}

/// One inspector property row (INTERACTION-AUDIT "InspectorRow") on the Effect Controls geometry: keyframe ring at
/// `ringX`, name at `nameX` (`nameWidth`), value control at `controlX` (`controlWidth`, `Row.control` high), keyframe
/// navigation trailing. One grid row high, no separator of its own. States: hover `State.rowHover`, `isSelected` `Selection.fill`,
/// `isEnabled = false` dims the name and disables the control.
public final class InspectorRow: NSView, ControlsRowProbing {
    public let nameLabel: NSTextField
    public let control: NSView?
    public var controlWidth: CGFloat { didSet { needsLayout = true } }
    public let keyframes: KeyframeControls?

    public var title: String {
        get { nameLabel.stringValue }
        set { nameLabel.stringValue = newValue }
    }
    public var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    public var isEnabled = true {
        didSet {
            nameLabel.textColor = isEnabled ? Theme.Colors.label2 : Theme.State.disabledText
            (control as? NSControl)?.isEnabled = isEnabled
            keyframes?.isEnabled = isEnabled
        }
    }
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    public init(title: String, control: NSView?, controlWidth: CGFloat = 72, keyframes: KeyframeControls? = nil) {
        nameLabel = NSTextField(labelWithString: title)
        self.control = control
        self.controlWidth = controlWidth
        self.keyframes = keyframes
        super.init(frame: .zero)
        nameLabel.font = Theme.Typography.body
        nameLabel.textColor = Theme.Colors.label2
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        if let control { addSubview(control); control.setAccessibilityLabel(title) }
        keyframes?.install(in: self)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.Inspector.rowHeight) }

    /// Row fill for the current state (nil = transparent).
    var backgroundFill: NSColor? {
        if isSelected { return Theme.Selection.fill }
        return hovering ? Theme.State.rowHover : nil
    }

    public override func layout() {
        super.layout()
        let h = bounds.height, lh = Theme.Inspector.labelHeight, ch = Theme.Row.control
        keyframes?.layout(rowBounds: bounds)
        nameLabel.frame = NSRect(x: ControlsGrid.labelX, y: ((h - lh) / 2).rounded(), width: Theme.Inspector.nameWidth, height: lh)
        if let control {
            let navW = keyframes == nil ? 0 : KeyframeNavigationView.width + ControlsGrid.gap
            let room = bounds.width - ControlsGrid.valueX - Theme.Inspector.trailing - navW
            control.frame = NSRect(x: ControlsGrid.valueX, y: ((h - ch) / 2).rounded(),
                                   width: max(min(gridWidth(of: control), room), 0), height: ch)
        }
    }

    /// The width the grid gives `control`: a number field is one value column, a stack of number fields (X and Y, with an
    /// optional icon after them) is that many columns with the grid's gap; anything else (popup, segmented control, font)
    /// fills the control column. ``controlWidth` only narrows other controls.
    private func gridWidth(of control: NSView) -> CGFloat {
        let slot = Theme.Inspector.iconSlot
        func fields(_ v: NSView) -> Int? {
            if v is ScrubField { return 1 }
            guard let s = v as? NSStackView, s.orientation == .horizontal, !s.arrangedSubviews.isEmpty,
                  s.arrangedSubviews.allSatisfy({ $0 is ScrubField }) else { return nil }
            s.spacing = ControlsGrid.gap
            s.distribution = .fillEqually
            return s.arrangedSubviews.count
        }
        func columns(_ n: Int) -> CGFloat { CGFloat(n) * ControlsGrid.valueWidth + CGFloat(n - 1) * ControlsGrid.gap }
        if let n = fields(control) { return columns(n) }
        if let outer = control as? NSStackView, outer.orientation == .horizontal, outer.arrangedSubviews.count == 2,
           let n = fields(outer.arrangedSubviews[0]) {
            outer.spacing = ControlsGrid.gap
            return columns(n) + ControlsGrid.gap + slot
        }
        // Choosers fill the one control column (no 120 here, 128 there); other controls keep their own, capped, width.
        if control is SQPopup || control is SQSegmented || control is NumericSlider { return ControlsGrid.controlColumnWidth }
        return min(controlWidth, ControlsGrid.controlColumnWidth)
    }

    public var rowProbe: ControlsRowProbe {
        ControlsRowProbe(label: nameLabel.frame, controls: control.map { [$0.frame] } ?? [])
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    /// Scrolling under a resting pointer sends no mouseExited: re-read the pointer on every scroll step (`ScrollHoverSync`).
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in self?.hovering = p != nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    /// Tests: apply a pointer position (window coordinates) as the scroll refresh would.
    func syncHover(atWindowPoint p: NSPoint) { hovering = ScrollHoverSync.pointer(over: self, atWindowPoint: p) != nil }
    var isHovered: Bool { hovering }

    public override func draw(_ dirtyRect: NSRect) {
        if let fill = backgroundFill { fill.setFill(); bounds.fill() }
        // No hairline: the only separator of a list of sections is the header's top line.
    }
}
