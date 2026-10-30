import AppKit

/// The SQPopup box (capsule, title, one chevron) without NSPopUpButton: the rows are `SQMenuItem`s built when it opens.
/// `image` only (no title) gives the "..." button of a panel header.
@MainActor
public final class SQMenuPopup: NSControl {
    public var title = "" { didSet { if title != oldValue { refresh() } } }
    public var image: NSImage? { didSet { refresh() } }
    /// Rows shown below the box on click.
    public var itemsProvider: (() -> [SQMenuItem])?
    public var boxHeight: CGFloat = Theme.Metrics.quietButton { didSet { invalidateIntrinsicContentSize() } }
    /// True: as wide as the current title, not a stable form width.
    public var sizesToTitle = true { didSet { invalidateIntrinsicContentSize() } }
    /// v9 `.pop.flat`: no box at rest, `fillHover` under the pointer (panel headers, top bar).
    public var isFlat = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var isTracking = false
    private var hoverArea: NSTrackingArea?

    public override init(frame: NSRect) { super.init(frame: frame); setup() }
    public convenience init() { self.init(frame: .zero) }
    public required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        font = Theme.Typography.body
        focusRingType = .none
        setAccessibilityRole(.popUpButton)
    }

    public override var isEnabled: Bool { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { false }

    private func refresh() {
        needsDisplay = true
        invalidateIntrinsicContentSize()
        setAccessibilityValue(title)
    }

    public override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    public override var intrinsicContentSize: NSSize {
        let f = font ?? Theme.Typography.body
        var w = (title as NSString).size(withAttributes: [.font: f]).width
        if let image { w += image.size.width + (title.isEmpty ? 0 : 4) }
        if !sizesToTitle { w = max(w, 56) }
        let titleInset = title.isEmpty && image != nil ? SQPopup.chevronInset : SQPopup.titleInset
        return NSSize(width: ceil(titleInset + w + SQPopup.chevronGap + SQPopup.chevronSize.width + SQPopup.chevronInset), height: boxHeight)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }
    public override var acceptsFirstResponder: Bool { isEnabled }

    public override func mouseDown(with event: NSEvent) { open() }
    public override func performClick(_ sender: Any?) { open() }
    public override func accessibilityPerformPress() -> Bool { open(); return true }

    func open() {
        guard isEnabled, let items = itemsProvider?(), !items.isEmpty else { return }
        isTracking = true; needsDisplay = true
        SQContextMenu.popUp(items: items, at: NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
        SQAfterEvent.run { self.isTracking = false; self.needsDisplay = true }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let h = min(boxHeight, bounds.height)
        let box = NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
        let rest: NSColor? = isFlat ? nil : Theme.Colors.fill
        let fill = isTracking ? Theme.Colors.fillPressed : (isHovered && isEnabled ? Theme.Colors.fillHover : rest)
        let dim = isEnabled ? 1 : Theme.State.disabledAlpha
        if let fill {
            fill.withAlphaComponent(fill.alphaComponent * dim).setFill()
            ControlShape.capsule(box).fill()
        }
        let fg = Theme.Colors.label.withAlphaComponent(Theme.Colors.label.alphaComponent * dim)
        let chevronW = SQPopup.chevronSize.width
        let cr = NSRect(x: box.maxX - SQPopup.chevronInset - chevronW, y: (box.midY - SQPopup.chevronSize.height / 2).rounded(),
                        width: chevronW, height: SQPopup.chevronSize.height)
        SQPopup.drawChevron(in: cr, color: SQPopup.chevronColor.withAlphaComponent(dim))
        var x = box.minX + (title.isEmpty && image != nil ? SQPopup.chevronInset : SQPopup.titleInset)
        if let img = image {
            let s = img.size
            SQButton.tinted(img, fg).draw(in: NSRect(x: x, y: (box.midY - s.height / 2).rounded(), width: s.width, height: s.height),
                                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += s.width + 4
        }
        guard !title.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? Theme.Typography.body, .foregroundColor: fg, .paragraphStyle: style]
        let t = title as NSString
        let th = t.size(withAttributes: attrs).height
        let rect = NSRect(x: x, y: (box.midY - th / 2).rounded(), width: max(box.maxX - SQPopup.chevronInset - chevronW - SQPopup.chevronGap - x, 0), height: th)
        t.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        if ControlShape.isFocused(self) { ControlShape.drawFocusLine(in: box, radius: ControlShape.radius(box)) }
    }
}
