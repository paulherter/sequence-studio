import Foundation

/// The color curve spline (RGB Curves, Hue Saturation Curves): portable, so the renderer and the curve editors of every
/// platform evaluate one curve the same way.
public enum CurveMath {
    /// Sorted, deduplicated control points clamped to 0…1; fewer than 2 points = the diagonal.
    public static func normalized(_ pts: [CurvePoint]) -> [CurvePoint] {
        var p = pts.map { CurvePoint(min(max($0.x, 0), 1), min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for q in p { if let l = out.last, q.x - l.x < 1e-4 { out[out.count - 1] = q } else { out.append(q) } }
        p = out
        return p.count < 2 ? RGBCurves.diagonal : p
    }

    /// Monotone cubic Hermite value at `x` (flat beyond the end points).
    public static func evaluate(_ points: [CurvePoint], _ x: Float) -> Float {
        Spline(normalized(points)).value(x)
    }

    /// Precomputed monotone cubic (Fritsch-Carlson) through `p` (already cleaned, at least 2 points, x ascending):
    /// the slopes are worked out once, so sampling a curve many times does not repeat that.
    public struct Spline: Sendable {
        public let p: [CurvePoint]
        public let m: [Float]

        public init(_ p: [CurvePoint]) {
            self.p = p
            let n = p.count
            guard n >= 2 else { m = [0]; return }
            var d = [Float](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x) }
            var m = [Float](repeating: 0, count: n)
            m[0] = d[0]; m[n - 1] = d[n - 2]
            if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
            for i in 0..<(n - 1) {
                if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
                let a = m[i] / d[i], b = m[i + 1] / d[i]
                let s = a * a + b * b
                if s > 9 { let k = 3 / sqrtf(s); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
            }
            self.m = m
        }

        public func value(_ x: Float) -> Float {
            let n = p.count
            if n < 2 { return p.first?.y ?? 0.5 }
            if x <= p[0].x { return p[0].y }
            if x >= p[n - 1].x { return p[n - 1].y }
            var k = 0
            while k < n - 2 && x > p[k + 1].x { k += 1 }
            let h = p[k + 1].x - p[k].x
            let t = (x - p[k].x) / h
            let t2 = t * t, t3 = t2 * t
            let v = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
                + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
            return min(max(v, 0), 1)
        }
    }

    public static func sample(_ points: [CurvePoint], _ count: Int) -> [Float] {
        let spline = Spline(normalized(points))
        return (0..<count).map { spline.value(Float($0) / Float(count - 1)) }
    }
}
