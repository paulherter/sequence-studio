import AppKit

/// Search field (design artifact v11, sq.css `.fld` / `.srch`): capsule 22 high, `field` fill, .5 px `fieldEdge`, magnifier 12 pt
/// `label3`; hover = 1 px white .18 edge, focus = inner 1.5 px accent line. A drop-in NSSearchField subclass (delegate, `sendsSearchStringImmediately`, target/action keep working);
/// only the bezel is ours, so editing, the cancel button and recents stay system behavior.
open class SQSearchField: NSSearchField {
    open override class var cellClass: AnyClass? {
        get { SQSearchFieldCell.self }
        set { _ = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        if !(cell is SQSearchFieldCell) { cell = SQSearchFieldCell(textCell: "") }
        font = Theme.Typography.body
        textColor = Theme.Colors.label
        focusRingType = .none
        drawsBackground = false
        isBezeled = false
        isBordered = false
        (cell as? NSSearchFieldCell)?.searchButtonCell?.image = Theme.symbol(.search, size: 12)
            .map { SQButton.tinted($0, Theme.Colors.label3) }
        (cell as? NSSearchFieldCell)?.searchButtonCell?.alternateImage = nil
        (cell as? NSTextFieldCell)?.placeholderAttributedString = nil
    }

    /// Placeholder in `label3`.
    public func setQuietPlaceholder(_ s: String) {
        placeholderAttributedString = NSAttributedString(string: s, attributes: [.font: Theme.Typography.body,
                                                                                 .foregroundColor: Theme.Colors.label3])
    }

    open override var placeholderString: String? {
        get { placeholderAttributedString?.string }
        set { setQuietPlaceholder(newValue ?? "") }
    }

    open override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: Theme.Metrics.quietField)
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
    private func hoverChanged() { needsDisplay = true }
}

final class SQSearchFieldCell: NSSearchFieldCell {
    /// Text line centered in the capsule (the system rect sits a few points high in a 22 pt box).
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        let lineHeight = ceil((font ?? Theme.Typography.body).boundingRectForFont.height)
        r.size.height = lineHeight
        r.origin.y = rect.minY + ((rect.height - lineHeight) / 2).rounded()
        return r
    }
    // The field editor is placed by the cell from the rect it is handed. AppKit hands it the whole capsule, which left the editor
    // (and with it the placeholder and the first typed character) at the top-left corner of the field when it was clicked. Hand
    // it the centered text line instead, so idle and editing geometry are the same.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: Self.editorRect(rect, searchTextRect(forBounds: rect)), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: Self.editorRect(rect, searchTextRect(forBounds: rect)), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
    /// The rect to hand to AppKit: the text line when `rect` is the whole capsule, unchanged when AppKit already passed a line.
    static func editorRect(_ rect: NSRect, _ line: NSRect) -> NSRect { rect.height > line.height + 1 ? line : rect }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let h = min(Theme.Metrics.quietField, cellFrame.height)
        let outer = NSRect(x: cellFrame.minX, y: cellFrame.minY + ((cellFrame.height - h) / 2).rounded(), width: cellFrame.width, height: h)
        let p = ControlShape.capsule(outer)
        Theme.Colors.fill2.setFill()       // board `.fld.ph0`: every search field is the quiet kind
        p.fill()
        let focused = controlView.window?.firstResponder is NSText
            && (controlView.window?.firstResponder as? NSText)?.delegate === controlView
        let hovered = (controlView as? SQSearchField)?.isHovered == true
        if focused {
            ControlShape.drawFocusLine(in: outer, radius: ControlShape.radius(outer))
        } else if hovered {
            // Design v7: no frame at rest, the hover shows as a slightly lighter body.
            Theme.State.controlHover.setFill()
            p.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}
