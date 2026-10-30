import Accelerate
import Foundation
import SQCore

/// `SubjectTrackRules.matte` (bilinear resample of the model's logits, then alpha from the distance to the edge) with vDSP: the same arithmetic
/// per pixel, in whole-row operations. SQCore is compiled unoptimized in a Debug build, where its per-pixel loop took
/// ~500 ms for a 1080p frame; this target is optimized and the work is vectorized.
enum SubjectMatteUpsample {
    static func matte(logits: [Float], size: Int, width: Int, height: Int) -> SubjectMatte {
        precondition(logits.count == size * size && width > 0 && height > 0, "logits size mismatch")
        // Column taps once per matte (as indices into a source row, as vDSP_vindex wants them).
        var x0s = [Float](repeating: 0, count: width), x1s = x0s, txs = x0s
        for x in 0..<width {
            let fx = min(max((Double(x) + 0.5) * Double(size) / Double(width) - 0.5, 0), Double(size - 1))
            x0s[x] = Float(Int(fx)); x1s[x] = Float(min(Int(fx) + 1, size - 1)); txs[x] = Float(fx - Double(Int(fx)))
        }
        // Every source row resampled to the output width.
        var wide = [Float](repeating: 0, count: size * width)
        var a = [Float](repeating: 0, count: width), b = a
        logits.withUnsafeBufferPointer { src in
            for r in 0..<size {
                let row = src.baseAddress! + r * size
                vDSP_vindex(row, x0s, 1, &a, 1, vDSP_Length(width))
                vDSP_vindex(row, x1s, 1, &b, 1, vDSP_Length(width))
                vDSP.subtract(b, a, result: &b)
                vDSP.multiply(b, txs, result: &b)
                wide[(r * width)..<((r + 1) * width)] = ArraySlice(vDSP.add(a, b))
            }
        }
        // Then between two of those rows per output row.
        var v = [Float](repeating: 0, count: width * height)
        wide.withUnsafeBufferPointer { w in
            v.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let fy = min(max((Double(y) + 0.5) * Double(size) / Double(height) - 0.5, 0), Double(size - 1))
                    let r0 = Int(fy), r1 = min(Int(fy) + 1, size - 1)
                    var t = Float(fy - Double(r0))
                    vDSP_vintb(w.baseAddress! + r0 * width, 1, w.baseAddress! + r1 * width, 1, &t, out.baseAddress! + y * width, 1, vDSP_Length(width))
                }
            }
        }
        edgeAlpha(&v, width: width, height: height)
        return SubjectMatte(width: width, height: height, values: v)
    }

    /// `SubjectTrackRules.edgeAlpha` in place, with the same arithmetic in whole-plane operations.
    static func edgeAlpha(_ v: inout [Float], width w: Int, height h: Int) {
        let n = w * h
        var gx = [Float](repeating: 0, count: n), gy = gx
        v.withUnsafeBufferPointer { src in
            gx.withUnsafeMutableBufferPointer { dx in
                gy.withUnsafeMutableBufferPointer { dy in
                    let s = src.baseAddress!, x = dx.baseAddress!, y = dy.baseAddress!
                    var two: Float = 2
                    if w >= 2 {
                        for r in 0..<h {
                            let row = s + r * w, out = x + r * w
                            // vDSP_vsub(B, A): A - B.
                            if w > 2 { vDSP_vsub(row, 1, row + 2, 1, out + 1, 1, vDSP_Length(w - 2)) }
                            out[0] = 2 * (row[1] - row[0]); out[w - 1] = 2 * (row[w - 1] - row[w - 2])
                        }
                    }
                    if h >= 2 {
                        if h > 2 { vDSP_vsub(s, 1, s + 2 * w, 1, y + w, 1, vDSP_Length((h - 2) * w)) }
                        vDSP_vsub(s, 1, s + w, 1, y, 1, vDSP_Length(w))
                        vDSP_vsmul(y, 1, &two, y, 1, vDSP_Length(w))
                        vDSP_vsub(s + (h - 2) * w, 1, s + (h - 1) * w, 1, y + (h - 1) * w, 1, vDSP_Length(w))
                        vDSP_vsmul(y + (h - 1) * w, 1, &two, y + (h - 1) * w, 1, vDSP_Length(w))
                    }
                }
            }
        }
        // slope = max(sqrt(gx^2 + gy^2) / 2, floor), then alpha = v / slope / edge width + 0.5, within 0...1.
        vDSP_vsq(gx, 1, &gx, 1, vDSP_Length(n))
        vDSP_vsq(gy, 1, &gy, 1, vDSP_Length(n))
        vDSP_vadd(gx, 1, gy, 1, &gx, 1, vDSP_Length(n))
        var count = Int32(n)
        vvsqrtf(&gx, gx, &count)
        var half: Float = 0.5, floor = SubjectTrackRules.matteSlopeFloor, k = 1 / SubjectTrackRules.matteEdgeWidth
        vDSP_vsmul(gx, 1, &half, &gx, 1, vDSP_Length(n))
        vDSP_vthr(gx, 1, &floor, &gx, 1, vDSP_Length(n))
        vDSP_vdiv(gx, 1, v, 1, &v, 1, vDSP_Length(n))
        vDSP_vsmsa(v, 1, &k, &half, &v, 1, vDSP_Length(n))
        var zero: Float = 0, one: Float = 1
        vDSP_vclip(v, 1, &zero, &one, &v, 1, vDSP_Length(n))
    }
}
