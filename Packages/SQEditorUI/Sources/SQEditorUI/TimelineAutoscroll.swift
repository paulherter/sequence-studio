import CoreGraphics
import Foundation

/// Edge autoscroll while a clip, an edge or the playhead is dragged near the border of the timeline (pure).
public enum TimelineAutoscroll {
    /// Distance from the edge, inside the view, where scrolling starts (points).
    public static let zone: CGFloat = 48
    /// The pointer this far outside the view (or further) scrolls at full speed (points).
    public static let overshoot: CGFloat = 80
    /// Top speed in points per second.
    public static let maxSpeed: CGFloat = 1800

    /// Scroll speed (points per second, >= 0) for a pointer `distanceFromEdge` points inside the nearest edge; negative
    /// = outside the view. Zero in the interior (>= `zone`), growing smoothly towards the edge, capped at `maxSpeed`.
    /// Monotonic: a smaller distance never scrolls slower.
    public static func autoscrollSpeed(distanceFromEdge d: CGFloat) -> CGFloat {
        guard d < zone else { return 0 }
        let t = min((zone - d) / (zone + overshoot), 1)
        return maxSpeed * t * t
    }

    /// Signed horizontal velocity (points per second, negative = scroll left) for a pointer at `x` over the content
    /// area `viewLeft..<viewRight`. Zero when the area is too narrow to hold both zones.
    public static func velocity(pointerX x: CGFloat, viewLeft: CGFloat, viewRight: CGFloat) -> CGFloat {
        guard viewRight - viewLeft > 2 * zone else { return 0 }
        let fromLeft = x - viewLeft, fromRight = viewRight - x
        if fromLeft < fromRight { return -autoscrollSpeed(distanceFromEdge: fromLeft) }
        return autoscrollSpeed(distanceFromEdge: fromRight)
    }
}

/// Shift while dragging a clip locks the movement to the axis that moved first (horizontal = time, vertical = track).
public struct AxisLock: Sendable, Equatable {
    public enum Axis: Sendable, Equatable { case horizontal, vertical }
    /// Pointer travel (points) before an axis is chosen.
    public static let threshold: CGFloat = 4
    public private(set) var axis: Axis?
    public init() {}

    /// Feeds the pointer travel since mouse down. The first axis whose travel reaches `threshold` wins, the larger one
    /// when both do at once; once chosen it stays until `reset()`.
    @discardableResult
    public mutating func update(dx: CGFloat, dy: CGFloat) -> Axis? {
        if axis == nil, max(abs(dx), abs(dy)) >= Self.threshold { axis = abs(dx) >= abs(dy) ? .horizontal : .vertical }
        return axis
    }

    public mutating func reset() { axis = nil }
}
