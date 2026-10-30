import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

/// Opacity blend modes. The CPU maths here is the reference the Metal shader (`compositeFragmentBlend`) is tested against.
///
/// Everything is premultiplied and works in the compositor's working-linear space (Rec.709 primaries, scene-linear, half
/// float). Premiere and Photoshop blend gamma-encoded values, so the contrast modes (Overlay, Soft/Hard/Vivid/Linear/Pin
/// Light, Hard Mix) split at linear 0.5 rather than at encoded mid gray; Multiply, Screen, Darken/Lighten and the
/// Component modes of black, white and pure hues agree. See DECISIONS "Blend parity".
///
/// With source `S = (Cs, as)` and destination `D = (Cd, ad)` (premultiplied), `cs` and `cd` the un-premultiplied colors:
///     rgb = Cs (1 - ad) + Cd (1 - as) + as ad B(cd, cs)        a = as + ad (1 - as)
/// Normal is B = cs, which gives the plain alpha-over. Add is not clamped: the target is half float.
///
/// The Component modes (Hue, Saturation, Color, Luminosity) and Darker/Lighter Color are non-separable: they use the
/// W3C SetLum/SetSat/ClipColor construction with Rec.709 luminance weights (correct for linear light; the W3C
/// 0.3/0.59/0.11 are Rec.601 weights meant for encoded values). ClipColor folds out-of-gamut results back towards the
/// luminance; the upper fold only applies when the luminance itself is below 1, so HDR highlights stay bright.
///
/// Dissolve replaces the source's coverage by a fixed per-pixel pattern: a pixel shows the source fully when its hash is
/// below the source alpha, else not at all (`dissolveThreshold`).
public enum BlendModes {
    /// The id the shader switches on (0 = normal). Ids are stable within one build only (not stored).
    public static func shaderID(_ m: BlendMode) -> UInt32 {
        switch m {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .add: 3
        case .overlay: 4
        case .darken: 5
        case .lighten: 6
        case .colorDodge: 7
        case .colorBurn: 8
        case .linearBurn: 9
        case .hardLight: 10
        case .softLight: 11
        case .difference: 12
        case .exclusion: 13
        case .dissolve: 14
        case .vividLight: 15
        case .linearLight: 16
        case .pinLight: 17
        case .hardMix: 18
        case .subtract: 19
        case .divide: 20
        case .darkerColor: 21
        case .lighterColor: 22
        case .hue: 23
        case .saturation: 24
        case .color: 25
        case .luminosity: 26
        }
    }

    /// The shader id of a footage-fill draw (`RenderLayer.stencil`); not a `BlendMode`, never stored.
    public static let stencilShaderID: UInt32 = 27

    /// CPU reference of the stencil draw: the destination kept by the matte's coverage `s.a` (already times `opacity`),
    /// `opacity` of it mixed with the untouched destination: `d * (1 - opacity + s.a)`.
    public static func stencil(source s: SIMD4<Float>, destination d: SIMD4<Float>, opacity: Float) -> SIMD4<Float> {
        d * (1 - opacity + s.w)
    }

    /// Rec.709 luminance weights (linear light).
    public static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// B(cd, cs) for the whole color (cd = backdrop, cs = source).
    public static func channel(_ m: BlendMode, backdrop cd: SIMD3<Float>, source cs: SIMD3<Float>) -> SIMD3<Float> {
        switch m {
        case .darkerColor: return lum(cs) < lum(cd) ? cs : cd
        case .lighterColor: return lum(cs) > lum(cd) ? cs : cd
        case .hue: return setLum(setSat(cs, sat(cd)), lum(cd))
        case .saturation: return setLum(setSat(cd, sat(cs)), lum(cd))
        case .color: return setLum(cs, lum(cd))
        case .luminosity: return setLum(cd, lum(cs))
        default: return SIMD3(scalar(m, cd.x, cs.x), scalar(m, cd.y, cs.y), scalar(m, cd.z, cs.z))
        }
    }

