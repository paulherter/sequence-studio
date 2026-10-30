import AppKit

/// The board's disclosure chevron (sq.css `.cv`): a 5 pt corner stroked 1.2 in `label3`, pointing right (closed) or
/// down (open). Draws only; the row handles the click.
public final class DisclosureGlyph: NSView {
    public var isOpen: Bool { didSet { needsDisplay = true } }

    public init(isOpen: Bool) {
        self.isOpen = isOpen
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let p = NSBezierPath()
        if isOpen {
            p.move(to: NSPoint(x: c.x - 4.0, y: c.y - 2.0)); p.line(to: NSPoint(x: c.x, y: c.y + 2.0)); p.line(to: NSPoint(x: c.x + 4.0, y: c.y - 2.0))
        } else {
            p.move(to: NSPoint(x: c.x - 2.0, y: c.y - 4.0)); p.line(to: NSPoint(x: c.x + 2.0, y: c.y)); p.line(to: NSPoint(x: c.x - 2.0, y: c.y + 4.0))
        }
        p.lineWidth = 1.2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        Theme.Colors.label3.setStroke(); p.stroke()
    }
}
