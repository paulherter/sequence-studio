import Foundation

// Stabilizer v2: the residual perspective. The analysis fits a homography per frame pair and reduces it to the camera
// similarity (turn, zoom, shift). What the similarity cannot express stays here as `PerspectiveResidual`: the homography
// R = S^-1 H of the pair, as eight numbers (R minus the identity, h33 = 1) in picture px about the picture center.
// The residual path is the running sum of the pairs (first order: the terms are small), smoothed by the same second
// difference solver as the similarity channels, scaled by Strength, and written as the Stabilizer's perspective keys.
// The render side warps with I + correction in the existing Stabilizer warp pass (the Rolling Shutter pass), before the
// stage's similarity: one resampling for both.
// shortcut: the weights are the base ones (the crop-aware relaxing of the similarity does not apply, the edge is held in
// the warp instead), and a pair below `Stabilizer.minConfidence` contributes no residual; upgrade when a clip shows it.

/// A homography near the identity: `values` = (m00-1, m01, m02, m10, m11-1, m12, m20, m21) of the 3x3 map
/// p -> (m00 x + m01 y + m02, m10 x + m11 y + m12) / (m20 x + m21 y + 1).
public struct PerspectiveResidual: Sendable, Hashable, Codable {
    public var values: [Double]
    public static let zero = PerspectiveResidual([Double](repeating: 0, count: 8))
    public init(_ values: [Double]) {
        self.values = values.count == 8 ? values : [Double](repeating: 0, count: 8)
    }
    public init(from d: Decoder) throws { self.init(try d.singleValueContainer().decode([Double].self)) }
    public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(values) }

    public var isZero: Bool { values.allSatisfy { $0 == 0 } }

    /// The map this residual describes.
    public func map(_ p: Vec2) -> Vec2 {
        let v = values
        let w = v[6] * p.x + v[7] * p.y + 1
        guard abs(w) > 1e-9 else { return p }
        return Vec2(((1 + v[0]) * p.x + v[1] * p.y + v[2]) / w, (v[3] * p.x + (1 + v[4]) * p.y + v[5]) / w)
    }

    /// The residual of the map `m` (row-major 3x3, any h33 != 0), nil when degenerate or not finite.
    public init?(matrix m: [Double]) {
        guard m.count == 9, abs(m[8]) > 1e-12 else { return nil }
        let k = 1 / m[8]
        let v = [m[0] * k - 1, m[1] * k, m[2] * k, m[3] * k, m[4] * k - 1, m[5] * k, m[6] * k, m[7] * k]
        guard v.allSatisfy(\.isFinite) else { return nil }
        self.init(v)
    }

    /// The same map in a picture whose x and y are scaled by `fx`, `fy` (analysis px -> picture px): D R D^-1.
    public func scaled(x fx: Double, y fy: Double) -> PerspectiveResidual {
        let v = values
        return PerspectiveResidual([v[0], v[1] * fx / fy, v[2] * fx, v[3] * fy / fx, v[4], v[5] * fy, v[6] / fx, v[7] / fy])
    }

    public func lerp(to o: PerspectiveResidual, _ f: Double) -> PerspectiveResidual {
        PerspectiveResidual(zip(values, o.values).map { $0 + ($1 - $0) * f })
    }

    /// Largest stored size, for deciding whether anything is left to warp.
    public var magnitude: Double { values.map(abs).max() ?? 0 }
}

extension ClipEffect {
    /// The eight stored perspective correction keys (never rename), generated data like the stage keys.
    public static let stabilizePerspectiveKeys = (0..<8).map { "stabilizePerspective\($0)" }
}

extension Stabilizer {
    /// Smallest correction worth a warp: below it the keys are not written (no pass for nothing).
    static let perspectiveFloor = 1e-9

    /// The perspective correction per analyzed frame (`n` entries), or empty when no frame needs one. `skip[i]`: segment i
    /// is left uncorrected (the guard's verdict). Pairs are the analysis' residuals, each pair `i` taking frame i-1 to i.
    static func perspectiveCorrections(_ a: StabilizationAnalysis, n: Int, segments: [Range<Int>], skip: [Bool],
                                       locked: Bool, sigma: Double, strength: Double) -> [PerspectiveResidual] {
        guard a.perspective.count >= n, strength > 0, a.perspective.contains(where: { !$0.isZero }) else { return [] }
        var out = [PerspectiveResidual](repeating: .zero, count: n)
        for (i, seg) in segments.enumerated() where !skip[i] && seg.count > 2 {
            // Running sum of the pairs from the segment start; untrusted pairs add nothing. Stored confidence: the check
            // vouches for the similarity only, so a poor-inlier homography stays untrusted when the check agrees.
            var real = [[Double]](repeating: [Double](repeating: 0, count: 8), count: seg.count)
            for (j, k) in seg.enumerated() where j > 0 {
                let pair = a.storedConfidence(at: k) >= minConfidence ? a.perspective[k].values : [Double](repeating: 0, count: 8)
                real[j] = zip(real[j - 1], pair).map { $0 + $1 }
            }
            var wanted = real
            if locked {
                let mean = (0..<8).map { c in real.reduce(0) { $0 + $1[c] } / Double(seg.count) }
                wanted = real.map { _ in mean }
            } else if sigma.isFinite, sigma > 0 {
                let lambda = [Double](repeating: baseLambda(sigma: sigma), count: seg.count - 2)
                let channels = (0..<8).map { c in solveSecondDifference(real.map { $0[c] }, lambda: lambda) }
                wanted = (0..<seg.count).map { j in (0..<8).map { channels[$0][j] } }
            }
            for (j, k) in seg.enumerated() {
                out[k] = PerspectiveResidual((0..<8).map { strength * (wanted[j][$0] - real[j][$0]) })
            }
        }
        return out.contains { $0.magnitude > perspectiveFloor } ? out : []
    }

    /// The perspective correction at source time `t`: the analyzed frame's own, linear between two analyzed frames, held
    /// before the first, after the last and across a cut (as `correction`). Zero when the plan has none.
    public static func perspectiveCorrection(_ plan: StabilizationPlan, _ analysis: StabilizationAnalysis, at t: Time) -> PerspectiveResidual {
        let cs = plan.perspective, ts = analysis.frameTimes
        let n = min(cs.count, ts.count)
        guard n > 0 else { return .zero }
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return cs[0] }
        let i = lo - 1
        if i == n - 1 || ts[i] == t || analysis.cuts.contains(i + 1) { return cs[i] }
        let span = ts[i + 1] - ts[i], into = t - ts[i]
        let f = Double(into.value) / Double(into.timescale) / (Double(span.value) / Double(span.timescale))
        guard f.isFinite, f > 0 else { return cs[i] }
        return cs[i].lerp(to: cs[i + 1], f)
    }

    /// Largest error of a stored perspective key against the exact correction, per key: every term moves a picture
    /// corner by at most 0.1 px.
    static func perspectiveTolerances(pictureWidth w: Int, pictureHeight h: Int) -> [Double] {
        let reach = max(Double(max(w, h)) / 2, 1)
        return [0.1 / reach, 0.1 / reach, 0.1, 0.1 / reach, 0.1 / reach, 0.1, 0.1 / (reach * reach), 0.1 / (reach * reach)]
    }
}
