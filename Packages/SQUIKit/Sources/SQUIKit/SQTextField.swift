import AppKit

public final class SQTextFieldCell: NSTextFieldCell {
    public static let inset: CGFloat = 6
    private func padded(_ r: NSRect) -> NSRect {
        let h = min(Theme.Metrics.quietField, r.height)
        let box = NSRect(x: r.minX + Self.inset, y: r.minY + ((r.height - h) / 2).rounded(), width: max(r.width - Self.inset * 2, 0), height: h)
        let th = cellSize(forBounds: box).height
        return NSRect(x: box.minX, y: box.minY + max(((h - th) / 2).rounded(), 0), width: box.width, height: min(th, h))
    }
    public override func drawingRect(forBounds rect: NSRect) -> NSRect { padded(rect) }
    public override func titleRect(forBounds rect: NSRect) -> NSRect { padded(rect) }
    public override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: padded(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    public override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: padded(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// Text field (design artifact v11, sq.css `.fld`): capsule 22 high, `field` fill, .5 px `fieldEdge`, hover 1 px white .18,
/// focus inner 1.5 px accent line, 11 pt `label`, 6 pt inset, no system bezel.
/// A drop-in NSTextField subclass (`stringValue`, delegate, target/action unchanged).
open class SQTextField: NSTextField {
    open override class var cellClass: AnyClass? {
        get { SQTextFieldCell.self }
        set { _ = newValue }
    }

    public convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        if !(cell is SQTextFieldCell) {
            let old = cell as? NSTextFieldCell
            let c = SQTextFieldCell(textCell: stringValue)
            c.isEditable = old?.isEditable ?? true
            c.isSelectable = true
            cell = c
        }
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = Theme.Typography.body
        textColor = Theme.Colors.label
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = Theme.Colors.field.cgColor
        layer?.borderColor = edgeColor.cgColor
        layer?.borderWidth = edgeWidth
        alphaValue = isEnabled ? 1 : Theme.State.disabledAlpha
    }

    // Hover (INTERACTION-AUDIT §7): tracked so the box shows the hover state.
    private(set) var isHovered = false { didSet { if oldValue != isHovered { hoverChanged() } } }
    private var hoverArea: NSTrackingArea?
    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    open override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); isHovered = true }
    open override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); isHovered = false }
    private func hoverChanged() { layer?.borderColor = edgeColor.cgColor; layer?.borderWidth = edgeWidth }
    private var isFocused: Bool { currentEditor() != nil }
    /// Edge per state (design v7): focused `focusLine` (1.5 px, inside the layer bounds), hover `fieldEdgeHover` (1 px),
    /// no frame at rest.
    /// Error state: the entry cannot be used. A red 1.5 px edge, also while focused, until the text is valid again.
    public var isInvalid = false { didSet { if oldValue != isInvalid { hoverChanged() } } }
    var edgeColor: NSColor {
        if isInvalid { return Theme.Colors.red }
        if isFocused { return Theme.State.focusLine }
        return isHovered && isEnabled && isEditable ? Theme.Colors.fieldEdgeHover : .clear
    }
    var edgeWidth: CGFloat {
        if isInvalid { return Theme.State.focusLineWidth }
        if isFocused { return Theme.State.focusLineWidth }
        return isHovered && isEnabled && isEditable ? 1 : 0
    }
    open override func layout() {
        super.layout()
        layer?.cornerRadius = min(Theme.Radius.control, bounds.height / 2)
    }
    open override var isEnabled: Bool { didSet { applyColors() } }
    open override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { layer?.borderColor = (isInvalid ? Theme.Colors.red : Theme.State.focusLine).cgColor; layer?.borderWidth = Theme.State.focusLineWidth }
        return ok
    }
    open override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        layer?.borderColor = edgeColor.cgColor
        layer?.borderWidth = edgeWidth
    }

    open override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: Theme.Metrics.quietField)
    }
}
