import Foundation

// Stabilizer v2 smoothing (docs/research/reverse-engineering/REA-resolve-stabilizer.md section 7; own code from the
// principle): the wanted camera path minimizes the distance to the real path plus a per-frame weighted second difference
// (a quadratic path optimization, one banded solve per channel). The weights start equal and are relaxed around every
// frame whose picture would not cover its frame within the crop limit, then the path is solved again, until all frames
// pass. So the smoothing is not a fixed width: it gives way exactly where the crop limit would be violated.

extension Stabilizer {
    /// Solves (I + D^T diag(lambda) D) s = p for a pentadiagonal SPD system; D rows are second differences, `lambda[r]`
    /// weighs the row centered on frame r + 1 (count n - 2). Straight lines are not changed, the ends stay free.
    static func solveSecondDifference(_ p: [Double], lambda: [Double], dataWeight: [Double]? = nil) -> [Double] {
        let n = p.count
        guard n > 2, lambda.count == n - 2 else { return p }
        // Bands of the symmetric matrix: d[i] = A[i][i], e[i] = A[i][i+1], f[i] = A[i][i+2].
        // With `dataWeight` mu the system is (diag(mu) + D^T diag(lambda) D) s = mu * p.
        var d = dataWeight ?? [Double](repeating: 1, count: n), e = [Double](repeating: 0, count: n), f = [Double](repeating: 0, count: n)
        for r in 0..<(n - 2) {
            let l = lambda[r]
            // Row r = (1, -2, 1) on frames r, r + 1, r + 2.
            d[r] += l; d[r + 1] += 4 * l; d[r + 2] += l
            e[r] -= 2 * l; e[r + 1] -= 2 * l
            f[r] += l
        }
        // LDL^T for bandwidth 2.
        var ld = d, l1 = e, l2 = f      // l1[i] = L[i+1][i], l2[i] = L[i+2][i] (after the loop)
        var x = dataWeight.map { w in p.indices.map { w[$0] * p[$0] } } ?? p
        for i in 0..<n {
            if i >= 1 { ld[i] -= l1[i - 1] * l1[i - 1] * ld[i - 1] }
            if i >= 2 { ld[i] -= l2[i - 2] * l2[i - 2] * ld[i - 2] }
            if i + 1 < n {
                var v = e[i]
                if i >= 1 { v -= l1[i - 1] * l2[i - 1] * ld[i - 1] }
                l1[i] = v / ld[i]
            }
            if i + 2 < n { l2[i] = f[i] / ld[i] }
        }
        for i in 0..<n {   // forward: L y = p
            if i >= 1 { x[i] -= l1[i - 1] * x[i - 1] }
            if i >= 2 { x[i] -= l2[i - 2] * x[i - 2] }
        }
        for i in 0..<n { x[i] /= ld[i] }
        for i in stride(from: n - 1, through: 0, by: -1) {   // backward: L^T s = z
            if i + 1 < n { x[i] -= l1[i] * x[i + 1] }
            if i + 2 < n { x[i] -= l2[i] * x[i + 2] }
        }
        return x
    }

    /// The second-difference weight whose response matches a Gaussian of `sigma` frames at half amplitude.
    static func baseLambda(sigma: Double) -> Double {
        let s = sigma / 1.1774
        return s * s * s * s
    }

    static func quadraticPath(_ real: [CameraPose], lambda: [Double]) -> [CameraPose] {
        let tx = solveSecondDifference(real.map(\.translation.x), lambda: lambda)
        let ty = solveSecondDifference(real.map(\.translation.y), lambda: lambda)
        let r = solveSecondDifference(real.map(\.rotation), lambda: lambda)
        let s = solveSecondDifference(real.map(\.logScale), lambda: lambda)
        return real.indices.map { CameraPose(translation: Vec2(tx[$0], ty[$0]), rotation: r[$0], logScale: s[$0]) }
    }

    /// The smoothed path of one segment, crop-aware: `fits(wanted, k)` says whether frame k stays within the crop limit.
    /// Frames that do not fit lower the weight of their neighbors (out to 3 sigma, Gaussian falloff) and the path is solved
    /// again; every 5th round the reach grows. Frames still violating after `rounds` follow the real path.
    static func adaptiveQuadraticPath(real: [CameraPose], sigma: Double, rounds: Int = 40,
                                      fits: (CameraPose, Int) -> Bool) -> [CameraPose] {
        let n = real.count
        guard n > 2, sigma.isFinite, sigma > 0 else { return real }
        let base = baseLambda(sigma: sigma)
        var lambda = [Double](repeating: base, count: n - 2)
        var reach = max(sigma / 3, 1)
        var wanted = quadraticPath(real, lambda: lambda)
        for round in 0...rounds {
            let bad = wanted.indices.filter { !fits(wanted[$0], $0) }
            if bad.isEmpty { return wanted }
            if round == rounds {
                return wanted.indices.map { fits(wanted[$0], $0) ? wanted[$0] : real[$0] }
            }
            let span = Int((3 * reach).rounded(.up))
            for b in bad {
                for k in -span...span {
                    let row = b - 1 + k          // lambda row centered on frame b + k
                    guard row >= 0, row < n - 2 else { continue }
                    lambda[row] *= 1 - 0.5 * exp(-Double(k * k) / (reach * reach))
                }
            }
            if round % 5 == 4 { reach += 2 }
            wanted = quadraticPath(real, lambda: lambda)
        }
        return wanted
    }
}
