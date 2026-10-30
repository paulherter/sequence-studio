import Foundation

// Mask tracking beyond translation and scale (DECISIONS "Mask tracking: rotation and perspective"). The tracker reports
// one motion per frame: a 3 x 3 projective map from the frame the track started on. Position and +Scale come from the
// object tracker's box; +Rotation and Perspective are fitted here from point correspondences (optical flow samples
// inside the mask), robustly, so background flow leaking into the region does not drag the mask.

/// What a mask track follows (chosen in Effect Controls, not stored in the project).
public enum MaskTrackMode: String, CaseIterable, Sendable, Codable {
    case position, scale, rotation, perspective

    /// The behavior before this choice existed: position + per-axis scale from the object tracker.
    public static let `default` = MaskTrackMode.scale

    public var title: String {
        switch self {
        case .position: "Position"
        case .scale: "+ Scale"
        case .rotation: "+ Rotation"
        case .perspective: "Perspective"
        }
    }

    /// Point tracking (optical flow + fit) instead of the object tracker's box.
    public var usesPoints: Bool { self == .rotation || self == .perspective }

    /// Fewest correspondences a fit of this kind needs.
    var minPoints: Int {
        switch self {
        case .position: 1
        case .scale, .rotation: 2
        case .perspective: 4
        }
    }
}

/// A 3 x 3 projective map (row major), p' = M p in homogeneous coordinates. Frame fractions or pixels, as named.
public struct MaskMotion: Sendable, Hashable {
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = MaskMotion(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public init(translation t: Vec2) { self.init(m: [1, 0, t.x, 0, 1, t.y, 0, 0, 1]) }

    /// Turn by `angle` radians about `c` (y down: positive turns +x towards +y, clockwise on screen).
    public init(rotation angle: Double, about c: Vec2) {
        let co = cos(angle), si = sin(angle)
        self.init(m: [co, -si, c.x - co * c.x + si * c.y, si, co, c.y - si * c.x - co * c.y, 0, 0, 1])
    }

    /// Box `a` becoming box `b`: moved, and with `scale` sized per axis about its center (the object tracker's motion).
    public init(from a: MaskTrackBox, to b: MaskTrackBox, scale: Bool) {
        let sx = scale && a.size.x > 1e-9 ? b.size.x / a.size.x : 1
        let sy = scale && a.size.y > 1e-9 ? b.size.y / a.size.y : 1
        self.init(m: [sx, 0, b.center.x - sx * a.center.x, 0, sy, b.center.y - sy * a.center.y, 0, 0, 1])
    }

    public func apply(_ p: Vec2) -> Vec2 {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        let iw = abs(w) > 1e-12 ? 1 / w : 0
        return Vec2((m[0] * p.x + m[1] * p.y + m[2]) * iw, (m[3] * p.x + m[4] * p.y + m[5]) * iw)
    }

    /// This motion first, then `next`.
    public func then(_ next: MaskMotion) -> MaskMotion { MaskMotion(m: Self.mul(next.m, m)) }

    public var inverse: MaskMotion? {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7], c1 = a[5] * a[6] - a[3] * a[8], c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-15 else { return nil }
        let d = 1 / det
        return MaskMotion(m: [
            c0 * d, (a[2] * a[7] - a[1] * a[8]) * d, (a[1] * a[5] - a[2] * a[4]) * d,
            c1 * d, (a[0] * a[8] - a[2] * a[6]) * d, (a[2] * a[3] - a[0] * a[5]) * d,
            c2 * d, (a[1] * a[6] - a[0] * a[7]) * d, (a[0] * a[4] - a[1] * a[3]) * d,
        ])
    }

    /// A pixel-space motion on a `width` x `height` frame as a motion on frame fractions.
    public func inFractions(width: Double, height: Double) -> MaskMotion {
        MaskMotion(m: Self.mul(Self.mul([1 / width, 0, 0, 0, 1 / height, 0, 0, 0, 1], m), [width, 0, 0, 0, height, 0, 0, 0, 1]))
    }

