import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure axis rule of an ease handle drag (like Premiere, no accidental bounce): a drag starts horizontal only (Reach);
/// the vertical part (speed at the key) applies once the pointer has left the dead zone around the press, then follows
/// both axes freely. Shift keeps the drag horizontal only.
public enum EaseHandleDragMath {
    /// Points of vertical travel from the press before the height starts to follow.
    public static let deadZone: CGFloat = 6

    /// Whether the vertical part is on: it latches once past the dead zone, and Shift switches it off.
    public static func isVertical(wasVertical: Bool, pressY: CGFloat, y: CGFloat, shift: Bool) -> Bool {
        if shift { return false }
        return wasVertical || abs(y - pressY) > deadZone
    }

    /// The speed to write: the pointer's speed when vertical is on, else the speed the handle had (`kept`),
    /// clamped to what the handle's value part can store (`dy = speed * dx`, `dx` = reach).
    public static func speed(vertical: Bool, pointer: Double, kept: Double, reach: Double,
                             valueRange: ClosedRange<Double>?) -> Double {
        let s = vertical ? pointer : kept
        guard let r = valueRange, reach > 1e-9 else { return s }
        return min(max(s, r.lowerBound / reach), r.upperBound / reach)
    }
}
