import Foundation
import SQCore

// Planar homography from point pairs (stabilizer analysis, REA-resolve-stabilizer.md section 7 item 3: the default warp is
// one homography). Own code: direct linear solve with h33 = 1 on Hartley-normalized points, RANSAC over 4-point samples,
// least-squares refit on the inliers. The stabilizer corrects a similarity, so the homography is reduced to the similarity
// that best explains it over the picture (`similarity(in:)`); perspective the camera really had then no longer bends the
// estimate of turn and zoom the way a straight similarity fit through moving points does.

/// 3x3 projective map, row-major, h[8] = 1. Points are centered pixel coordinates (the `CameraMotion` convention).
struct Homography: Sendable, Equatable {
    var h: [Double]
    static let identity = Homography(h: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ p: Vec2) -> Vec2? {
        let w = h[6] * p.x + h[7] * p.y + h[8]
        guard abs(w) > 1e-9 else { return nil }
        let r = Vec2((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
        return r.x.isFinite && r.y.isFinite ? r : nil
    }

    /// Least-squares fit through 4 or more pairs (normal equations of the 8 unknowns, Hartley-normalized); nil when the
    /// points are degenerate (collinear, repeated).
    static func fit(_ src: [Vec2], _ dst: [Vec2]) -> Homography? {
        let n = min(src.count, dst.count)
        guard n >= 4 else { return nil }
        let (ts, ss) = normalization(Array(src[0..<n])), (td, sd) = normalization(Array(dst[0..<n]))
        guard ss > 0, sd > 0 else { return nil }
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        func addRow(_ r: [Double], _ b: Double) {
            for i in 0..<8 { atb[i] += r[i] * b; for j in 0..<8 { ata[i * 8 + j] += r[i] * r[j] } }
        }
        for i in 0..<n {
            let x = (src[i].x - ts.x) * ss, y = (src[i].y - ts.y) * ss
            let u = (dst[i].x - td.x) * sd, v = (dst[i].y - td.y) * sd
            addRow([x, y, 1, 0, 0, 0, -u * x, -u * y], u)
            addRow([0, 0, 0, x, y, 1, -v * x, -v * y], v)
        }
        guard let s = solve(ata, atb, 8) else { return nil }
        // Normalized H' maps ((p - ts) ss) to ((q - td) sd); undo: H = T_d^-1 H' T_s.
        let hn = s + [1]
        let tS = [ss, 0, -ts.x * ss, 0, ss, -ts.y * ss, 0, 0, 1]
        let tDInv = [1 / sd, 0, td.x, 0, 1 / sd, td.y, 0, 0, 1]
        var out = mul(tDInv, mul(hn, tS))
        guard abs(out[8]) > 1e-12 else { return nil }
        let k = 1 / out[8]
        out = out.map { $0 * k }
        guard out.allSatisfy({ $0.isFinite }) else { return nil }
        return Homography(h: out)
    }

    /// The similarity that best explains the map over a grid of points inside `halfWidth` x `halfHeight` (the picture is
    /// centered on the origin). nil when the map degenerates there.
    func similarity(halfWidth: Double, halfHeight: Double, grid: Int = 5) -> CameraMotion? {
        var a: [Vec2] = [], b: [Vec2] = []
        for i in 0..<grid {
            for j in 0..<grid {
                let p = Vec2((Double(i) / Double(grid - 1) * 2 - 1) * halfWidth, (Double(j) / Double(grid - 1) * 2 - 1) * halfHeight)
                guard let q = apply(p) else { return nil }
                a.append(p); b.append(q)
            }
        }
        return Registration.fitSimilarity(a, b)
    }

    /// What the camera similarity `s` (previous -> current) cannot express of this map: R = S^-1 H, normalized to h33 = 1
    /// (the residual perspective the Stabilizer keeps, `PerspectiveResidual`). Identity when the map is a similarity.
    func residual(after s: CameraMotion) -> PerspectiveResidual? {
        let r = s.rotation * .pi / 180, a = s.scale * cos(r), b = s.scale * sin(r), k = a * a + b * b
        guard k > 1e-12 else { return nil }
        // S^-1 = [a b -(a tx + b ty); -b a (b tx - a ty); 0 0 k] / k
        let inv = [a, b, -(a * s.dx + b * s.dy), -b, a, b * s.dx - a * s.dy, 0, 0, k]
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for t in 0..<3 { m[i * 3 + j] += inv[i * 3 + t] * h[t * 3 + j] } } }
        return PerspectiveResidual(matrix: m)
    }

