import AppKit
import SQCore

/// The window of the selected Color Step on the Program monitor (Color page, Pro grade): its outline with a center
/// handle, edge handles that resize, a rotate handle and the body to move it. Same pattern as `ZoomEditOverlayView`:
/// pure drawing and event routing, maths in `StepWindowEditGeometry`. The host writes each change into the Step; one
/// drag = one undo step. Clicks that hit no handle and not the body pass through to the monitor below.
@MainActor
public final class StepWindowOverlayView: NSView {
    public enum Phase: Sendable { case began, changed, ended }

    public var geometry = StepWindowEditGeometry(layer: ZoomEditGeometry(layer: TransformOverlayGeometry(
        sequenceSize: CGSize(width: 1920, height: 1080), viewRect: .zero, mediaAspect: 16.0 / 9, transform: .identity))) {
        didSet { needsDisplay = true; invalidateHandleCursors() }
    }
    public var stepWindow = StepWindow() {
        didSet { needsDisplay = true; invalidateHandleCursors() }
    }
    /// The window changed (live): the host writes it into the Step.
    public var onChange: ((Phase, StepWindow) -> Void)?
    public var isDragging: Bool { drag != nil }

    private var drag: (hit: StepWindowEditGeometry.Hit, press: CGPoint, base: StepWindow)?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func invalidateHandleCursors() { window?.invalidateCursorRects(for: self) }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard drag != nil || geometry.hitTest(convert(point, from: superview), stepWindow) != nil else { return nil }
        return self
    }

    // MARK: Events

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = geometry.hitTest(p, stepWindow) else { return }
        drag = (hit, p, stepWindow)
        onChange?(.began, stepWindow)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        stepWindow = geometry.dragged(d.hit, from: d.press, to: p, base: d.base)
        onChange?(.changed, stepWindow)
    }

    public override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        onChange?(.ended, stepWindow)
    }

    public override func resetCursorRects() {
        guard geometry.layer.layer.fittedSize.width > 0 else { return }
        let r: CGFloat = 8
        func cursor(_ p: CGPoint, _ c: NSCursor) {
            addCursorRect(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), cursor: c)
        }
        cursor(geometry.rotatePoint(stepWindow), .crosshair)
        for e in StepWindowEditGeometry.Edge.allCases {
            if let p = geometry.edgePoint(e, stepWindow) { cursor(p, .crosshair) }
        }
        cursor(geometry.centerPoint(stepWindow), .openHand)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let w = stepWindow
        let pts = geometry.outline(w)
        guard pts.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.line(to: $0) }
        if w.shape != .linear { path.close() }
        Theme.OnPicture.shadow.setStroke(); path.lineWidth = 3; path.stroke()
        Theme.Colors.accent.setStroke(); path.lineWidth = 1.5; path.stroke()

        func dot(_ p: CGPoint, filled: Bool) {
            let h = NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            (filled ? Theme.Colors.accent : Theme.OnPicture.stroke).setFill(); h.fill()
            Theme.OnPicture.shadow.setStroke(); h.lineWidth = 1; h.stroke()
        }
        for e in StepWindowEditGeometry.Edge.allCases { if let p = geometry.edgePoint(e, w) { dot(p, filled: true) } }
        let c = geometry.centerPoint(w), r = geometry.rotatePoint(w)
        let stalk = NSBezierPath()
        stalk.move(to: c); stalk.line(to: r)
        Theme.OnPicture.guide.setStroke(); stalk.lineWidth = 1; stalk.stroke()
        dot(r, filled: false)
        dot(c, filled: true)
    }
}
