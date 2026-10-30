import AppKit
import SQCore
import SQRender

/// RGB curve editor: one channel at a time. Click the curve area to add a point, drag to move, double-click a point to
/// remove it (the section's Reset restores the diagonal). One drag = one `onBegin` ... `onChange`* ... `onEnd`.
/// Hover lights the point under the pointer; cursors: crosshair on the plot (a click adds a point), open hand on a point,
/// closed hand while dragging.
public final class CurveEditorView: NSView {
    public var points: [CurvePoint] = RGBCurves.diagonal {
        didSet { if points != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    }
    public var lineColor: NSColor = Theme.Colors.label { didSet { needsDisplay = true } }
    /// RGB curves start on the diagonal; Hue Saturation Curves on the flat middle line (y = 0.5 = no change).
    public var flatBaseline = false { didSet { needsDisplay = true } }
    /// Optional color strip along the bottom (the hue wheel for hue-keyed curves).
    public var hueStrip = false { didSet { needsDisplay = true } }
    public var onBegin: (() -> Void)?
    public var onChange: (([CurvePoint]) -> Void)?
    public var onEnd: (() -> Void)?

    private var dragIndex: Int?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Curve")
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var plot: NSRect { bounds.insetBy(dx: 6, dy: 6) }

    private func toData(_ p: NSPoint) -> (Float, Float) {
        let r = plot
        return (Float((p.x - r.minX) / max(r.width, 1)), Float(1 - (p.y - r.minY) / max(r.height, 1)))
    }

    private func toView(_ q: CurvePoint) -> NSPoint {
        let r = plot
        return NSPoint(x: r.minX + CGFloat(q.x) * r.width, y: r.minY + (1 - CGFloat(q.y)) * r.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let r = plot
        Theme.Colors.field.setFill()
        NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        Theme.Colors.fieldEdge.setStroke()
        let grid = NSBezierPath()
        for i in 1..<4 {
            let f = CGFloat(i) / 4
            grid.move(to: NSPoint(x: r.minX + f * r.width, y: r.minY)); grid.line(to: NSPoint(x: r.minX + f * r.width, y: r.maxY))
            grid.move(to: NSPoint(x: r.minX, y: r.minY + f * r.height)); grid.line(to: NSPoint(x: r.maxX, y: r.minY + f * r.height))
        }
        grid.lineWidth = 0.5
        grid.stroke()
        if hueStrip {
            let strip = NSRect(x: r.minX, y: r.maxY - 6, width: r.width, height: 6)
            let colors = (0...12).map { Theme.ColorBridge.hsb(CGFloat($0) / 12, 0.85, 0.9) }
            NSGradient(colors: colors)?.draw(in: strip, angle: 0)
        }
        let diag = NSBezierPath()
        if flatBaseline {
            diag.move(to: NSPoint(x: r.minX, y: r.midY)); diag.line(to: NSPoint(x: r.maxX, y: r.midY))
        } else {
            diag.move(to: NSPoint(x: r.minX, y: r.maxY)); diag.line(to: NSPoint(x: r.maxX, y: r.minY))
        }
        Theme.Colors.fieldEdge.setStroke()
        diag.lineWidth = 0.5
        diag.stroke()

        let curve = NSBezierPath()
        let n = 96
        for i in 0...n {
            let x = Float(i) / Float(n)
            let p = toView(CurvePoint(x, CurveMath.evaluate(points, x)))
            if i == 0 { curve.move(to: p) } else { curve.line(to: p) }
        }
        lineColor.setStroke()
        curve.lineWidth = 1.5
        curve.stroke()

        for (i, q) in points.enumerated() {
            let c = toView(q)
            let dot = NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
            (i == dragIndex ? Theme.Colors.accent : i == hoverIndex ? Theme.Colors.accentFill : Theme.Colors.label).setFill()
            NSBezierPath(ovalIn: dot).fill()
            Theme.OnPicture.shadow.setStroke()
            NSBezierPath(ovalIn: dot).stroke()
        }
    }

    // MARK: Hover and cursors

    private func pointIndex(at p: NSPoint) -> Int? {
        let r = plot
        return CurveEditing.hit(points, x: p.x - r.minX, y: p.y - r.minY, size: r.size)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverIndex = pointIndex(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    public override func resetCursorRects() {
        if dragIndex != nil { addCursorRect(bounds, cursor: .closedHand); return }
        addCursorRect(plot, cursor: .crosshair)
        let h = CurveEditing.hitRadius
        for q in points {
            let c = toView(q)
            addCursorRect(NSRect(x: c.x - h, y: c.y - h, width: 2 * h, height: 2 * h), cursor: .openHand)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        let r = plot
        let local = NSPoint(x: p.x - r.minX, y: p.y - r.minY)
        let hit = CurveEditing.hit(points, x: local.x, y: local.y, size: r.size)
        // Cmd-click (Premiere) or double-click removes an interior point.
        if event.clickCount == 2 || (event.modifierFlags.contains(.command) && hit != nil) {
            onBegin?()
            if let hit { edit(CurveEditing.remove(points, index: hit)) }
            onEnd?()
            return
        }
        onBegin?()
        let (x, y) = toData(p)
        if let hit { dragIndex = hit } else {
            let added = CurveEditing.add(points, x: x, y: y)
            dragIndex = added.index
            edit(added.points)
        }
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        var (x, y) = toData(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift), points.indices.contains(i) { x = points[i].x }   // Shift locks x
        edit(CurveEditing.move(points, index: i, to: x, y))
    }

    /// Shows an edit at once, then reports it. The owner writes the model's points back asynchronously; events that arrive
    /// before that must edit what is shown, not a stale list (a drag after adding a point moved an end point instead).
    private func edit(_ new: [CurvePoint]) {
        points = new
        onChange?(new)
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil || event.clickCount == 2 || event.modifierFlags.contains(.command) else { return }
        if dragIndex != nil { dragIndex = nil; onEnd?() }
        hoverIndex = pointIndex(at: convert(event.locationInWindow, from: nil))
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
