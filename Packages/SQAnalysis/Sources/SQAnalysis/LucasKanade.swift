import CoreVideo
import Foundation
import SQCore

/// Pyramidal Lucas-Kanade point tracking (Bouguet's formulation) on luma: each point's sub-pixel shift between two
/// frames from a 15 x 15 window, coarse to fine over three levels (shifts up to ~25 px). Points in flat areas (small
/// smallest eigenvalue) or that do not converge are dropped.
enum LucasKanade {
    struct Gray {
        let w: Int, h: Int
        var px: [Float]

        /// Bilinear sample, clamped to the edges.
        @inline(__always) func at(_ x: Float, _ y: Float) -> Float {
            let cx = min(max(x, 0), Float(w - 1)), cy = min(max(y, 0), Float(h - 1))
            let x0 = Int(cx), y0 = Int(cy)
            let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
            let fx = cx - Float(x0), fy = cy - Float(y0)
            let a = px[y0 * w + x0], b = px[y0 * w + x1], c = px[y1 * w + x0], d = px[y1 * w + x1]
            return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
        }

        /// Half size, 2 x 2 box average.
        func half() -> Gray {
            let nw = max(w / 2, 1), nh = max(h / 2, 1)
            var out = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    let x0 = min(2 * x, w - 1), x1 = min(2 * x + 1, w - 1), y0 = min(2 * y, h - 1), y1 = min(2 * y + 1, h - 1)
                    out[y * nw + x] = (px[y0 * w + x0] + px[y0 * w + x1] + px[y1 * w + x0] + px[y1 * w + x1]) * 0.25
                }
            }
            return Gray(w: nw, h: nh, px: out)
        }
    }

    static let levels = 3
    static let radius = 7
    static let iterations = 12
    /// Smallest eigenvalue of the window's structure tensor (per pixel, luma 0...1) below which a point is untrackable.
    static let minEigen: Float = 1e-4

    /// Luma (Rec. 709 weights) of a BGRA buffer.
    static func gray(_ pb: CVPixelBuffer) -> Gray? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let r = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let b = Float(r[x * 4]), g = Float(r[x * 4 + 1]), rr = Float(r[x * 4 + 2])
                px[y * w + x] = (0.0722 * b + 0.7152 * g + 0.2126 * rr) / 255
            }
        }
        return Gray(w: w, h: h, px: px)
    }

    static func pyramid(_ g: Gray) -> [Gray] {
        var out = [g]
        while out.count < levels { out.append(out[out.count - 1].half()) }
        return out
    }

    /// Point pairs previous -> current for `pts` (pixels of level 0) between two pyramids; untrackable points are left out.
    static func pairs(_ pa: [Gray], _ pb: [Gray], _ pts: [Vec2]) -> ([Vec2], [Vec2])? {
        var from: [Vec2] = [], to: [Vec2] = []
        for p in pts {
            guard let q = track(Vec2(p.x, p.y), pa, pb) else { continue }
            from.append(p); to.append(q)
        }
        return from.count >= 8 ? (from, to) : nil
    }

    /// Where point `p` of the first pyramid went in the second (pixels of level 0), or nil.
    static func track(_ p: Vec2, _ a: [Gray], _ b: [Gray]) -> Vec2? {
        var gx: Float = 0, gy: Float = 0          // guess carried down the pyramid
        let n = (2 * radius + 1) * (2 * radius + 1)
        var ix = [Float](repeating: 0, count: n), iy = ix, i0 = ix
        for level in stride(from: a.count - 1, through: 0, by: -1) {
            let s = Float(1 << level)
            let px = Float(p.x) / s, py = Float(p.y) / s
            let A = a[level], B = b[level]
            // Window of the first image: values and central-difference gradients, and the structure tensor.
            var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0, k = 0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let x = px + Float(dx), y = py + Float(dy)
                    let vx = (A.at(x + 1, y) - A.at(x - 1, y)) * 0.5, vy = (A.at(x, y + 1) - A.at(x, y - 1)) * 0.5
                    ix[k] = vx; iy[k] = vy; i0[k] = A.at(x, y)
                    gxx += vx * vx; gxy += vx * vy; gyy += vy * vy
                    k += 1
                }
            }
            let det = gxx * gyy - gxy * gxy
            let tr = gxx + gyy
            let minEig = (tr - ((gxx - gyy) * (gxx - gyy) + 4 * gxy * gxy).squareRoot()) / 2 / Float(n)
            guard det > 1e-12 else { return nil }
            if level == 0, minEig < minEigen { return nil }
            var vx: Float = 0, vy: Float = 0
            for _ in 0..<iterations {
                var bx: Float = 0, by: Float = 0, k = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let d = B.at(px + Float(dx) + gx + vx, py + Float(dy) + gy + vy) - i0[k]
                        bx += d * ix[k]; by += d * iy[k]
                        k += 1
                    }
                }
                let ex = -(gyy * bx - gxy * by) / det, ey = -(gxx * by - gxy * bx) / det
                vx += ex; vy += ey
                if ex * ex + ey * ey < 1e-4 { break }
            }
            guard vx.isFinite, vy.isFinite else { return nil }
            if level > 0 { gx = 2 * (gx + vx); gy = 2 * (gy + vy) } else { gx += vx; gy += vy }
        }
        guard abs(gx) < 60, abs(gy) < 60 else { return nil }
        return Vec2(p.x + Double(gx), p.y + Double(gy))
    }
}
