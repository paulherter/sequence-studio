import AppKit

// Small own-design building blocks of the export dialog (AppKit, V1 Quiet tokens). Closure based so the dialog code stays flat.

/// Popup that reports the chosen index. Items listed in `disabled` are shown dimmed and cannot be picked.
@MainActor
final class ClosurePopup: SQPopup {
    var onSelect: (@MainActor (Int) -> Void)?

    convenience init(items: [String], selected: Int, disabled: Set<Int> = [], width: CGFloat, onSelect: (@MainActor (Int) -> Void)? = nil) {
        self.init()
        self.onSelect = onSelect
        menu?.autoenablesItems = false
        for (i, t) in items.enumerated() {
            addItem(withTitle: SQL10n.localized(t))
            lastItem?.isEnabled = !disabled.contains(i)
        }
        if items.indices.contains(selected) { selectItem(at: selected) }
        target = self
        action = #selector(fire)
        boxHeight = Theme.Metrics.quietField
        frame = NSRect(x: 0, y: 0, width: width, height: Theme.Metrics.quietField)
    }

    @objc private func fire() { onSelect?(indexOfSelectedItem) }
}

@MainActor
final class ClosureSegmented: SQSegmented {
    var onSelect: (@MainActor (Int) -> Void)?

    convenience init(labels: [String], selected: Int, disabled: Set<Int> = [], segmentWidth: CGFloat = 64,
                     onSelect: (@MainActor (Int) -> Void)? = nil) {
        self.init(labels: labels.map { SQL10n.string($0) }, segmentWidth: segmentWidth)
        self.onSelect = onSelect
        for i in disabled { setEnabled(false, forSegment: i) }
        selectedSegment = selected
        target = self
        action = #selector(fire)
        sizeToFit()
    }

    @objc private func fire() { onSelect?(selectedSegment) }
}

@MainActor
final class ClosureCheckbox: SQCheckbox {
    var onToggle: (@MainActor (Bool) -> Void)?

    convenience init(title: String, on: Bool, enabled: Bool = true, onToggle: (@MainActor (Bool) -> Void)? = nil) {
        self.init(title: SQL10n.string(title), target: nil, action: nil)
        self.onToggle = onToggle
        state = on ? .on : .off
        isEnabled = enabled
        target = self
        action = #selector(fire)
        sizeToFit()
    }

    @objc private func fire() { onToggle?(state == .on) }
}

/// A clickable row of the sequence list (selection background, hover).
@MainActor
final class ExportListRow: NSView {
    var onSelect: (@MainActor () -> Void)?
    /// Board shows no selection fill in the list (the checkbox is the state); kept for the click target only.
    var isSelected = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

/// The preview picture: aspect-fit image on the viewer background, a short text when nothing can be shown.
@MainActor
final class ExportPictureView: NSView {
    var onClick: (@MainActor () -> Void)?
    private let note = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.viewer.cgColor
        layer?.cornerRadius = Theme.Radius.control
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspect
        note.font = Theme.Typography.body
        note.textColor = Theme.Colors.label3
        note.alignment = .center
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.cell?.wraps = true
        note.isHidden = true
        addSubview(note)
        setAccessibilityRole(.image)
        setAccessibilityLabel(SQL10n.string("Export preview"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func layout() {
        super.layout()
        let lh = ceil(Theme.Typography.body.ascender - Theme.Typography.body.descender + Theme.Typography.body.leading)
        note.frame = NSRect(x: Theme.Spacing.md, y: bounds.midY - lh, width: bounds.width - 2 * Theme.Spacing.md, height: lh * 2)
    }

    func show(image: CGImage?, note text: String?) {
        layer?.contents = image
        note.stringValue = text ?? ""
        note.isHidden = text == nil
    }
}

/// Scrub strip under the preview: thin track, accent progress, round playhead. Click or drag to scrub.
@MainActor
final class ExportScrubBar: NSView {
    var onScrub: (@MainActor (Double) -> Void)?
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    private let inset: CGFloat = Theme.Spacing.sm

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func f(_ e: NSEvent) -> Double {
        let x = convert(e.locationInWindow, from: nil).x
        return min(max(Double((x - inset) / max(bounds.width - 2 * inset, 1)), 0), 1)
    }
    override func mouseDown(with event: NSEvent) { if isEnabled { onScrub?(f(event)) } }
    override func mouseDragged(with event: NSEvent) { if isEnabled { onScrub?(f(event)) } }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width - 2 * inset
        let track = NSRect(x: inset, y: bounds.midY - 2, width: w, height: 4)
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: track, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        guard isEnabled else { return }
        let x = inset + w * CGFloat(fraction)
        Theme.Colors.accentFill.setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: track.minY, width: max(x - inset, 0), height: 4), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        Theme.Colors.label.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 5, y: bounds.midY - 5, width: 10, height: 10)).fill()
    }
}

