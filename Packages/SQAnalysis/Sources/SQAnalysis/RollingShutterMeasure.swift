import Foundation
import SQCore

// The per-row motion of a frame pair for the Stabilizer's Rolling Shutter option (SQCore RollingShutter.swift).
//
// The registration of the Stabilizer check gives one similarity (shift, rotation, zoom) for the whole picture. A rolling
// sensor adds a part no similarity holds: while the camera's speed changes, the shift grows along the scan axis. It is
// measured as a dense flow on a grid: every cell (about 24 px) refines its own shift from the global fit, and an affine
// field dx = a0 + a1 x + a2 y, dy = b0 + b1 x + b2 y goes through the cells that agree (a moving subject drops out).
// Of its four linear terms a rotation and a zoom use two (a2 = -b1, a1 = b2); what is left is the slope:
//   rows scanned along y:  slope = ((a2 + b1) * height, (b2 - a1) * height)
//   rows scanned along x:  slope = ((a1 - b2) * width,  (b1 + a2) * width)
// That split only holds where a pixel is square. The analysis frame has the stored pixels (anamorphic: wider than tall
// when shown), so the field is taken to the displayed source picture first (X = fx x, Y = fy y):
//   a1, b2 stay, a2 -> a2 fx / fy, b1 -> b1 fy / fx, shifts and extents by their own factor.
enum RollingShutterMeasure {
    /// Cell size of the flow grid in analysis pixels, and the fewest agreeing cells for a sample.
    static let cellSize = 24, minCells = 12

    /// Shift and slope of `current` against `previous` (same size), started at the registered `motion` (analysis
    /// pixels). The result is in source pixels: `factorX/Y` = picture width / analysis width and picture height /
    /// analysis height (both 1: analysis pixels). nil when too few textured cells agree.
    static func sample(previous: GrayFrame, current: GrayFrame, around motion: CameraMotion, alongX: Bool,
                       factorX: Double = 1, factorY: Double = 1) -> RollingShutterSample? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        let w = current.width, h = current.height
        let r = motion.rotation * .pi / 180
        let a = motion.scale * cos(r) - 1, b = motion.scale * sin(r), tx = motion.dx, ty = motion.dy
        let cols = max(4, w / cellSize), rows = max(4, h / cellSize)
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        var at: [Vec2] = [], flow: [Vec2] = []
        at.reserveCapacity(cols * rows); flow.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let x0 = col * w / cols, x1 = (col + 1) * w / cols, y0 = row * h / rows, y1 = (row + 1) * h / rows
                var ctx = tx, cty = ty, ok = false
                for _ in 0..<8 {
                    guard let (d, fit) = PhotometricRegistration.step(previous, current, tx: ctx, ty: cty, a: a, b: b, stride: 1,
                                                                      region: (x0, x1, y0, y1), translationOnly: true),
                          fit.texture >= PhotometricRegistration.minTexture, fit.valid > 0.5 else { break }
                    ctx += d.0; cty += d.1
                    if abs(d.0) < 0.005 && abs(d.1) < 0.005 { ok = true; break }
                }
                guard ok, abs(ctx - tx) < Double(w) / 16, abs(cty - ty) < Double(h) / 16 else { continue }
                let p = Vec2((Double(x0 + x1) - 1) / 2 - cx, (Double(y0 + y1) - 1) / 2 - cy)
                at.append(p)
                flow.append(Vec2(a * p.x - b * p.y + ctx, b * p.x + a * p.y + cty))
            }
        }
        guard at.count >= minCells else { return nil }
        var keep = Array(at.indices)
        var fx = [0.0, 0, 0], fy = [0.0, 0, 0]
        for _ in 0..<3 {
            guard keep.count >= minCells, let x = plane(keep.map { at[$0] }, keep.map { flow[$0].x }),
                  let y = plane(keep.map { at[$0] }, keep.map { flow[$0].y }) else { return nil }
            fx = x; fy = y
            let res = at.indices.map { i -> Double in
                let ex = fx[0] + fx[1] * at[i].x + fx[2] * at[i].y - flow[i].x, ey = fy[0] + fy[1] * at[i].x + fy[2] * at[i].y - flow[i].y
                return (ex * ex + ey * ey).squareRoot()
            }
            let limit = max(0.25, 2.5 * keep.map { res[$0] }.sorted()[keep.count / 2])
            let next = at.indices.filter { res[$0] <= limit }
            if next == keep { break }
            keep = next
        }
        guard keep.count >= minCells else { return nil }
        guard factorX > 0, factorY > 0, factorX.isFinite, factorY.isFinite else { return nil }
        let a1 = fx[1], a2 = fx[2] * factorX / factorY, b1 = fy[1] * factorY / factorX, b2 = fy[2]
        let width = Double(w) * factorX, height = Double(h) * factorY
        let slope = alongX ? Vec2((a1 - b2) * width, (b1 + a2) * width) : Vec2((a2 + b1) * height, (b2 - a1) * height)
        let shift = Vec2(fx[0] * factorX, fy[0] * factorY)
        guard slope.x.isFinite, slope.y.isFinite, shift.x.isFinite, shift.y.isFinite else { return nil }
        return RollingShutterSample(shiftX: shift.x, shiftY: shift.y, slopeX: slope.x, slopeY: slope.y)
    }

    /// Least-squares plane v = c0 + c1 x + c2 y through the points; nil when they lie on a line.
    static func plane(_ p: [Vec2], _ v: [Double]) -> [Double]? {
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0, sv = 0.0, sxv = 0.0, syv = 0.0
        for (q, value) in zip(p, v) {
            sx += q.x; sy += q.y; sxx += q.x * q.x; sxy += q.x * q.y; syy += q.y * q.y
            sv += value; sxv += q.x * value; syv += q.y * value
        }
        let n = Double(p.count)
        // Cramer on [[n sx sy] [sx sxx sxy] [sy sxy syy]].
        let det = n * (sxx * syy - sxy * sxy) - sx * (sx * syy - sxy * sy) + sy * (sx * sxy - sxx * sy)
        guard abs(det) > 1e-9 * max(n * sxx * syy, 1e-300) else { return nil }
        let c0 = (sv * (sxx * syy - sxy * sxy) - sx * (sxv * syy - sxy * syv) + sy * (sxv * sxy - sxx * syv)) / det
        let c1 = (n * (sxv * syy - sxy * syv) - sv * (sx * syy - sxy * sy) + sy * (sx * syv - sxv * sy)) / det
        let c2 = (n * (sxx * syv - sxv * sxy) - sx * (sx * syv - sxv * sy) + sv * (sx * sxy - sxx * sy)) / det
        return [c0, c1, c2]
    }

    /// The sample in source pixels (`factor` = picture width / analysis width).
    static func scaled(_ s: RollingShutterSample, by factor: Double) -> RollingShutterSample {
        RollingShutterSample(shiftX: s.shiftX * factor, shiftY: s.shiftY * factor, slopeX: s.slopeX * factor, slopeY: s.slopeY * factor)
    }
}
