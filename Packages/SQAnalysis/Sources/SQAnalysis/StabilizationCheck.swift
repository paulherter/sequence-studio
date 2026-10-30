import Foundation
import SQCore

// W9.7 (2a/2b) The stabilizer's second opinion. Next to Vision's registration every frame pair is also registered
// photometrically: a robust pyramidal Lucas-Kanade fit of a similarity on a small gray picture (long side 256), started at
// "no motion", so it does not inherit Vision's mistakes. It gives
//   - the check motion (`StabilizationAnalysis.checks`, the plan's never-worse guard),
//   - a texture score (smallest eigenvalue of the gradient structure tensor: a blank wall has none),
//   - the confidence of Vision's motion (agreement of the two, texture),
//   - the cut scores: gray residual left after the alignment, and a quadrant histogram distance.
// Pure CPU on ~37k pixels per frame (well under a millisecond per level), no allocations per iteration.

/// A gray picture (0...255), row-major.
struct GrayFrame: Sendable {
    let width: Int, height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) { self.width = width; self.height = height; self.pixels = pixels }


    /// Half size (2x2 mean).
    func halved() -> GrayFrame? {
        let w = width / 2, h = height / 2
        guard w >= 8, h >= 8 else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    let i = 2 * y * width + 2 * x
                    out[y * w + x] = (p[i] + p[i + 1] + p[i + width] + p[i + width + 1]) * 0.25
                }
            }
        }
        return GrayFrame(width: w, height: h, pixels: out)
    }

    /// Finest first: self, half, quarter, ... while the long side stays >= 24.
    func pyramid(levels: Int) -> [GrayFrame] {
        var out = [self]
        while out.count < levels, let h = out.last!.halved(), max(h.width, h.height) >= 24 { out.append(h) }
        return out
    }

    /// 16-bin luma histogram per quadrant, each normalized to 1.
    func quadrantHistograms() -> [Float] {
        var hist = [Float](repeating: 0, count: 64)
        let hw = width / 2, hh = height / 2
        for y in 0..<height {
            for x in 0..<width {
                let q = (y < hh ? 0 : 2) + (x < hw ? 0 : 1)
                let b = min(max(Int(pixels[y * width + x] / 16), 0), 15)
                hist[q * 16 + b] += 1
            }
        }
        for q in 0..<4 {
            let n = hist[(q * 16)..<(q * 16 + 16)].reduce(0, +)
            if n > 0 { for b in 0..<16 { hist[q * 16 + b] /= n } }
        }
        return hist
    }

    /// Mean over the quadrants of half the L1 distance of two `quadrantHistograms` (0 = equal, 1 = disjoint).
    static func histogramDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var s: Float = 0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return Double(s) / 2 / 4
    }
}

/// The photometric registration of one pair.
struct PhotometricMotion: Sendable {
    /// Content motion previous -> current in px of the finest gray level (center origin, y down, degrees clockwise).
    var motion: CameraMotion
    /// Mean |gray difference| left after the alignment (0...255).
    var residual: Double
    /// Smallest eigenvalue of the mean gradient structure tensor (gray levels^2 per px^2) of the finest level.
    var texture: Double
    /// The fit converged inside the picture and enough grid cells agree on it.
    var converged: Bool
    /// Share of the textured grid cells whose own shift agrees with the fitted motion (0...1).
    var coherence: Double = 1
}

enum PhotometricRegistration {
    /// Below this texture (`PhotometricMotion.texture`) neither registration is trusted: a blank wall, a black frame.
    /// Measured 2026-10-04 at 256 px (EngineBench stabilize, SQ_STAB_PROBE): hand-held iPhone shots 13-45, Sony shots
    /// with blurred backgrounds 3.5-36; a blank frame ~0.
    static let minTexture = 4.0
    /// Huber limit of the robust fit, gray levels: larger differences (a moving subject) count less.
    static let huber: Float = 12

