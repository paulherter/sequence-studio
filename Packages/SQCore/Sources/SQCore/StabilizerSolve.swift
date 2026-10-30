import Foundation

// Stabilizer rebuild, stage B (docs/research/stabilization/R2-resolve-deep.md section 11; own code from the principles):
// the wanted camera path is a bilateral low-pass of the real path (a temporal Gaussian whose weights also fall with the
// distance between the two path values, so a sudden intended move such as a whip or a pan start is followed instead of
// averaged away), blended per frame with the real path by a strength that steps down wherever the picture would not cover
// its frame within the crop limit. The last step sets a still-violating frame to "no correction", so the limit always holds.

extension Stabilizer {
    /// Distance between two path values in px: translation plus the displacement of a point at `reach` from the center
    /// that turn and zoom cause (the L1 measure, cheap and monotone).
    static func pathDistance(_ a: CameraPose, _ b: CameraPose, reach: Double) -> Double {
        let dt = a.translation - b.translation
        return abs(dt.x) + abs(dt.y) + reach * (abs(a.rotation - b.rotation) * .pi / 180 + abs(a.logScale - b.logScale))
    }

    /// Bilateral low-pass of a path: temporal Gaussian `sigma` frames, motion Gaussian `motionSigma` px; the ends are
    /// reflected oddly (a straight line stays straight, the first and last pose stay).
    static func bilateralSmooth(_ poses: [CameraPose], sigma: Double, motionSigma: Double, reach: Double) -> [CameraPose] {
        let n = poses.count
        guard n > 2, sigma.isFinite, sigma > 0, motionSigma > 0 else { return poses }
        let radius = min(Int((3 * sigma).rounded(.up)), n - 1)
        guard radius > 0 else { return poses }
        func at(_ i: Int) -> CameraPose {
            if i >= 0 && i < n { return poses[i] }
            let edge = i < 0 ? 0 : n - 1
            let mirror = i < 0 ? min(-i, n - 1) : max(2 * (n - 1) - i, 0)
            let e = poses[edge], m = poses[mirror]
            return CameraPose(translation: e.translation * 2 - m.translation, rotation: 2 * e.rotation - m.rotation,
                              logScale: 2 * e.logScale - m.logScale)
        }
        let time = (0...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let m2 = 2 * motionSigma * motionSigma
        return (0..<n).map { t in
            let c = poses[t]
            var sum = 0.0, tx = 0.0, ty = 0.0, rot = 0.0, scale = 0.0
            for k in -radius...radius {
                let p = at(t + k)
                let d = pathDistance(c, p, reach: reach)
                let w = time[abs(k)] * exp(-(d * d) / m2)
                sum += w; tx += w * p.translation.x; ty += w * p.translation.y; rot += w * p.rotation; scale += w * p.logScale
            }
            return sum > 0 ? CameraPose(translation: Vec2(tx / sum, ty / sum), rotation: rot / sum, logScale: scale / sum) : c
        }
    }

    /// The wanted path between the real one (`strength` 0) and the bilateral low-pass of it (1), per frame.
    static func blended(real: [CameraPose], smooth: [CameraPose], strength: [Double]) -> [CameraPose] {
        real.indices.map { CameraPose.lerp(real[$0], smooth[$0], strength[$0]) }
    }

    /// The smoothed wanted path for one segment's real path whose pictures all cover their frame within the crop limit:
    /// `fits(wanted, k)` says whether frame k does. Strength steps down by a factor at the frames that do not fit, the
    /// reduction is spread over the smoothing window, and frames that still do not fit after `rounds` get strength 0.
    static func cropLimitedPath(real: [CameraPose], sigma: Double, motionSigma: Double, reach: Double,
                                rounds: Int = 12, step: Double = 0.7, fits: (CameraPose, Int) -> Bool) -> [CameraPose] {
        let smooth = bilateralSmooth(real, sigma: sigma, motionSigma: motionSigma, reach: reach)
        var s = [Double](repeating: 1, count: real.count)
        var wanted = blended(real: real, smooth: smooth, strength: s)
        for round in 0...rounds {
            let bad = wanted.indices.filter { !fits(wanted[$0], $0) }
            if bad.isEmpty { return wanted }
            if round == rounds {
                for k in bad { s[k] = 0 }
                return blended(real: real, smooth: smooth, strength: s)
            }
            for k in bad { s[k] *= step }
            // Neighbors follow: a lone dip in strength is a visible jerk, a dip over the window is a softer path.
            let spread = gaussianSmooth(s, sigma: max(sigma / 2, 1))
            for k in s.indices { s[k] = min(s[k], spread[k]) }
            wanted = blended(real: real, smooth: smooth, strength: s)
        }
        return wanted
    }
}
