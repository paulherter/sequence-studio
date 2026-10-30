import Foundation

// Stabilizer v2: crop-constrained optimal path (principle of Grundmann et al., "Auto-Directed Video Stabilization with
// Robust L1 Optimal Camera Paths", 2011, which also bounds the path by a crop window; own code). The wanted path of one
// channel is the least-curvature path inside a tube around the real path (box-constrained quadratic program; the L1
// objective was tried as a taut string and loses on the RMS jitter measure because it bends in kinks). The tube
// width is the crop budget of one zoom, so the zoom is searched, not measured afterwards: the smallest zoom whose taut path
// is no more jittery than the quadratic path it replaces. Any path inside the tube is a candidate, so the quadratic one at its own zoom is too:
// the search can only improve on it.

extension Stabilizer {
    /// RMS second difference of a path in px at `reach` (the frame-to-frame shake the wanted path still has).
    static func pathJitter(_ p: [CameraPose], reach: Double) -> Double {
        let n = p.count
        guard n > 2 else { return 0 }
        func d2(_ f: (CameraPose) -> Double) -> [Double] { (1..<(n - 1)).map { f(p[$0 + 1]) - 2 * f(p[$0]) + f(p[$0 - 1]) } }
        let rad = Double.pi / 180
        let cs = [d2 { $0.translation.x }, d2 { $0.translation.y }, d2 { $0.rotation * rad * reach }, d2 { $0.logScale * reach }]
        let sum = cs.reduce(0.0) { $0 + $1.reduce(0) { $0 + $1 * $1 } }
        return (sum / Double(n - 2)).squareRoot()
    }

    /// The wanted path of one segment with the least zoom: for a zoom `z` (bisection from 1 to the zoom of `base`) the
    /// least-curvature path inside a tube around `real`, the tube per channel as wide as `base` strays from `real` at most
    /// and narrowed frame by frame (and around it) wherever the path would need more than `z`. The smallest `z` whose path
    /// is no more jittery than `base` wins; `base` (the quadratic path, also the fallback) is itself a candidate, so the result
    /// never needs more zoom or shakes more. `frameZoom(pose, k)` is the zoom frame k needs (nil: does not fit the limit).
    static func l1CropPath(real: [CameraPose], base: [CameraPose], hw: Double, hh: Double,
                           frameZoom: (CameraPose, Int) -> Double?) -> [CameraPose] {
        let n = real.count
        guard n > 2, base.count == n else { return base }
        func zoom(_ p: [CameraPose]) -> Double? {
            var z = 1.0
            for k in p.indices { guard let c = frameZoom(p[k], k) else { return nil }; z = max(z, c) }
            return z
        }
        guard let baseZoom = zoom(base), baseZoom > 1 + 1e-6 else { return base }
        let diagonal = (hw * hw + hh * hh).squareRoot()
        let target = pathJitter(base, reach: diagonal) * 1.0001
        /// The least-curvature path whose frames all need at most `z`: frames that do not fit are pinned at the boundary of
        /// the feasible set (on the line from the real pose to the violating one) and the path is solved again.
        func path(zoom z: Double) -> [CameraPose]? {
            var pinned = [CameraPose?](repeating: nil, count: n)
            let lambda = [Double](repeating: 1, count: n - 2)
            let mu = (0..<n).map { _ in 1e-4 }
            func solve() -> [CameraPose] {
                var channels: [[Double]] = []
                for f in [{ (p: CameraPose) in p.translation.x }, { $0.translation.y }, { $0.rotation }, { $0.logScale }] as [(CameraPose) -> Double] {
                    let target = (0..<n).map { pinned[$0].map(f) ?? f(base[$0]) }
                    let w = (0..<n).map { pinned[$0] == nil ? mu[$0] : 1e6 }
                    channels.append(solveSecondDifference(target, lambda: lambda, dataWeight: w))
                }
                return real.indices.map { CameraPose(translation: Vec2(channels[0][$0], channels[1][$0]), rotation: channels[2][$0], logScale: channels[3][$0]) }
            }
            for _ in 0..<30 {
                var p = solve()
                var bad = false
                for k in 0..<n where pinned[k] == nil && (frameZoom(p[k], k) ?? .infinity) > z + 1e-9 {
                    bad = true
                    var lo = 0.0, hi = 1.0   // fraction of the way from the real pose to p[k]
                    for _ in 0..<25 {
                        let mid = (lo + hi) / 2
                        if (frameZoom(CameraPose.lerp(real[k], p[k], mid), k) ?? .infinity) <= z + 1e-9 { lo = mid } else { hi = mid }
                    }
                    pinned[k] = CameraPose.lerp(real[k], p[k], lo)
                }
                if !bad { return p }
                p = solve()
                if p.indices.allSatisfy({ (frameZoom(p[$0], $0) ?? .infinity) <= z + 1e-9 }) { return p }
            }
            return nil
        }
        var best = base, bestZoom = baseZoom
        var lo = 1.0, hi = baseZoom
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            if let p = path(zoom: mid), pathJitter(p, reach: diagonal) <= target, let z = zoom(p) {
                hi = mid
                if z < bestZoom { best = p; bestZoom = z }
            } else {
                lo = mid
            }
        }
        return best
    }

    /// Camera Lock pose with the least zoom: pattern search over (x, y, turn, scale) minimizing the largest zoom any frame of
    /// `real` needs to hold it (`zoomOf(pose, k)`, nil = does not fit), starting at `start`, steps in px / degrees / log.
    static func lockPose(real: [CameraPose], start: CameraPose, step: Double, zoomOf: (CameraPose, Int) -> Double?) -> CameraPose {
        func cost(_ p: CameraPose) -> Double {
            var m = 1.0
            for k in real.indices { m = max(m, zoomOf(p, k) ?? 1e3) }
            return m
        }
        var cur = start, c = cost(cur)
        var h = [step, step, step / 100, step / 2000]
        for _ in 0..<60 {
            var improved = false
            for dim in 0..<4 {
                for sign in [-1.0, 1.0] {
                    var q = cur
                    switch dim {
                    case 0: q.translation.x += sign * h[dim]
                    case 1: q.translation.y += sign * h[dim]
                    case 2: q.rotation += sign * h[dim]
                    default: q.logScale += sign * h[dim]
                    }
                    let qc = cost(q)
                    if qc < c - 1e-9 { cur = q; c = qc; improved = true }
                }
            }
            if !improved { h = h.map { $0 / 2 }; if h[0] < 0.05 { break } }
        }
        return cur
    }
}