    /// Registers `current` against `previous` (same size): q = [1+a -b; b 1+a] p + t on the pyramid, coarse to fine.
    static func register(previous: GrayFrame, current: GrayFrame, levels: Int = 4) -> PhotometricMotion? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        let pp = previous.pyramid(levels: levels), cp = current.pyramid(levels: levels)
        guard pp.count == cp.count else { return nil }
        var tx = 0.0, ty = 0.0, a = 0.0, b = 0.0
        var last = Fit(residual: 0, texture: 0, valid: 0)
        for level in stride(from: pp.count - 1, through: 0, by: -1) {
            if level < pp.count - 1 { tx *= 2; ty *= 2 }
            let stride = level == 0 ? 2 : 1
            for _ in 0..<(level == 0 ? 6 : 10) {
                guard let (d, fit) = step(pp[level], cp[level], tx: tx, ty: ty, a: a, b: b, stride: stride) else { return nil }
                tx += d.0; ty += d.1; a += d.2; b += d.3
                last = fit
                if abs(d.0) < 0.005 && abs(d.1) < 0.005 && abs(d.2) < 1e-5 && abs(d.3) < 1e-5 { break }
            }
        }
        // Flow coherence: each grid cell refines its own shift from the global fit; a robust similarity through the cells
        // that agree replaces the global fit (a moving subject or a flat sky pulls one cell, not the camera motion).
        let cells = cellFit(pp[0], cp[0], tx: tx, ty: ty, a: a, b: b)
        var coherence = 0.0
        if let c = cells {
            coherence = c.coherence
            let r = c.motion.rotation * .pi / 180
            a = c.motion.scale * cos(r) - 1; b = c.motion.scale * sin(r); tx = c.motion.dx; ty = c.motion.dy
        }
        guard let final = measure(pp[0], cp[0], tx: tx, ty: ty, a: a, b: b) else { return nil }
        last = final
        let s = ((1 + a) * (1 + a) + b * b).squareRoot()
        guard s.isFinite, s > 0, tx.isFinite, ty.isFinite else { return nil }
        let m = CameraMotion(dx: tx, dy: ty, rotation: atan2(b, 1 + a) * 180 / .pi, scale: s)
        let w = Double(previous.width), h = Double(previous.height)
        let converged = cells != nil && last.valid > 0.5 && abs(tx) < w / 3 && abs(ty) < h / 3 && abs(m.rotation) < 15
            && s > 0.8 && s < 1.25
        return PhotometricMotion(motion: m, residual: last.residual, texture: last.texture, converged: converged,
                                 coherence: coherence)
    }

    /// Grid of the cell refinement and the fewest agreeing cells for a check.
    static let cellColumns = 6, cellRows = 4, minCoherentCells = 6

    /// Refines the shift of each grid cell (translation only, started at the global fit) and fits a similarity through
    /// the cell centers, dropping cells that disagree (residual > max(0.3 px, 2.5 x median), twice). nil when fewer than
    /// `minCoherentCells` textured cells agree. Coherence = agreeing share of the textured cells.
    private static func cellFit(_ prev: GrayFrame, _ cur: GrayFrame, tx: Double, ty: Double, a: Double, b: Double)
        -> (motion: CameraMotion, coherence: Double)? {
        let w = cur.width, h = cur.height
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        var src: [Vec2] = [], dst: [Vec2] = []
        for row in 0..<cellRows {
            for col in 0..<cellColumns {
                let x0 = col * w / cellColumns, x1 = (col + 1) * w / cellColumns
                let y0 = row * h / cellRows, y1 = (row + 1) * h / cellRows
                var ctx = tx, cty = ty, ok = false, textured = false
                for _ in 0..<8 {
                    guard let (d, fit) = step(prev, cur, tx: ctx, ty: cty, a: a, b: b, stride: 1,
                                              region: (x0, x1, y0, y1), translationOnly: true) else { break }
                    guard fit.texture >= minTexture, fit.valid > 0.5 else { break }
                    textured = true
                    ctx += d.0; cty += d.1
                    if abs(d.0) < 0.01 && abs(d.1) < 0.01 { ok = true; break }
                }
                guard textured, ok, abs(ctx - tx) < Double(w) / 16, abs(cty - ty) < Double(h) / 16 else { continue }
                let p = Vec2((Double(x0 + x1) - 1) / 2 - cx, (Double(y0 + y1) - 1) / 2 - cy)
                src.append(p)
                dst.append(Vec2((1 + a) * p.x - b * p.y + ctx, b * p.x + (1 + a) * p.y + cty))
            }
        }
        guard src.count >= minCoherentCells else { return nil }
        var keep = Array(src.indices)
        var fit: CameraMotion?
        for _ in 0..<3 {
            guard keep.count >= minCoherentCells, let m = Registration.fitSimilarity(keep.map { src[$0] }, keep.map { dst[$0] }) else { return nil }
            fit = m
            let pose = m.posePublic
            let res = src.indices.map { i -> Double in let d = pose.apply(src[i]) - dst[i]; return (d.x * d.x + d.y * d.y).squareRoot() }
            let med = keep.map { res[$0] }.sorted()[keep.count / 2]
            let limit = max(0.3, 2.5 * med)
            let next = src.indices.filter { res[$0] <= limit }
            if next == keep { break }
            keep = next
        }
        guard let fit, keep.count >= minCoherentCells else { return nil }
        return (fit, Double(keep.count) / Double(src.count))
    }

    struct Fit { var residual: Double; var texture: Double; var valid: Double }

    /// One robust Gauss-Newton step; the parameter change and the fit before it.
    /// `region` (pixel x0..<x1, y0..<y1; nil = whole picture) and `translationOnly` (only tx, ty change) serve the cells.
    static func step(_ prev: GrayFrame, _ cur: GrayFrame, tx: Double, ty: Double, a: Double, b: Double,
                             stride: Int, region: (Int, Int, Int, Int)? = nil,
                             translationOnly: Bool = false) -> ((Double, Double, Double, Double), Fit)? {
        let w = cur.width, h = cur.height
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2, L = Double(max(w, h)) / 2
        let (rx0, rx1, ry0, ry1) = region.map { (max($0.0, 2), min($0.1, w - 2), max($0.2, 2), min($0.3, h - 2)) } ?? (2, w - 2, 2, h - 2)
        guard rx1 > rx0, ry1 > ry0 else { return nil }
        var g0 = 0.0, g1 = 0.0, g2 = 0.0, g3 = 0.0
        var h00 = 0.0, h01 = 0.0, h02 = 0.0, h03 = 0.0, h11 = 0.0, h12 = 0.0, h13 = 0.0, h22 = 0.0, h23 = 0.0, h33 = 0.0
        var absSum = 0.0, count = 0, total = 0
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        prev.pixels.withUnsafeBufferPointer { P in
            cur.pixels.withUnsafeBufferPointer { C in
                for y in Swift.stride(from: ry0, to: ry1, by: stride) {
                    let py = Double(y) - cy
                    for x in Swift.stride(from: rx0, to: rx1, by: stride) {
                        total += 1
                        let px = Double(x) - cx
                        let qx = (1 + a) * px - b * py + tx + cx, qy = b * px + (1 + a) * py + ty + cy
                        guard qx >= 1, qy >= 1, qx < Double(w - 2), qy < Double(h - 2) else { continue }
                        let x0 = Int(qx), y0 = Int(qy)
                        let fx = Float(qx - Double(x0)), fy = Float(qy - Double(y0))
                        @inline(__always) func at(_ xx: Int, _ yy: Int) -> Float { C[yy * w + xx] }
                        @inline(__always) func bil(_ dx: Int, _ dy: Int) -> Float {
                            let i00 = at(x0 + dx, y0 + dy), i10 = at(x0 + 1 + dx, y0 + dy)
                            let i01 = at(x0 + dx, y0 + 1 + dy), i11 = at(x0 + 1 + dx, y0 + 1 + dy)
                            return (i00 * (1 - fx) + i10 * fx) * (1 - fy) + (i01 * (1 - fx) + i11 * fx) * fy
                        }
                        let ic = bil(0, 0)
                        let gx = Double((bil(1, 0) - bil(-1, 0)) * 0.5), gy = Double((bil(0, 1) - bil(0, -1)) * 0.5)
                        let r = Double(ic - P[y * w + x])
                        let ar = abs(r)
                        let wt = ar <= Double(huber) ? 1 : Double(huber) / ar
                        let j0 = gx, j1 = gy, j2 = (gx * px + gy * py) / L, j3 = (-gx * py + gy * px) / L
                        let w0 = wt * j0, w1 = wt * j1, w2 = wt * j2, w3 = wt * j3
                        g0 += w0 * r; g1 += w1 * r; g2 += w2 * r; g3 += w3 * r
                        h00 += w0 * j0; h01 += w0 * j1; h02 += w0 * j2; h03 += w0 * j3
                        h11 += w1 * j1; h12 += w1 * j2; h13 += w1 * j3
                        h22 += w2 * j2; h23 += w2 * j3; h33 += w3 * j3
                        sxx += gx * gx; syy += gy * gy; sxy += gx * gy
                        absSum += ar; count += 1
                    }
                }
            }
        }
        guard count > 16 else { return nil }
        let H = [h00, h01, h02, h03, h01, h11, h12, h13, h02, h12, h22, h23, h03, h13, h23, h33]
        let g = [g0, g1, g2, g3]
        let n = Double(count)
        let mxx = sxx / n, myy = syy / n, mxy = sxy / n
        let tr = mxx + myy, det = mxx * myy - mxy * mxy
        let lmin = tr / 2 - max(tr * tr / 4 - det, 0).squareRoot()
        let fit = Fit(residual: absSum / n, texture: lmin, valid: n / Double(max(total, 1)))
        if translationOnly {
            let det2 = h00 * h11 - h01 * h01
            guard det2 > 1e-9 * max(h00 * h11, 1e-300) else { return ((0, 0, 0, 0), fit) }
            return (((-g0 * h11 + g1 * h01) / det2, (-g1 * h00 + g0 * h01) / det2, 0, 0), fit)
        }
        guard let d = solve4(H, g.map { -$0 }) else { return ((0, 0, 0, 0), fit) }
        return ((d[0], d[1], d[2] / L, d[3] / L), fit)
    }

    /// Residual and texture at the given parameters (no step).
    private static func measure(_ prev: GrayFrame, _ cur: GrayFrame, tx: Double, ty: Double, a: Double, b: Double) -> Fit? {
        step(prev, cur, tx: tx, ty: ty, a: a, b: b, stride: 1)?.1
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve4(_ m: [Double], _ rhs: [Double]) -> [Double]? {
        var a = m, b = rhs
        let scale = (0..<4).map { abs(a[$0 * 4 + $0]) }.max() ?? 0
        guard scale > 0 else { return nil }
        for c in 0..<4 {
            var p = c
            for r in (c + 1)..<4 where abs(a[r * 4 + c]) > abs(a[p * 4 + c]) { p = r }
            guard abs(a[p * 4 + c]) > scale * 1e-12 else { return nil }
            if p != c {
                for k in 0..<4 { a.swapAt(c * 4 + k, p * 4 + k) }
                b.swapAt(c, p)
            }
            for r in (c + 1)..<4 {
                let f = a[r * 4 + c] / a[c * 4 + c]
                for k in c..<4 { a[r * 4 + k] -= f * a[c * 4 + k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: 4)
        for r in stride(from: 3, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<4 { s -= a[r * 4 + k] * x[k] }
            x[r] = s / a[r * 4 + r]
        }
        return x
    }

    /// Displacement difference of two motions (same px) at the four points half way to the corners, RMS px.
    static func disagreement(_ m1: CameraMotion, _ m2: CameraMotion, width: Double, height: Double) -> Double {
        let p1 = m1.posePublic, p2 = m2.posePublic
        var s = 0.0
        for q in [Vec2(-width / 4, -height / 4), Vec2(width / 4, -height / 4), Vec2(width / 4, height / 4), Vec2(-width / 4, height / 4)] {
            let d = p1.apply(q) - p2.apply(q)
            s += d.x * d.x + d.y * d.y
        }
        return (s / 4).squareRoot()
    }

    /// Vision and the check agree within this, px per 512 px of the long side: full confidence; at
    /// `fullDisagreement` none. Measured 2026-10-04 (EngineBench stabilize "check" line).
    /// Sony shots with a moving subject: median 0.3-1.3, p75 0.8-2.8; iPhone shots median 0.3-0.4.
    static let fullAgreement = 1.0, fullDisagreement = 3.0

    /// Confidence of Vision's motion (source px) given the check (`check` already in source px).
    static func confidence(vision: CameraMotion, check: PhotometricMotion?, checkInSource: CameraMotion?,
                           pictureWidth: Int, pictureHeight: Int) -> Double {
        guard let check, let c = checkInSource, check.converged, check.texture >= minTexture else { return 0 }
        let w = Double(pictureWidth), h = Double(pictureHeight)
        let d = disagreement(vision, c, width: w, height: h) * 512 / max(w, h)
        return min(max((fullDisagreement - d) / (fullDisagreement - fullAgreement), 0), 1)
    }
}

extension CameraMotion {
    var posePublic: CameraPose {
        CameraPose(translation: Vec2(dx, dy), rotation: rotation.isFinite ? rotation : 0,
                   logScale: scale.isFinite && scale > 0 ? log(scale) : 0)
    }
}
