import AppKit
import SSCore
import SSRender

/// Pure point editing for one curve (x ascending, 0…1). Interior points keep a minimum gap to their neighbours; the end
/// points only move vertically.
public enum CurveEditing {
    public static let minGap: Float = 0.01
    public static let hitRadius: CGFloat = 8

    /// Adds a point at (x, y); returns the new list and the index of the point.
    public static func add(_ pts: [CurvePoint], x: Float, y: Float) -> (points: [CurvePoint], index: Int) {
        var p = pts
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        let i = p.firstIndex { $0.x > cx } ?? p.count
        p.insert(CurvePoint(cx, cy), at: i)
        return (p, i)
    }

    public static func move(_ pts: [CurvePoint], index i: Int, to x: Float, _ y: Float) -> [CurvePoint] {
        guard pts.indices.contains(i) else { return pts }
        var p = pts
        let cy = min(max(y, 0), 1)
        if i == 0 || i == p.count - 1 {
            p[i].y = cy
        } else {
            let lo = p[i - 1].x + minGap, hi = p[i + 1].x - minGap
            p[i] = CurvePoint(min(max(x, lo), max(lo, hi)), cy)
        }
        return p
    }

    /// Interior points can be removed; the two end points stay.
    public static func remove(_ pts: [CurvePoint], index i: Int) -> [CurvePoint] {
        guard pts.count > 2, i > 0, i < pts.count - 1 else { return pts }
        var p = pts
        p.remove(at: i)
        return p
    }

    /// Index of the point within `radius` (in the same units as the coordinates) of (x, y), nearest first.
    public static func hit(_ pts: [CurvePoint], x: CGFloat, y: CGFloat, size: CGSize, radius: CGFloat = hitRadius) -> Int? {
        var best: (Int, CGFloat)?
        for (i, q) in pts.enumerated() {
            let d = hypot(CGFloat(q.x) * size.width - x, (1 - CGFloat(q.y)) * size.height - y)
            if d <= radius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}

/// RGB curve editor: one channel at a time. Click the curve area to add a point, drag to move, double-click a point to
/// remove it (the section's Reset restores the diagonal). One drag = one `onBegin` ... `onChange`* ... `onEnd`.
public final class CurveEditorView: NSView {
    public var points: [CurvePoint] = RGBCurves.diagonal { didSet { if points != oldValue { needsDisplay = true } } }
    public var lineColor: NSColor = Theme.Colors.label { didSet { needsDisplay = true } }
    /// RGB curves start on the diagonal; Hue Saturation Curves on the flat middle line (y = 0.5 = no change).
    public var flatBaseline = false { didSet { needsDisplay = true } }
    /// Optional colour strip along the bottom (the hue wheel for hue-keyed curves).
    public var hueStrip = false { didSet { needsDisplay = true } }
    public var onBegin: (() -> Void)?
    public var onChange: (([CurvePoint]) -> Void)?
    public var onEnd: (() -> Void)?

    private var dragIndex: Int?

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
            let colors = (0...12).map { NSColor(hue: CGFloat($0) / 12, saturation: 0.85, brightness: 0.9, alpha: 1) }
            NSGradient(colors: colors)?.draw(in: strip, angle: 0)
        }
        let diag = NSBezierPath()
        if flatBaseline {
            diag.move(to: NSPoint(x: r.minX, y: r.midY)); diag.line(to: NSPoint(x: r.maxX, y: r.midY))
        } else {
            diag.move(to: NSPoint(x: r.minX, y: r.maxY)); diag.line(to: NSPoint(x: r.maxX, y: r.minY))
        }
        Theme.white(0.2).setStroke()
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
            (i == dragIndex ? Theme.Colors.accent : Theme.white(0.92)).setFill()
            NSBezierPath(ovalIn: dot).fill()
            Theme.black(0.5).setStroke()
            NSBezierPath(ovalIn: dot).stroke()
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
            if let hit { onChange?(CurveEditing.remove(points, index: hit)) }
            onEnd?()
            return
        }
        onBegin?()
        let (x, y) = toData(p)
        if let hit { dragIndex = hit } else {
            let added = CurveEditing.add(points, x: x, y: y)
            dragIndex = added.index
            onChange?(added.points)
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        var (x, y) = toData(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift), points.indices.contains(i) { x = points[i].x }   // Shift locks x
        onChange?(CurveEditing.move(points, index: i, to: x, y))
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil || event.clickCount == 2 || event.modifierFlags.contains(.command) else { return }
        if dragIndex != nil { dragIndex = nil; onEnd?() }
        needsDisplay = true
    }
}
