import Foundation
import SQCore

/// Pure point editing for one curve (x ascending, 0…1). Interior points keep a minimum gap to their neighbors; the end
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
            let d = CGFloat(hypot(Double(CGFloat(q.x) * size.width - x), Double((1 - CGFloat(q.y)) * size.height - y)))
            if d <= radius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}
