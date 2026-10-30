import AppKit

/// Tool column button that can hold variants (Premiere's grouped tools): a click picks the slot's current tool, holding
/// the mouse (or a right-click) opens the `variantItems` SQ menu. A small triangle in the corner marks a slot with variants.
final class TimelineToolSlotButton: NSButton {
    /// Variants of this slot; nil = a plain button.
    var variantItems: (() -> [SQMenuItem])? {
        didSet { needsDisplay = true }
    }
    /// Right-click and ctrl-click open the variants as SQ rows (no NSMenu).
    override func menu(for event: NSEvent) -> NSMenu? {
        if variantItems != nil, isEnabled { popUpVariants() }
        return nil
    }
    /// SQ tooltip, never the system one (see `SQButton.toolTip`).
    override var toolTip: String? {
        get { sqToolTip }
        set { sqToolTip = newValue }
    }
    static let holdDelay: TimeInterval = 0.45       // design v9: hold 450 ms

    /// How the button draws its state: `segment` = chip inside the tool track (selected-segment fill), `toggle` = glyph color
    /// only (no fill), `pill` = a text button on a quiet fill (Fit), `plain` = the older accent-tint chip.
    enum Style { case plain, segment, toggle, pill, tool, popup }
    var style: Style = .plain { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        guard variantItems != nil, isEnabled, let window else { super.mouseDown(with: event); return }
        let deadline = Date().addingTimeInterval(Self.holdDelay)
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline,
                                           inMode: .eventTracking, dequeue: true) else {
                popUpVariants()                                      // held: show the variants
                return
            }
            if e.type == .leftMouseUp {
                if bounds.contains(convert(e.locationInWindow, from: nil)) { sendAction(action, to: target) }
                return
            }
        }
    }

    private func popUpVariants() {
        guard let items = variantItems?(), !items.isEmpty else { return }
        SQContextMenu.popUp(items: items, below: self)       // v9: the options open below the tool
    }

    // Flat V1 Quiet drawing: no bezel; selected = accentTint fill, hover = faint fill.
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var contentTintColor: NSColor? { didSet { needsDisplay = true } }
    override var image: NSImage? { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = style == .pill ? bounds.height / 2 : (style == .segment || style == .toggle ? Theme.Radius.small : Theme.Radius.control)
        let box = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        switch style {
        case .plain:
            if state == .on { Theme.Colors.accentTint.setFill(); box.fill() }
            else if hovering { Theme.Colors.fill.setFill(); box.fill() }
        case .segment:
            if state == .on { Theme.State.selectedSegment.setFill(); box.fill() }
            else if hovering { Theme.State.rowHover.setFill(); box.fill() }
        case .tool:
            // v9 `.tbar .ibtn`: 28 x 28, radius 6, picked = `fillPressed`, hover = `fillHover`.
            if state == .on { Theme.Colors.fillPressed.setFill(); box.fill() }
            else if hovering { Theme.Colors.fillHover.setFill(); box.fill() }
        case .toggle:
            if hovering { Theme.Colors.fillHover.setFill(); box.fill() }
        case .popup:
            // v9 flat popup: no fill until hovered, 11 pt label, 12 pt chevron on the right.
            let flat = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            if hovering { Theme.Colors.fillHover.setFill(); flat.fill() }
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label]
            let sz = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: 10, y: bounds.midY - sz.height / 2), withAttributes: attrs)
            let cr = NSRect(x: bounds.maxX - 8 - 12, y: bounds.midY - 6, width: 12, height: 12)
            SQIcon.chevronDown.image(size: 12, color: Theme.Colors.label3).draw(in: cr)
            return
        case .pill:
            (hovering ? Theme.State.controlHover : Theme.Colors.fill).setFill(); box.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body,       // board .btn: 11
                                                        .foregroundColor: contentTintColor ?? Theme.Colors.label2]
            let sz = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
            return
        }
        let tint = contentTintColor ?? Theme.Colors.label2
        if let image {
            let size = image.size
            let r = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: r.integral)
        }
        guard variantItems != nil else { return }
        // v9 `.grp::after`: 4 pt triangle, 4 pt in from the right and bottom, t3 (t1 on the picked tool).
        let s: CGFloat = 4, r = bounds.insetBy(dx: 4, dy: 4)
        let bottom = isFlipped ? r.maxY : r.minY, up: CGFloat = isFlipped ? -s : s
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.maxX, y: bottom))
        p.line(to: NSPoint(x: r.maxX - s, y: bottom))
        p.line(to: NSPoint(x: r.maxX, y: bottom + up))
        p.close()
        (style == .tool ? (state == .on ? Theme.Colors.label : Theme.Colors.label3) : tint).setFill()
        p.fill()
    }
}