    /// A frame-fraction motion as a motion on pixels of a `width` x `height` frame.
    public func inPixels(width: Double, height: Double) -> MaskMotion {
        MaskMotion(m: Self.mul(Self.mul([width, 0, 0, 0, height, 0, 0, 0, 1], m), [1 / width, 0, 0, 0, 1 / height, 0, 0, 0, 1]))
    }

    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                let x: Double = a[r * 3] * b[c]
                let y: Double = a[r * 3 + 1] * b[3 + c]
                let z: Double = a[r * 3 + 2] * b[6 + c]
                out[r * 3 + c] = x + y + z
            }
        }
        return out
    }
}

extension MaskTrackBox {
    /// Axis-aligned bounds of `points` (none: a zero box at the frame center).
    public init(bounding points: [Vec2]) {
        guard let f = points.first else { self.init(center: Vec2(0.5, 0.5), size: .zero); return }
        var lo = f, hi = f
        for p in points.dropFirst() {
            lo = Vec2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vec2(max(hi.x, p.x), max(hi.y, p.y))
        }
        self.init(center: (lo + hi) * 0.5, size: hi - lo)
    }
}

extension MaskPath {
    /// The path carried by `motion`: points mapped, tangents follow their handle ends (exact for affine motions).
    public func transformed(by motion: MaskMotion) -> MaskPath {
        MaskPath(vertices: vertices.map { v in
            let p = motion.apply(v.point)
            return MaskVertex(p, inTangent: motion.apply(v.point + v.inTangent) - p,
                              outTangent: motion.apply(v.point + v.outTangent) - p)
        })
    }
}

/// Robust motion fits from point correspondences (pixel space, so a rotation stays a rotation on non-square frames).
public enum MaskMotionFit {
    public struct Result: Sendable, Hashable {
        public var motion: MaskMotion
        /// Root mean square residual of the kept points (px).
        public var rms: Double
        /// Points kept after outlier rejection.
        public var inliers: Int
    }

    /// Residuals below this always count as inliers (px): flow noise on real footage.
    static let minThreshold = 0.75
    static let rounds = 4

    /// Fits the motion of `mode` taking `from[i]` to `to[i]`, rejecting outliers (residual over 3 x median) in a few rounds.
    /// nil: too few or degenerate points.
    public static func fit(from: [Vec2], to: [Vec2], mode: MaskTrackMode) -> Result? {
        guard from.count == to.count, from.count >= mode.minPoints else { return nil }
        var keep = Array(from.indices)
        // Perspective picks its inliers with a similarity first: a free homography bends towards outliers.
        if mode == .perspective, let sim = fit(from: from, to: to, mode: .rotation) {
            keep = from.indices.filter { (sim.motion.apply(from[$0]) - to[$0]).length <= threshold(sim, from, to) }
        }
        var best: Result?
        for _ in 0..<rounds {
            guard keep.count >= mode.minPoints,
                  let motion = solve(keep.map { from[$0] }, keep.map { to[$0] }, mode) else { return best }
            let res = from.indices.map { (motion.apply(from[$0]) - to[$0]).length }
            let kept = keep.map { res[$0] }
            let rms = (kept.reduce(0) { $0 + $1 * $1 } / Double(kept.count)).squareRoot()
            best = Result(motion: motion, rms: rms, inliers: keep.count)
            let limit = max(3 * median(kept), minThreshold)
            let next = from.indices.filter { res[$0] <= limit }
            if next == keep { break }
            keep = next
        }
        return best
    }

