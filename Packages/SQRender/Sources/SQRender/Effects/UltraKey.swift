import Foundation
import SQCore
import simd

/// Ultra Key: a compact chroma key on the un-premultiplied working-linear colour. CPU reference of `applyChromaKey` in the
/// compositor shader; the parity test compares the two.
///
/// Per pixel: hue and saturation of the colour; `K` = how much it belongs to the key colour (1 inside `halfWidth` degrees of
/// the key hue, falling to 0 over `soft` more degrees, weighted down for grey and for near-black pixels, whose hue is noise).
/// The pixel's alpha is multiplied by `1 - K`. Spill suppression desaturates the colour towards its luma in a wider zone
/// around the key hue, in proportion to `spill` and to how little of the pixel was keyed.
public enum UltraKey {
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Hue in degrees (0..<360), saturation and value (max channel) of linear rgb.
    public static func hsv(_ c: SIMD3<Float>) -> (h: Float, s: Float, v: Float) {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z)), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// Applies one key: returns the (spill-suppressed) colour and `K`.
    public static func key(_ c: SIMD3<Float>, hue: Float, halfWidth: Float, soft: Float, spill: Float) -> (color: SIMD3<Float>, k: Float) {
        let (h, s, v) = hsv(c)
        var dist = abs(h - hue)
        dist = min(dist, 360 - dist)
        let weight = smoothstep(0.08, 0.3, s) * smoothstep(0.001, 0.01, v)
        let inside = 1 - smoothstep(halfWidth, halfWidth + soft, dist)
        let k = inside * weight
        let zone = 1 - smoothstep(halfWidth + soft, 2 * halfWidth + soft + 20, dist)
        let w = spill * zone * weight * (1 - k)
        let luma = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        let out = c + (SIMD3<Float>(repeating: luma) - c) * w
        return (out, k)
    }

    /// All keys in order over un-premultiplied `rgb` with `alpha`.
    public static func apply(rgb: SIMD3<Float>, alpha: Float, keys: [ChromaKey]) -> (rgb: SIMD3<Float>, alpha: Float) {
        var c = rgb, a = alpha
        for k in keys.prefix(ChromaKey.maxPerLayer) {
            let r = key(c, hue: Float(k.hue), halfWidth: Float(k.halfWidth), soft: Float(k.soft), spill: Float(k.spill))
            c = r.color
            a *= 1 - r.k
        }
        return (c, a)
    }

    /// The uniform vector the shader reads for one key: hue, half width, soft edge, spill.
    static func vector(_ k: ChromaKey) -> SIMD4<Float> {
        SIMD4(Float(k.hue), Float(k.halfWidth), Float(k.soft), Float(k.spill))
    }
}
