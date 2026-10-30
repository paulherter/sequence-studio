import Foundation

/// Spacing guides of the Program monitor: while a layer is moved between two other layers, it snaps to the position
/// where the gap to the left layer equals the gap to the right one (same on y). Offset space, y down, like `SnapGuides`.
public enum SpacingGuides {
    /// One gap to mark: `from`..`to` along `axis`, at `cross` on the other axis.
    public struct Gap: Sendable, Equatable {
        public var vertical: Bool   // true: the gap is measured on y (a vertical run)
        public var from: Double, to: Double, cross: Double
    }

    public struct Result: Sendable, Equatable {
        public var dx = 0.0, dy = 0.0
        public var gaps: [Gap] = []
        public static let none = Result()
    }

    /// `box` is the moving layer's bounds, `others` the other layers' bounds. Only layers that overlap the box on the
    /// cross axis count as neighbors. The nearest pair per axis within `threshold` wins.
    public static func snap(box: CGRect, others: [CGRect], threshold: Double) -> Result {
        var r = Result.none
        // x axis: neighbors overlapping in y
        let rowMates = others.filter { !$0.isEmpty && $0.maxY > box.minY && $0.minY < box.maxY }
        if let s = equalGap(lo: Double(box.minX), hi: Double(box.maxX),
                            before: rowMates.filter { $0.maxX <= box.minX + 1e-6 }.map { (Double($0.minX), Double($0.maxX)) },
                            after: rowMates.filter { $0.minX >= box.maxX - 1e-6 }.map { (Double($0.minX), Double($0.maxX)) },
                            threshold: threshold) {
            r.dx = s.shift
            let y = Double(box.midY)
            r.gaps += [Gap(vertical: false, from: s.beforeEdge, to: Double(box.minX) + s.shift, cross: y),
                       Gap(vertical: false, from: Double(box.maxX) + s.shift, to: s.afterEdge, cross: y)]
        }
        let colMates = others.filter { !$0.isEmpty && $0.maxX > box.minX && $0.minX < box.maxX }
        if let s = equalGap(lo: Double(box.minY), hi: Double(box.maxY),
                            before: colMates.filter { $0.maxY <= box.minY + 1e-6 }.map { (Double($0.minY), Double($0.maxY)) },
                            after: colMates.filter { $0.minY >= box.maxY - 1e-6 }.map { (Double($0.minY), Double($0.maxY)) },
                            threshold: threshold) {
            r.dy = s.shift
            let x = Double(box.midX)
            r.gaps += [Gap(vertical: true, from: s.beforeEdge, to: Double(box.minY) + s.shift, cross: x),
                       Gap(vertical: true, from: Double(box.maxY) + s.shift, to: s.afterEdge, cross: x)]
        }
        return r
    }

    private static func equalGap(lo: Double, hi: Double, before: [(Double, Double)], after: [(Double, Double)],
                                 threshold: Double) -> (shift: Double, beforeEdge: Double, afterEdge: Double)? {
        guard let b = before.max(by: { $0.1 < $1.1 }), let a = after.min(by: { $0.0 < $1.0 }) else { return nil }
        let free = a.0 - b.1 - (hi - lo)             // room left around the box
        guard free >= 0 else { return nil }
        let want = b.1 + free / 2                      // box.lo when both gaps are equal
        let shift = want - lo
        guard abs(shift) <= threshold else { return nil }
        return (shift, b.1, a.0)
    }
}