/// One settings row of the Export dialog (board: 24 pt, label column at x 28 / 92 wide, controls from x 128 to the right
/// edge minus 12). Items with `width == nil` share the remaining room; a row never wraps.
@MainActor
final class ExportSettingRow: NSView {
    struct Item {
        let view: NSView
        let width: CGFloat?
        /// A control not laid out yet (a button made a moment ago) has frame width 0: its intrinsic width counts, so it never
        /// shrinks to a sliver under the hint next to it.
        static func fixed(_ v: NSView, _ w: CGFloat? = nil) -> Item {
            let intrinsic = v.intrinsicContentSize.width
            return Item(view: v, width: w ?? max(v.frame.width, intrinsic == NSView.noIntrinsicMetric ? 0 : intrinsic, 1))
        }
        static func fill(_ v: NSView) -> Item { Item(view: v, width: nil) }
    }

    static let labelX: CGFloat = 25
    static let labelW: CGFloat = 92
    static let controlX: CGFloat = 128
    static let trailing: CGFloat = 12

    private let label: NSTextField
    private let items: [Item]
    /// The row's label (tests list the options with it).
    var title: String { label.stringValue }

    init(title: String, items: [Item], dimmed: Bool = false) {
        label = NSTextField(labelWithString: SQL10n.string(title))
        self.items = items
        super.init(frame: .zero)
        label.font = Theme.Typography.body
        label.textColor = dimmed ? Theme.Colors.label3 : Theme.Colors.label2
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        for i in items { addSubview(i.view) }
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// One property-row pitch for every row (design pass; the board had 28 for rows with a popup, segmented control or field).
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.Row.property) }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Self.labelX, y: ((h - lh) / 2).rounded(), width: Self.controlX - Self.labelX - Theme.Spacing.xs, height: lh)
        let gap = Theme.Spacing.sm
        let room = bounds.width - Self.controlX - Self.trailing
        let fixed = items.reduce(CGFloat(0)) { $0 + ($1.width ?? 0) } + gap * CGFloat(max(items.count - 1, 0))
        let flexible = max(items.filter { $0.width == nil }.count, 1)
        let share = max((room - fixed) / CGFloat(flexible), 20)
        var x = Self.controlX
        for i in items {
            let w = i.width ?? share
            let vh: CGFloat = (i.view is NSTextField && !(i.view is SQTextField)) ? ceil(i.view.intrinsicContentSize.height) : Theme.Metrics.quietField
            let ch = i.view is SQCheckbox ? max(i.view.frame.height, 16) : vh
            i.view.frame = NSRect(x: x, y: ((h - ch) / 2).rounded(), width: w, height: ch)
            x += w + gap
        }
    }
}

/// Single-line field as a capsule (board: radius = half the height). Optional fixed suffix (the ".mp4" of the file name).
@MainActor
final class ExportCapsuleField: SQTextField {
    let suffixLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        suffixLabel.font = Theme.Typography.body
        suffixLabel.textColor = Theme.Colors.label3
        suffixLabel.isHidden = true
        addSubview(suffixLabel)
        lineBreakMode = .byTruncatingMiddle
    }
    required init?(coder: NSCoder) { fatalError() }

    var suffix: String = "" {
        didSet { suffixLabel.stringValue = suffix; suffixLabel.isHidden = suffix.isEmpty; needsLayout = true }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        guard !suffix.isEmpty else { return }
        let textW = ((currentEditor()?.string ?? stringValue) as NSString).size(withAttributes: [.font: font ?? Theme.Typography.body]).width
        let lh = ceil(suffixLabel.intrinsicContentSize.height)
        let x = min(SQTextFieldCell.inset + Theme.Spacing.xs + ceil(textW) + 1, max(bounds.width - suffixLabel.intrinsicContentSize.width - Theme.Spacing.sm, 0))
        suffixLabel.frame = NSRect(x: x, y: ((bounds.height - lh) / 2).rounded(), width: suffixLabel.intrinsicContentSize.width, height: lh)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}
