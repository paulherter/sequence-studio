import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

/// Crop and Rounded Corners as one coverage mask on the layer rectangle. CPU reference of the mask in
/// `compositeFragment` (same signed distance to a rounded rectangle, same one pixel anti-aliasing ramp, widened inwards by
/// the Crop Softness `feather`).
public enum CropMask {
    /// The kept rectangle in layer-local coordinates (origin at the layer center, y down).
    public static func keptRect(size: SIMD2<Float>, crop: CropInsets) -> (lo: SIMD2<Float>, hi: SIMD2<Float>) {
        let lo = -0.5 * size + SIMD2(Float(crop.left), Float(crop.top)) * size
        let hi = 0.5 * size - SIMD2(Float(crop.right), Float(crop.bottom)) * size
        return (lo, hi)
    }

    /// Signed distance (layer px, negative inside) of `p` to the kept rectangle with rounded corners.
    public static func signedDistance(_ p: SIMD2<Float>, size: SIMD2<Float>, crop: CropInsets, cornerRadius: Float,
                                      roundFirst: Bool = false) -> Float {
        let (lo, hi) = keptRect(size: size, crop: crop)
        let c = 0.5 * (lo + hi), h = 0.5 * (hi - lo)
        if roundFirst {
            // Rounded Corners, then Crop: the rounded full frame intersected with the straight crop rectangle.
            let d0 = signedDistance(p, size: size, crop: .none, cornerRadius: cornerRadius)
            let q1 = simd_abs(p - c) - h
            let d1 = simd_length(simd_max(q1, SIMD2(repeating: 0))) + min(max(q1.x, q1.y), 0)
            return max(d0, d1)
        }
        let r = min(cornerRadius, min(h.x, h.y))
        let q = simd_abs(p - c) - h + SIMD2(repeating: r)
        let outside = simd_length(simd_max(q, SIMD2(repeating: 0)))
        return outside + min(max(q.x, q.y), 0) - r
    }

    /// Coverage 0...1 at `p` for an axis-aligned layer drawn at scale 1 (one layer px per screen px). `feather` (layer px)
    /// widens the ramp inwards: 0 outside, full `feather` + 0.5 px inside the edge (0 = the one pixel edge).
    public static func coverage(_ p: SIMD2<Float>, size: SIMD2<Float>, crop: CropInsets, cornerRadius: Float,
                                roundFirst: Bool = false, feather: Float = 0) -> Float {
        let d = signedDistance(p, size: size, crop: crop, cornerRadius: cornerRadius, roundFirst: roundFirst)
        return min(max((0.5 - d) / (1 + max(feather, 0)), 0), 1)
    }

    /// Applies the mask to premultiplied pixels (row-major, `width` x `height`), pixel centers sampled.
    /// Identity crop and radius 0 touch nothing.
    public static func apply(_ px: inout [SIMD4<Float>], width: Int, height: Int, crop: CropInsets, cornerRadius: Float,
                             roundFirst: Bool = false, feather: Float = 0) {
        guard !crop.isIdentity || cornerRadius > 0 || feather > 0 else { return }
        let size = SIMD2(Float(width), Float(height))
        for y in 0..<height {
            for x in 0..<width {
                let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - 0.5 * size
                px[y * width + x] *= coverage(p, size: size, crop: crop, cornerRadius: cornerRadius, roundFirst: roundFirst,
                                                     feather: feather)
            }
        }
    }
}
