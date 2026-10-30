import Foundation

/// Cubic bezier path of a position segment with an arc-length table.
public struct SpatialPath: Sendable, Hashable {
    public var p0, p1, p2, p3: Vec2
    private var table: [Double]   // cumulative length at s = i / (count-1)
    public var length: Double { table.last ?? 0 }

    public init(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, resolution: Int = 128) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
        table = [0]
        var prev = p0
        var acc = 0.0
        for i in 1...resolution {
            let pt = SpatialPath.eval(p0, p1, p2, p3, Double(i) / Double(resolution))
            acc += (pt - prev).length
            table.append(acc)
            prev = pt
        }
    }

    private static func eval(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2, _ s: Double) -> Vec2 {
        let u = 1 - s
        return a * (u * u * u) + b * (3 * u * u * s) + c * (3 * u * s * s) + d * (s * s * s)
    }

    /// Point at curve parameter `s` (0...1).
    public func point(atParameter s: Double) -> Vec2 { SpatialPath.eval(p0, p1, p2, p3, s) }

    /// Point at a fraction (0...1) of the arc length: constant speed for linear progress.
    public func point(atArcFraction f: Double) -> Vec2 {
        guard length > 0 else { return p0 }
        let target = min(max(f, 0), 1) * length
        var lo = 0, hi = table.count - 1
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if table[m] <= target { lo = m } else { hi = m }
        }
        let span = table[hi] - table[lo]
        let frac = span > 0 ? (target - table[lo]) / span : 0
        return point(atParameter: (Double(lo) + frac) / Double(table.count - 1))
    }
}

public struct MotionPathSegment: Sendable, Hashable {
    public var fromID: UUID
    public var toID: UUID
    /// Polyline along the path; a hold segment has only the point it shows.
    public var points: [Vec2]
}

extension KeyframeTrack where V == Vec2 {
    /// Motion path for the program monitor, `samplesPerSegment` points per segment (min 2).
    public func motionPath(samplesPerSegment n: Int = 32) -> [MotionPathSegment] {
        let n = max(n, 2)
        return zip(keys, keys.dropFirst()).map { a, b in
            if a.interpolation.isHold {
                return MotionPathSegment(fromID: a.id, toID: b.id, points: [a.interpolation == .hold ? a.value : b.value])
            }
            let path = SpatialPath(p0: a.value, p1: a.value + a.outTangent, p2: b.value + b.inTangent, p3: b.value)
            let pts = (0..<n).map { i in i == n - 1 ? b.value : path.point(atParameter: Double(i) / Double(n - 1)) }
            return MotionPathSegment(fromID: a.id, toID: b.id, points: pts)
        }
    }
}
