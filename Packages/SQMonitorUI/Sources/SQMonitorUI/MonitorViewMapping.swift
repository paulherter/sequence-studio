import CoreGraphics
import Foundation
import SQCore
import SQText
import SQRender

// MonitorViewMapping (the canvas rect, pan and zoom reducers) lives in SQDrawMonitor; the Windows monitor shares it.

/// Type tool: where a click in the Program monitor puts the new text's center.
public enum TypeToolPlacement {
    /// Position (sequence px from the canvas center) for a click at `p`; nil when the click is outside the canvas.
    /// The text's center is clamped so it always lands on the canvas.
    public static func position(forClick p: CGPoint, mapping m: MonitorViewMapping) -> Vec2? { m.clickPosition(p) }

    /// Type tool drag from `a` to `b`: the box (center from the canvas center, size in sequence px) clipped to the
    /// canvas; nil for a drag shorter than `minDrag` points in both directions (that is a click) or one outside the canvas.
    public static func box(from a: CGPoint, to b: CGPoint, mapping m: MonitorViewMapping, minDrag: CGFloat) -> (Vec2, TextBox)? {
        guard abs(b.x - a.x) >= minDrag || abs(b.y - a.y) >= minDrag else { return nil }
        let r = m.canvasRect
        let drag = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let clipped = drag.intersection(r)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let p0 = m.sequenceOffset(fromView: CGPoint(x: clipped.minX, y: clipped.minY))
        let p1 = m.sequenceOffset(fromView: CGPoint(x: clipped.maxX, y: clipped.maxY))
        return (Vec2((p0.x + p1.x) / 2, (p0.y + p1.y) / 2), TextBox(width: max(1, p1.x - p0.x), height: max(1, p1.y - p0.y)))
    }
}
