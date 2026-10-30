import AppKit

/// On/off box (design artifact v11, sq.css `.chk`), replaces NSSwitch and `power.circle.fill`: 14×14, radius 4.
/// Off: `fill` with a .5 px `fieldEdge` (hover `fillHover`, pressed `fillPressed`). On: `accentFill` + white 1.5 pt checkmark.
/// Disabled draws at `disabledAlpha`, keyboard focus is the inner 1.5 px accent line. An optional title is drawn 6 pt right of the box.
/// A drop-in NSButton subclass (`state`, target/action, `.switch` type), custom-drawn.
open class SQCheckbox: NSButton {
    public convenience init(title: String = "", target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
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
        setButtonType(.switch)
        isBordered = false
        font = Theme.Typography.body
        focusRingType = .none
    }

    open override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    open override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    open override var isEnabled: Bool { didSet { needsDisplay = true } }
    open override var isHighlighted: Bool { didSet { needsDisplay = true } }

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

    open override var intrinsicContentSize: NSSize {
        let side = Theme.Metrics.checkbox
        guard !title.isEmpty else { return NSSize(width: side, height: side) }
        let w = (title as NSString).size(withAttributes: [.font: font ?? Theme.Typography.body]).width
        return NSSize(width: ceil(side + 6 + w), height: max(side, Theme.Metrics.capsule))
    }

    /// Fits the custom-drawn box (the cell's own size would be the system control's).
    open override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    /// The 14×14 box: left aligned, vertically centered.
    var boxRect: NSRect {
        let s = Theme.Metrics.checkbox
        return NSRect(x: 0, y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
    }

    /// Box fill: on = `accentFill` (hover / pressed brighten like the board's filter), off = `fill` / `fillHover` / `fillPressed`.
    var boxFill: NSColor {
        let pressed = isHighlighted
        if state == .on {
            let base = Theme.Colors.accentFill
            if pressed { return base.blended(withFraction: 0.35, of: .white) ?? base }
            return isHovered && isEnabled ? (base.blended(withFraction: 0.2, of: .white) ?? base) : base
        }
        return pressed ? Theme.Colors.fillPressed : (isHovered && isEnabled ? Theme.Colors.fillHover : Theme.Colors.fill)
    }

    open override func draw(_ dirtyRect: NSRect) {
        let box = boxRect
        let path = NSBezierPath(roundedRect: box, xRadius: Theme.Radius.checkbox, yRadius: Theme.Radius.checkbox)
        let alpha: CGFloat = isEnabled ? 1 : Theme.State.disabledAlpha
        boxFill.withAlphaComponent(boxFill.alphaComponent * alpha).setFill()
        path.fill()
        if state == .on {
            // Drawn into an unflipped (y up) image and composited with respectFlipped, so AppKit resolves the
            // host orientation (plain, flipped parent, layer-backed) instead of this code guessing it.
            let size = box.size
            let mark = NSImage(size: size, flipped: false) { r in
                let check = NSBezierPath()
                check.move(to: NSPoint(x: r.minX + r.width * 0.24, y: r.maxY - r.height * 0.52))
                check.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.maxY - r.height * 0.72))
                check.line(to: NSPoint(x: r.minX + r.width * 0.78, y: r.maxY - r.height * 0.30))
                check.lineWidth = 1.5
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.withAlphaComponent(alpha).setStroke()
                check.stroke()
                return true
            }
            mark.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), xRadius: Theme.Radius.checkbox, yRadius: Theme.Radius.checkbox)
            // Design v7 `.sw`: inset .5 px strong line (follows Contrast).
            Theme.Colors.trackHeaderLine.withAlphaComponent(Theme.Colors.trackHeaderLine.alphaComponent * alpha).setStroke()
            edge.lineWidth = 0.5
            edge.stroke()
            if state == .mixed {
                // Multi-select with differing values: a short dash, no check.
                let dash = NSRect(x: box.minX + box.width * 0.27, y: box.midY - 0.75, width: box.width * 0.46, height: 1.5)
                Theme.Colors.label.withAlphaComponent(alpha).setFill()
                dash.fill()
            }
        }
        if ControlShape.isFocused(self) { ControlShape.drawFocusLine(in: box, radius: Theme.Radius.checkbox) }
        guard !title.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? Theme.Typography.body,
                                                    .foregroundColor: isEnabled ? Theme.Colors.label : Theme.Colors.label3]
        let ts = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: Theme.Metrics.checkbox + 6, y: ((bounds.height - ts.height) / 2).rounded()),
                                 withAttributes: attrs)
    }
}