    /// One channel of B(cd, cs) for the separable modes (W3C compositing spec / Photoshop definitions). Add is not
    /// clamped; Color Dodge and Color Burn saturate at 1 and 0 as in every editor. Non-separable modes return `cs`.
    public static func scalar(_ m: BlendMode, _ cd: Float, _ cs: Float) -> Float {
        switch m {
        case .normal, .dissolve: return cs
        case .multiply: return cd * cs
        case .screen: return cd + cs - cd * cs
        case .add: return cd + cs
        case .overlay: return scalar(.hardLight, cs, cd)
        case .darken: return min(cd, cs)
        case .lighten: return max(cd, cs)
        case .colorDodge:
            if cd <= 0 { return 0 }
            if cs >= 1 { return 1 }
            return min(1, cd / (1 - cs))
        case .colorBurn:
            if cd >= 1 { return 1 }
            if cs <= 0 { return 0 }
            return 1 - min(1, (1 - cd) / cs)
        case .linearBurn: return max(0, cd + cs - 1)
        case .hardLight: return cs <= 0.5 ? cd * 2 * cs : scalar(.screen, cd, 2 * cs - 1)
        case .softLight:
            if cs <= 0.5 { return cd - (1 - 2 * cs) * cd * (1 - cd) }
            let d = cd <= 0.25 ? ((16 * cd - 12) * cd + 4) * cd : max(cd, 0).squareRoot()
            return cd + (2 * cs - 1) * (d - cd)
        case .difference: return abs(cd - cs)
        case .exclusion: return cd + cs - 2 * cd * cs
        case .vividLight: return cs <= 0.5 ? scalar(.colorBurn, cd, 2 * cs) : scalar(.colorDodge, cd, 2 * cs - 1)
        case .linearLight: return max(0, cd + 2 * cs - 1)
        case .pinLight: return cs <= 0.5 ? min(cd, 2 * cs) : max(cd, 2 * cs - 1)
        case .hardMix: return cd + cs >= 1 ? 1 : 0
        case .subtract: return max(0, cd - cs)
        case .divide:
            if cs <= 0 { return cd > 0 ? 1 : 0 }
            return min(cd / cs, max(1, cd))
        case .darkerColor, .lighterColor, .hue, .saturation, .color, .luminosity: return cs
        }
    }

    // MARK: Non-separable helpers (W3C compositing spec, Rec.709 weights)

    public static func lum(_ c: SIMD3<Float>) -> Float { c.x * lumaWeights.x + c.y * lumaWeights.y + c.z * lumaWeights.z }

    static func clipColor(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = lum(c)
        let n = min(c.x, min(c.y, c.z)), x = max(c.x, max(c.y, c.z))
        var out = c
        if n < 0 { out = l + (out - l) * (l / max(l - n, 1e-6)) }
        if l < 1 && x > 1 { out = l + (out - l) * ((1 - l) / max(x - l, 1e-6)) }
        return out
    }

    static func setLum(_ c: SIMD3<Float>, _ l: Float) -> SIMD3<Float> { clipColor(c + (l - lum(c))) }

    static func sat(_ c: SIMD3<Float>) -> Float { max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z)) }

    /// The color with its saturation (max - min) set to `s`, keeping which channel is largest/middle/smallest.
    static func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let range = mx - mn
        guard range > 0 else { return .zero }
        return (c - mn) * (s / range)
    }

    // MARK: Dissolve

    /// The fixed per-pixel threshold of Dissolve in [0, 1): a 32-bit integer hash (lowbias32) of the pixel position, top
    /// 24 bits. The shader runs the same integer ops, so CPU and GPU pick the same pixels.
    public static func dissolveThreshold(x: Int, y: Int) -> Float {
        var h = (UInt32(truncatingIfNeeded: x) &* 0x9E37_79B9) ^ (UInt32(truncatingIfNeeded: y) &* 0x85EB_CA6B)
        h ^= h >> 16; h = h &* 0x7FEB_352D
        h ^= h >> 15; h = h &* 0x846C_A68B
        h ^= h >> 16
        return Float(h >> 8) / 16_777_216
    }

    /// Source over destination, both premultiplied rgba. `x`, `y`: the pixel (only Dissolve reads it).
    public static func blend(_ m: BlendMode, source s: SIMD4<Float>, destination d: SIMD4<Float>, x: Int = 0, y: Int = 0) -> SIMD4<Float> {
        var s = s
        if m == .dissolve {
            let cs = s.w > 0 ? SIMD3<Float>(s.x, s.y, s.z) / s.w : SIMD3<Float>(repeating: 0)
            s = dissolveThreshold(x: x, y: y) < s.w ? SIMD4(cs.x, cs.y, cs.z, 1) : .zero
        }
        let sc = SIMD3<Float>(s.x, s.y, s.z), dc = SIMD3<Float>(d.x, d.y, d.z)
        let cs = s.w > 0 ? sc / s.w : SIMD3<Float>(repeating: 0)
        let cd = d.w > 0 ? dc / d.w : SIMD3<Float>(repeating: 0)
        let b = channel(m, backdrop: cd, source: cs)
        let rgb = sc * (1 - d.w) + dc * (1 - s.w) + s.w * d.w * b
        return SIMD4(rgb.x, rgb.y, rgb.z, s.w + d.w * (1 - s.w))
    }
}
