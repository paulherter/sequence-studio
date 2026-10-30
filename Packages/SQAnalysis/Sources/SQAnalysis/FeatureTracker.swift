import CoreVideo
import Foundation
import SQCore

// Stabilizer rebuild (docs/research/stabilization/R2-resolve-deep.md section 11, stage A; own code from the principles):
// the camera motion between two frames is measured from sparse tracked features, not from one dense registration.
//   1. tiled Shi-Tomasi corners on the previous frame (a grid of tiles, a few corners each, so the points cover the whole
//      picture and no single object owns them),
//   2. pyramidal Lucas-Kanade from the previous to the current frame, then back; a point whose round trip does not return
//      to its start is dropped,
//   3. RANSAC homography (similarity as the fallback, `fitMotion`) over the surviving points (a moving subject or a foreground object is just outliers), refit on
//      the inliers.
// The inlier count and ratio are the confidence: a frame with too few inliers is "weak" and reports nil.

/// One tracked point set measured between two frames.
struct FeatureMotion: Sendable {
    /// previous -> current in px of the analysis frame (centered, y down, the `CameraMotion` convention).
    var motion: CameraMotion
    var inliers: Int
    var tracked: Int
    /// What the similarity left of the pair's homography, in analysis px; nil when the pair was fitted as a similarity.
    var residual: PerspectiveResidual?
    var ratio: Double { tracked > 0 ? Double(inliers) / Double(tracked) : 0 }
    /// 0...1: how far the estimate can be trusted (inlier ratio and count).
    var confidence: Double {
        let byRatio = min(max((ratio - FeatureTracker.weakRatio) / 0.3, 0), 1)
        let byCount = min(max(Double(inliers - FeatureTracker.weakInliers) / 20, 0), 1)
        return min(byRatio, byCount)
    }
}

/// Image pyramid of one frame (level 0 = the frame), cached between two pairs.
struct FeaturePyramid: Sendable {
    var levels: [GrayFrame]
    init?(_ base: GrayFrame, levels count: Int = FeatureTracker.pyramidLevels) {
        var out = [base]
        while out.count < count, let next = out.last?.halved() { out.append(next) }
        levels = out
    }
}

enum FeatureTracker {
    static let pyramidLevels = 4          // the frame and three halvings (OpenCV-style maxLevel 3)
    static let weakInliers = 12
    static let weakRatio = 0.3
    static let roundTripLimit = 0.5       // px at the analysis size
    static let lkIterations = 30
    static let lkEpsilon: Float = 0.01
    static let minEigenvalue: Float = 1e-4

    // MARK: Corners

