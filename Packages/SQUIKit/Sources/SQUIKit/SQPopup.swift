import AppKit

/// Popup (design artifact v11, sq.css `.pop`): the SQButton capsule (22 high, `fill`, hover `fillHover`) with the
/// selected title in 11 pt `label` and ONE down chevron (7x10, 1.2 stroke, gray) 7 pt from the right edge.
/// A drop-in NSPopUpButton subclass: menus, `selectItem`, pull-down mode and target/action are untouched; only the
/// drawing is ours. A pull-down shows item 0 as its title (AppKit's convention).
open class SQPopup: NSPopUpButton {
    public var boxHeight: CGFloat = Theme.Metrics.quietButton { didSet { invalidateIntrinsicContentSize() } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    var isTracking = false
    /// v9 `.pop.flat`: no box at rest, `fillHover` under the pointer (the workspace popup in the top bar).
    public var isFlat = false { didSet { needsDisplay = true } }
    /// SQ rows built by the owner each time the popup opens (set: they replace the NSMenu; item 0 of a pull-down still carries the title).
    public var sqItems: (() -> [SQMenuItem])?

    public override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        setup()
    }
    public convenience init() { self.init(frame: .zero, pullsDown: false) }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        font = Theme.Typography.body
        focusRingType = .none
    }

    open override var bezelStyle: NSButton.BezelStyle {
        get { super.bezelStyle }
        set { _ = newValue }   // the system bezel never comes back; we draw the box ourselves
    }
    open override var isBordered: Bool {
        get { super.isBordered }
        set { super.isBordered = false }
    }

    /// Chevron slot (sq.css `.pop:after`: 7 x 10, 8 pt gap to the title, 7 pt from the right edge).
    public static let chevronSize = NSSize(width: 7, height: 10)
    static let chevronGap: CGFloat = 8
    static let chevronInset: CGFloat = 7
    static let titleInset: CGFloat = 10

    /// The one down chevron, stroked 1.2 round, `#999` like the board (drawn, not a symbol, so it is exactly 7 x 10).
    public static func drawChevron(in r: NSRect, color: NSColor) {
        let p = NSBezierPath()
        // Points down in either coordinate system (the popup is drawn flipped inside the flipped panels).
        let d: CGFloat = (NSGraphicsContext.current?.isFlipped ?? false) ? -1 : 1
        p.move(to: NSPoint(x: r.minX + 1.2, y: r.midY + 1.1 * d))
        p.line(to: NSPoint(x: r.minX + 3.5, y: r.midY - 1.2 * d))
        p.line(to: NSPoint(x: r.minX + 5.8, y: r.midY + 1.1 * d))
        p.lineWidth = 1.2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }
    public static let chevronColor = Theme.Colors.chevron

    /// The text the box shows.
    open var displayTitle: String {
        if pullsDown { return itemArray.first?.title ?? "" }
        return titleOfSelectedItem ?? ""
    }

    var displayImage: NSImage? {
        pullsDown ? itemArray.first?.image : selectedItem?.image
    }

    /// True: the box is as wide as its current title (board `.pop` in a panel header: "Main", "C2147.MP4"), not as the widest
    /// entry of the menu. The default keeps one stable width for forms.
    public var sizesToTitle = false {
        didSet { if sizesToTitle != oldValue { invalidateIntrinsicContentSize() } }
    }
    open override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true                    // a frame-based host (the tab strip) lays out again
    }

    open override var intrinsicContentSize: NSSize {
        let font = font ?? Theme.Typography.body
        var widest: CGFloat = 0
        if sizesToTitle {
            widest = (displayTitle as NSString).size(withAttributes: [.font: font]).width
            if let img = displayImage { widest += img.size.width + 4 }
        } else {
            for item in itemArray.prefix(64) where !item.isSeparatorItem {
                widest = max(widest, (item.title as NSString).size(withAttributes: [.font: font]).width)
            }
        }
        return NSSize(width: ceil(Self.titleInset + widest + Self.chevronGap + Self.chevronSize.width + Self.chevronInset), height: boxHeight)
    }

    /// Fits the custom-drawn box (the cell's own size would be the system control's).
    open override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    open override func mouseEntered(with event: NSEvent) { isHovered = true }
    open override func mouseExited(with event: NSEvent) { isHovered = false }
    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTracking = true; needsDisplay = true
        if let sqItems {
            SQContextMenu.popUp(items: sqItems(), below: self)
            SQAfterEvent.run { self.isTracking = false; self.needsDisplay = true }
            return
        }
        if SQContextMenu.popUp(button: self) {
            SQAfterEvent.run { self.isTracking = false; self.needsDisplay = true }
            return
        }
        super.mouseDown(with: event)   // native fallback: runs the menu modally
        isTracking = false; needsDisplay = true
    }
    private func selectionChanged() {
        needsDisplay = true
        if sizesToTitle { invalidateIntrinsicContentSize() }
    }
    open override func select(_ item: NSMenuItem?) { super.select(item); selectionChanged() }
    open override func selectItem(at index: Int) { super.selectItem(at: index); selectionChanged() }
    open override func selectItem(withTitle title: String) { super.selectItem(withTitle: title); selectionChanged() }
    open override func selectItem(withTag tag: Int) -> Bool {
        let ok = super.selectItem(withTag: tag); selectionChanged(); return ok
    }

    open override func draw(_ dirtyRect: NSRect) {
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
        let chevronW = Self.chevronSize.width
        let cr = NSRect(x: box.maxX - Self.chevronInset - chevronW, y: (box.midY - Self.chevronSize.height / 2).rounded(),
                        width: chevronW, height: Self.chevronSize.height)
        Self.drawChevron(in: cr, color: Self.chevronColor.withAlphaComponent(dim))
        var x = box.minX + Self.titleInset
        if let img = displayImage {
            let s = img.size
            SQButton.tinted(img, fg).draw(in: NSRect(x: x, y: (box.midY - s.height / 2).rounded(), width: s.width, height: s.height),
                                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += s.width + 4
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? Theme.Typography.body, .foregroundColor: fg, .paragraphStyle: style]
        let title = displayTitle as NSString
        let th = title.size(withAttributes: attrs).height
        let textRect = NSRect(x: x, y: (box.midY - th / 2).rounded(), width: max(box.maxX - Self.chevronInset - chevronW - Self.chevronGap - x, 0), height: th)
        title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        if ControlShape.isFocused(self) { ControlShape.drawFocusLine(in: box, radius: ControlShape.radius(box)) }
    }
}