    static func threshold(_ r: Result, _ from: [Vec2], _ to: [Vec2]) -> Double {
        max(3 * median(from.indices.map { (r.motion.apply(from[$0]) - to[$0]).length }), minThreshold)
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Least-squares fit of one kind (no outlier handling).
    static func solve(_ a: [Vec2], _ b: [Vec2], _ mode: MaskTrackMode) -> MaskMotion? {
        let n = Double(a.count)
        let ca = a.reduce(Vec2.zero, +) * (1 / n), cb = b.reduce(Vec2.zero, +) * (1 / n)
        switch mode {
        case .position:
            return MaskMotion(translation: cb - ca)
        case .scale, .rotation:
            var ss = 0.0, dot = 0.0, cross = 0.0
            for (p, q) in zip(a, b) {
                let s = p - ca, d = q - cb
                ss += s.x * s.x + s.y * s.y
                dot += s.x * d.x + s.y * d.y
                cross += s.x * d.y - s.y * d.x
            }
            guard ss > 1e-9 else { return nil }
            let k = dot / ss, r = mode == .rotation ? cross / ss : 0
            // q = cb + [k -r; r k](p - ca)
            return MaskMotion(m: [k, -r, cb.x - k * ca.x + r * ca.y, r, k, cb.y - r * ca.x - k * ca.y, 0, 0, 1])
        case .perspective:
            return homography(a, b)
        }
    }

    /// Normalized DLT with h33 = 1 (Hartley): least squares over all points.
    static func homography(_ a: [Vec2], _ b: [Vec2]) -> MaskMotion? {
        guard let ta = normalizer(a), let tb = normalizer(b), let tbInv = tb.inverse else { return nil }
        let na = a.map(ta.apply), nb = b.map(tb.apply)
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        func add(_ row: [Double], _ rhs: Double) {
            for i in 0..<8 {
                atb[i] += row[i] * rhs
                for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
            }
        }
        for (p, q) in zip(na, nb) {
            add([p.x, p.y, 1, 0, 0, 0, -p.x * q.x, -p.y * q.x], q.x)
            add([0, 0, 0, p.x, p.y, 1, -p.x * q.y, -p.y * q.y], q.y)
        }
        guard let h = solveLinear(ata, atb, 8) else { return nil }
        let hn = MaskMotion(m: h + [1])
        return ta.then(hn).then(tbInv)
    }

    /// Moves the centroid to the origin and scales the mean distance to sqrt 2.
    static func normalizer(_ p: [Vec2]) -> MaskMotion? {
        let n = Double(p.count)
        let c = p.reduce(Vec2.zero, +) * (1 / n)
        let mean = p.reduce(0) { $0 + ($1 - c).length } / n
        guard mean > 1e-9 else { return nil }
        let s = 2.0.squareRoot() / mean
        return MaskMotion(m: [s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1])
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solveLinear(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var a = a, b = b
        for col in 0..<n {
            var piv = col
            for r in col + 1..<n where abs(a[r * n + col]) > abs(a[piv * n + col]) { piv = r }
            guard abs(a[piv * n + col]) > 1e-12 else { return nil }
            if piv != col {
                for k in 0..<n { a.swapAt(col * n + k, piv * n + k) }
                b.swapAt(col, piv)
            }
            for r in col + 1..<n {
                let f = a[r * n + col] / a[col * n + col]
                guard f != 0 else { continue }
                for k in col..<n { a[r * n + k] -= f * a[col * n + k] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in r + 1..<n { s -= a[r * n + k] * x[k] }
            x[r] = s / a[r * n + r]
        }
        return x
    }

    /// Grid points (cell centers, `spacing` apart) inside `polygon` (even-odd); at most `limit`, thinned evenly.
    public static func samplePoints(in polygon: [Vec2], spacing: Double, limit: Int = 400) -> [Vec2] {
        guard polygon.count >= 3, spacing > 0 else { return [] }
        let box = MaskTrackBox(bounding: polygon)
        let lo = box.center - box.size * 0.5
        let nx = Int((box.size.x / spacing).rounded(.down)), ny = Int((box.size.y / spacing).rounded(.down))
        var out: [Vec2] = []
        for j in 0..<max(ny, 0) {
            for i in 0..<max(nx, 0) {
                let p = Vec2(lo.x + (Double(i) + 0.5) * spacing, lo.y + (Double(j) + 0.5) * spacing)
                if contains(polygon, p) { out.append(p) }
            }
        }
        guard out.count > limit, limit > 0 else { return out }
        let step = Double(out.count) / Double(limit)
        return (0..<limit).map { out[Int(Double($0) * step)] }
    }

    /// Even-odd point in polygon.
    static func contains(_ poly: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