    /// Shi-Tomasi corners of `f`, at most `perTile` in each cell of a `tilesX` x `tilesY` grid, at least `minDistance`
    /// apart inside a tile. Quality: 1 % of the frame's best response.
    static func corners(_ f: GrayFrame, tilesX: Int = 8, tilesY: Int = 6, perTile: Int, minDistance: Double,
                        margin: Int) -> [SIMD2<Float>] {
        let w = f.width, h = f.height
        guard w > 2 * margin + 8, h > 2 * margin + 8 else { return [] }
        // Min eigenvalue of the 3x3-summed structure tensor.
        var response = [Float](repeating: 0, count: w * h)
        f.pixels.withUnsafeBufferPointer { p in
            var gxx = [Float](repeating: 0, count: w * h), gxy = gxx, gyy = gxx
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let ix = (p[y * w + x + 1] - p[y * w + x - 1]) * 0.5, iy = (p[(y + 1) * w + x] - p[(y - 1) * w + x]) * 0.5
                    gxx[y * w + x] = ix * ix; gxy[y * w + x] = ix * iy; gyy[y * w + x] = iy * iy
                }
            }
            for y in 2..<(h - 2) {
                for x in 2..<(w - 2) {
                    var a: Float = 0, b: Float = 0, c: Float = 0
                    for dy in -1...1 {
                        let o = (y + dy) * w + x
                        a += gxx[o - 1] + gxx[o] + gxx[o + 1]
                        b += gxy[o - 1] + gxy[o] + gxy[o + 1]
                        c += gyy[o - 1] + gyy[o] + gyy[o + 1]
                    }
                    let half = (a + c) * 0.5, d = ((a - c) * 0.5 * (a - c) * 0.5 + b * b).squareRoot()
                    response[y * w + x] = half - d
                }
            }
        }
        guard let best = response.max(), best > 1e-3 else { return [] }
        let threshold = best * 0.01
        var out: [SIMD2<Float>] = []
        let x0 = margin, x1 = w - margin, y0 = margin, y1 = h - margin
        let tw = Double(x1 - x0) / Double(tilesX), th = Double(y1 - y0) / Double(tilesY)
        let minD2 = Float(minDistance * minDistance)
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let xa = x0 + Int(Double(tx) * tw), xb = x0 + Int(Double(tx + 1) * tw)
                let ya = y0 + Int(Double(ty) * th), yb = y0 + Int(Double(ty + 1) * th)
                var candidates: [(r: Float, x: Int, y: Int)] = []
                for y in ya..<yb {
                    for x in xa..<xb {
                        let r = response[y * w + x]
                        guard r > threshold else { continue }
                        // 3x3 local maximum
                        var isMax = true
                        search: for dy in -1...1 { for dx in -1...1 where (dx != 0 || dy != 0) && response[(y + dy) * w + x + dx] > r {
                            isMax = false; break search
                        } }
                        if isMax { candidates.append((r, x, y)) }
                    }
                }
                candidates.sort { $0.r > $1.r }
                var chosen: [SIMD2<Float>] = []
                for c in candidates {
                    let p = SIMD2<Float>(Float(c.x), Float(c.y))
                    if chosen.allSatisfy({ let d = $0 - p; return d.x * d.x + d.y * d.y >= minD2 }) { chosen.append(p) }
                    if chosen.count >= perTile { break }
                }
                out += chosen
            }
        }
        return out
    }

    // MARK: Lucas-Kanade

    /// Bilinear sample of a level; nil outside (one texel margin).
    @inline(__always)
    private static func sample(_ p: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let fx = x - Float(xi), fy = y - Float(yi)
        let o = yi * w + xi
        let a = p[o] + (p[o + 1] - p[o]) * fx
        let b = p[o + w] + (p[o + w + 1] - p[o + w]) * fx
        return a + (b - a) * fy
    }

    /// Where the point `start` (level-0 px of `from`) is in `to`: pyramidal translation LK. nil when it leaves the
    /// picture, has no texture in its window or does not converge.
    static func track(_ start: SIMD2<Float>, from: FeaturePyramid, to: FeaturePyramid, halfWindow hw: Int) -> SIMD2<Float>? {
        var flow = SIMD2<Float>(0, 0)
        for level in stride(from: min(from.levels.count, to.levels.count) - 1, through: 0, by: -1) {
            let a = from.levels[level], b = to.levels[level]
            let scale = Float(1 << level)
            let p = start / scale
            flow = flow * 2        // the coarser level's flow, in this level's pixels (zero at the top)
            let w = a.width, h = a.height
            guard Int(p.x) - hw - 2 >= 0, Int(p.y) - hw - 2 >= 0, Int(p.x) + hw + 3 < w, Int(p.y) + hw + 3 < h else {
                if level == 0 { return nil }
                continue
            }
            let n = (2 * hw + 1) * (2 * hw + 1)
            var ok = true
            a.pixels.withUnsafeBufferPointer { pa in
                b.pixels.withUnsafeBufferPointer { pb in
                    // Template and its gradient (fixed over the iterations).
                    var ix = [Float](repeating: 0, count: n), iy = ix, t = ix
                    var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0
                    var k = 0
                    for j in -hw...hw {
                        for i in -hw...hw {
                            let o = (Int(p.y) + j) * w + Int(p.x) + i
                            let dx = (pa[o + 1] - pa[o - 1]) * 0.5, dy = (pa[o + w] - pa[o - w]) * 0.5
                            ix[k] = dx; iy[k] = dy; t[k] = pa[o]
                            gxx += dx * dx; gxy += dx * dy; gyy += dy * dy
                            k += 1
                        }
                    }
                    let det = gxx * gyy - gxy * gxy
                    let minEig = ((gxx + gyy) - ((gxx - gyy) * (gxx - gyy) + 4 * gxy * gxy).squareRoot()) * 0.5 / Float(n)
                    guard det > 1e-6, minEig >= minEigenvalue else { ok = false; return }
                    let ox = Float(Int(p.x)), oy = Float(Int(p.y))
                    for _ in 0..<lkIterations {
                        var bx: Float = 0, by: Float = 0
                        var k = 0
                        for j in -hw...hw {
                            for i in -hw...hw {
                                let sx = ox + Float(i) + flow.x, sy = oy + Float(j) + flow.y
                                guard sx >= 1, sy >= 1, sx < Float(w - 2), sy < Float(h - 2) else { ok = false; return }
                                let e = t[k] - sample(pb, w, h, sx, sy)
                                bx += ix[k] * e; by += iy[k] * e
                                k += 1
                            }
                        }
                        let dx = (gyy * bx - gxy * by) / det, dy = (gxx * by - gxy * bx) / det
                        flow += SIMD2<Float>(dx, dy)
                        if abs(dx) < lkEpsilon && abs(dy) < lkEpsilon { break }
                        if abs(flow.x) > Float(w) / 2 || abs(flow.y) > Float(h) / 2 { ok = false; return }
                    }
                }
            }
            if !ok { return nil }
        }
        return start + flow
    }

    // MARK: Robust fit

    /// RANSAC similarity through point pairs (`src` previous, `dst` current, centered coordinates); refit on the inliers.
    static func ransacSimilarity(_ src: [Vec2], _ dst: [Vec2], threshold: Double, maxIterations: Int = 300,
                                 confidence: Double = 0.995) -> (motion: CameraMotion, inliers: Int)? {
        let n = min(src.count, dst.count)
        guard n >= 2 else { return nil }
        var rng = SplitMix(seed: 0x5EED_5EED)
        func inliers(of m: CameraMotion) -> [Int] {
            let pose = m.pose
            return (0..<n).filter { i in let d = pose.apply(src[i]) - dst[i]; return d.x * d.x + d.y * d.y <= threshold * threshold }
        }
        var best: [Int] = []
        var iterations = maxIterations, it = 0
        while it < iterations {
            it += 1
            let i = Int(rng.next() % UInt64(n)); var j = Int(rng.next() % UInt64(n))
            if j == i { j = (j + 1) % n }
            guard let m = Registration.fitSimilarity([src[i], src[j]], [dst[i], dst[j]]), Registration.plausibleScale(m) else { continue }
            let inl = inliers(of: m)
            if inl.count > best.count {
                best = inl
                let w = Double(inl.count) / Double(n)
                // Samples needed so that one all-inlier pair was drawn with probability `confidence`.
                if w >= 1 { break }
                let need = log(1 - confidence) / log(max(1 - w * w, 1e-12))
                iterations = min(maxIterations, max(Int(need.rounded(.up)), 10))
            }
        }
        guard best.count >= 2 else { return nil }
        // Refit on the inliers, twice (the inlier set follows the better model).
        var set = best
        var model: CameraMotion?
        for _ in 0..<2 {
            guard let m = Registration.fitSimilarity(set.map { src[$0] }, set.map { dst[$0] }) else { break }
            model = m
            let next = inliers(of: m)
            if next.count < 2 { break }
            set = next
        }
        guard let model else { return nil }
        return (model, set.count)
    }

    /// Fewest tracked points for which a homography is tried (8 unknowns need margin over the 4-point minimum).
    static let minHomographyPoints = 24

    /// The camera motion through point pairs: a RANSAC homography reduced to the similarity that explains it over the
    /// picture, when it explains clearly more points than a similarity does; the similarity otherwise (too few points,
    /// no plausible homography, no gain). `inliers` counts the points of the model that was used.
    static func fitMotion(_ src: [Vec2], _ dst: [Vec2], threshold: Double, halfWidth: Double,
                          halfHeight: Double) -> (motion: CameraMotion, inliers: Int, homography: Bool, residual: PerspectiveResidual?)? {
        let sim = ransacSimilarity(src, dst, threshold: threshold)
        if src.count >= minHomographyPoints,
           let hom = Homography.ransac(src, dst, threshold: threshold, halfWidth: halfWidth, halfHeight: halfHeight),
           let m = hom.map.similarity(halfWidth: halfWidth, halfHeight: halfHeight),
           Registration.plausibleScale(m), hom.inliers.count > (sim?.inliers ?? 0) + max(2, src.count / 50) {
            return (m, hom.inliers.count, true, hom.map.residual(after: m))
        }
        return sim.map { ($0.motion, $0.inliers, false, nil) }
    }

    /// Motion of `current` against `previous`; nil when the frames have too little in common (weak frame).
    static func register(previous: FeaturePyramid, current: FeaturePyramid) -> FeatureMotion? {
        let f = previous.levels[0]
        let w = f.width, h = f.height, maxDim = max(w, h)
        let perTile = min(max(Int((10 * Double(w) / 1920).rounded()), 4), 20)
        let search = max(3, maxDim / 192)
        let hw = search + 3
        let big = maxDim > 1000
        let pts = corners(f, perTile: perTile, minDistance: max(4, 30 * Double(w) / 1920), margin: hw + 2)
        var src: [Vec2] = [], dst: [Vec2] = []
        var tracked = 0
        let cx = Double(w) / 2, cy = Double(h) / 2
        for p in pts {
            guard let q = track(p, from: previous, to: current, halfWindow: hw),
                  let back = track(q, from: current, to: previous, halfWindow: hw) else { continue }
            let d = back - p
            guard (d.x * d.x + d.y * d.y).squareRoot() <= Float(roundTripLimit) else { continue }
            tracked += 1
            src.append(Vec2(Double(p.x) - cx, Double(p.y) - cy))
            dst.append(Vec2(Double(q.x) - cx, Double(q.y) - cy))
        }
        guard tracked >= weakInliers,
              let fit = fitMotion(src, dst, threshold: big ? 0.5 : 1.0, halfWidth: cx, halfHeight: cy) else { return nil }
        let result = FeatureMotion(motion: fit.motion, inliers: fit.inliers, tracked: tracked, residual: fit.residual)
        guard result.inliers >= weakInliers, result.ratio >= weakRatio else { return nil }
        return result
    }
}
