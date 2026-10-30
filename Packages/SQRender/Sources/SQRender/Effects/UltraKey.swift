import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

/// The key family on the un-premultiplied working-linear color: Ultra Key (chroma) and Luma Key. CPU reference of
/// `applyChromaKey` in the compositor shader; the parity test compares the two.
///
/// Chroma, per pixel: hue and saturation of the color; `K` = how much it belongs to the key color (1 inside `halfWidth`
/// degrees of the key hue, falling to 0 over `soft` more degrees, weighted down for gray and for near-black pixels, whose
/// hue is noise). Keep Highlights / Keep Shadows hold back the key on bright / dark pixels. Spill suppression desaturates
/// the color towards its luma in a wider zone around the key hue, in proportion to `spill` and to how little of the pixel
/// was keyed; then the color correction (saturation, hue shift, brightness) runs on what is kept.
/// Luma: `K` = 1 below the threshold of the encoded luma (above it for "brights"), falling to 0 over `softness`.
/// Both: pedestal, then the shared `MatteRefine.tone` (shrink / grow, contrast, midpoint) on the kept share 1 - K.
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

    /// Matte shaping of the keyed share `k`: the pedestal first drops weak keying, then the shared refine (shrink / grow,
    /// contrast, midpoint) works on coverage 1 - k. All neutral returns `k` unchanged. Mirrors `shapeMatte` in the shader.
    static func shape(_ k: Float, choke: Float, pedestal: Float, contrast: Float = 0, midpoint: Float = 0.5) -> Float {
        var m = k
        if pedestal > 0 { m = min(max((m - pedestal) / max(1 - pedestal, 1e-4), 0), 1) }
        if choke != 0 || contrast > 0 {
            let r = MatteRefine(shrink: Double(choke), contrast: Double(contrast), midpoint: Double(midpoint))
            m = 1 - r.toneF(1 - m)
        }
        return m
    }

    /// Saturation, hue shift (rotation about the gray axis, radians) and brightness factor on linear rgb.
    static func correct(_ c: SIMD3<Float>, saturation: Float, hueRadians: Float, luma: Float) -> SIMD3<Float> {
        var o = c
        let y = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        o = SIMD3(repeating: y) + (o - SIMD3(repeating: y)) * saturation
        if hueRadians != 0 {
            let cs = cosf(hueRadians), sn = sinf(hueRadians)
            let ax = SIMD3<Float>(repeating: 0.57735027)
            let cross = SIMD3(ax.y * o.z - ax.z * o.y, ax.z * o.x - ax.x * o.z, ax.x * o.y - ax.y * o.x)
            o = o * cs + cross * sn + ax * (simd_dot(ax, o) * (1 - cs))
        }
        return o * luma
    }

    /// Applies one chroma key: returns the (spill-suppressed) color and `K`.
    public static func key(_ c: SIMD3<Float>, hue: Float, halfWidth: Float, soft: Float, spill: Float,
                           choke: Float = 0, pedestal: Float = 0) -> (color: SIMD3<Float>, k: Float) {
        key(c, ChromaKey(hue: Double(hue), halfWidth: Double(halfWidth), soft: Double(soft), spill: Double(spill),
                         choke: Double(choke), pedestal: Double(pedestal)))
    }

    /// Applies one key of either mode: returns the color after spill suppression / color correction and `K`.
    public static func key(_ c: SIMD3<Float>, _ k: ChromaKey) -> (color: SIMD3<Float>, k: Float) {
        let choke = Float(k.choke), pedestal = Float(k.pedestal), contrast = Float(k.contrast), midpoint = Float(k.midpoint)
        if k.mode == .luma {
            let y = min(max(c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722, 0), 1).squareRoot()
            let yy = k.lumaKeysBrights ? 1 - y : y
            let tt = k.lumaKeysBrights ? 1 - Float(k.lumaThreshold) : Float(k.lumaThreshold)
            let raw = 1 - smoothstep(tt, tt + max(Float(k.lumaSoftness), 1e-4), yy)
            return (c, shape(raw, choke: choke, pedestal: pedestal, contrast: contrast, midpoint: midpoint))
        }
        let hue = Float(k.hue), halfWidth = Float(k.halfWidth), soft = Float(k.soft)
        let (h, s, v) = hsv(c)
        var dist = abs(h - hue)
        dist = min(dist, 360 - dist)
        let weight = smoothstep(0.08, 0.3, s) * smoothstep(0.001, 0.01, v)
        let inside = 1 - smoothstep(halfWidth, halfWidth + soft, dist)
        var raw = inside * weight
        if k.keepHighlights > 0 || k.keepShadows > 0 {
            let keep = min(Float(k.keepHighlights) * smoothstep(0.5, 1, v) + Float(k.keepShadows) * (1 - smoothstep(0.02, 0.3, v)), 1)
            raw *= 1 - keep
        }
        let keyed = shape(raw, choke: choke, pedestal: pedestal, contrast: contrast, midpoint: midpoint)
        let zone = 1 - smoothstep(halfWidth + soft, 2 * halfWidth + soft + Float(k.spillRange) * 40, dist)
        let w = Float(k.spill) * zone * weight * (1 - raw)
        let luma = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        var out = c + (SIMD3<Float>(repeating: luma) - c) * w
        if k.correctsColor {
            out = correct(out, saturation: Float(k.saturation), hueRadians: Float(k.hueShift) * .pi / 180, luma: Float(k.luma))
        }
        return (out, keyed)
    }

    /// All keys in order over un-premultiplied `rgb` with `alpha`.
    public static func apply(rgb: SIMD3<Float>, alpha: Float, keys: [ChromaKey]) -> (rgb: SIMD3<Float>, alpha: Float) {
        var c = rgb, a = alpha, kept: Float = 1
        var matte = false
        for k in keys.prefix(ChromaKey.maxPerLayer) {
            if k.output == .source { continue }                       // Source: the picture before keying
            let r = key(c, k)
            c = r.color
            a *= 1 - r.k
            kept *= 1 - r.k
            if k.output == .alpha { matte = true }
        }
        // Matte view: the kept share as gray, the layer's own coverage unchanged.
        if matte { return (SIMD3(repeating: kept), alpha) }
        return (c, a)
    }

    /// The matte vector the shader reads for one key: shrink / grow, pedestal, output (0 composite, 1 alpha, 2 source), mode.
    static func matteVector(_ k: ChromaKey) -> SIMD4<Float> {
        SIMD4(Float(k.choke), Float(k.pedestal), Float(k.output.rawValue), Float(k.mode.rawValue))
    }

    /// Matte generation / clean-up vector: contrast, midpoint, keep highlights, keep shadows.
    static func shapeVector(_ k: ChromaKey) -> SIMD4<Float> {
        SIMD4(Float(k.contrast), Float(k.midpoint), Float(k.keepHighlights), Float(k.keepShadows))
    }

    /// Color vector: saturation, hue shift (radians), brightness, spill range. `correct` runs only when saturation or
    /// brightness is not 1 or the hue shift is not 0 (the shader tests the same).
    static func colorVector(_ k: ChromaKey) -> SIMD4<Float> {
        SIMD4(Float(k.saturation), Float(k.hueShift) * .pi / 180, Float(k.luma), Float(k.spillRange))
    }

    /// The uniform vector the shader reads for one key: chroma = hue, half width, soft edge, spill; luma = threshold,
    /// softness, keys-brights flag, 0.
    static func vector(_ k: ChromaKey) -> SIMD4<Float> {
        if k.mode == .luma { return SIMD4(Float(k.lumaThreshold), Float(k.lumaSoftness), k.lumaKeysBrights ? 1 : 0, 0) }
        return SIMD4(Float(k.hue), Float(k.halfWidth), Float(k.soft), Float(k.spill))
    }
}