    /// RANSAC over 4-point samples; refit on the inliers (twice). `threshold`: px of transfer error. nil when fewer than
    /// 4 points or no model with a plausible reduction `maxPerspective` (|h6|, |h7| times the long half side).
    static func ransac(_ src: [Vec2], _ dst: [Vec2], threshold: Double, halfWidth: Double, halfHeight: Double,
                       maxIterations: Int = 400, confidence: Double = 0.995) -> (map: Homography, inliers: [Int])? {
        let n = min(src.count, dst.count)
        guard n >= 4 else { return nil }
        let reach = max(halfWidth, halfHeight)
        func plausible(_ m: Homography) -> Bool {
            guard abs(m.h[6]) * reach < 0.35, abs(m.h[7]) * reach < 0.35,
                  let s = m.similarity(halfWidth: halfWidth, halfHeight: halfHeight, grid: 3) else { return false }
            return Registration.plausibleScale(s)
        }
        func inliers(of m: Homography) -> [Int] {
            (0..<n).filter { i in
                guard let q = m.apply(src[i]) else { return false }
                let d = q - dst[i]
                return d.x * d.x + d.y * d.y <= threshold * threshold
            }
        }
        var rng = SplitMix(seed: 0x4851_4D47)
        var best: [Int] = []
        var iterations = maxIterations, it = 0
        while it < iterations {
            it += 1
            var pick: [Int] = []
            while pick.count < 4 { let k = Int(rng.next() % UInt64(n)); if !pick.contains(k) { pick.append(k) } }
            guard let m = fit(pick.map { src[$0] }, pick.map { dst[$0] }), plausible(m) else { continue }
            let inl = inliers(of: m)
            if inl.count > best.count {
                best = inl
                let w = Double(inl.count) / Double(n)
                if w >= 1 { break }
                let need = log(1 - confidence) / log(max(1 - pow(w, 4), 1e-12))
                iterations = min(maxIterations, max(Int(need.rounded(.up)), 20))
            }
        }
        guard best.count >= 4 else { return nil }
        var set = best
        var model: Homography?
        for _ in 0..<2 {
            guard let m = fit(set.map { src[$0] }, set.map { dst[$0] }), plausible(m) else { break }
            let next = inliers(of: m)
            guard next.count >= 4 else { break }
            model = m; set = next
        }
        guard let model else { return nil }
        return (model, set)
    }

    // MARK: Linear algebra helpers

    private static func normalization(_ pts: [Vec2]) -> (center: Vec2, scale: Double) {
        let n = Double(pts.count)
        let c = Vec2(pts.reduce(0) { $0 + $1.x } / n, pts.reduce(0) { $0 + $1.y } / n)
        let d = pts.reduce(0) { $0 + (($1.x - c.x) * ($1.x - c.x) + ($1.y - c.y) * ($1.y - c.y)).squareRoot() } / n
        return (c, d > 1e-9 ? 2.0.squareRoot() / d : 0)
    }

    private static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { o[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return o
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    private static func solve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var m = a, r = b
        for c in 0..<n {
            var p = c
            for i in c..<n where abs(m[i * n + c]) > abs(m[p * n + c]) { p = i }
            guard abs(m[p * n + c]) > 1e-10 else { return nil }
            if p != c { for j in 0..<n { m.swapAt(c * n + j, p * n + j) }; r.swapAt(c, p) }
            for i in (c + 1)..<n where i < n {
                let f = m[i * n + c] / m[c * n + c]
                if f == 0 { continue }
                for j in c..<n { m[i * n + j] -= f * m[c * n + j] }
                r[i] -= f * r[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = r[i]
            for j in (i + 1)..<n where j < n { s -= m[i * n + j] * x[j] }
            x[i] = s / m[i * n + i]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }
}
