import Foundation
import SQCore
import simd

/// Opacity blend modes. The CPU maths here is the reference the Metal shader (`compositeFragmentBlend`) is tested against.
///
/// Everything is premultiplied and works in the compositor's working-linear space (Rec.709 primaries). Premiere blends in
/// its own (often gamma-encoded) space, so Overlay in particular looks different near mid grey; Multiply and Screen of
/// black and white agree.
///
/// With source `S = (Cs, as)` and destination `D = (Cd, ad)` (premultiplied), `cs` and `cd` the un-premultiplied colours:
///     rgb = Cs (1 - ad) + Cd (1 - as) + as ad B(cd, cs)        a = as + ad (1 - as)
/// Normal is B = cs, which gives the plain alpha-over. Add (Linear Dodge) is not clamped: the target is half float.
public enum BlendModes {
    /// The id the shader switches on (0 = normal).
    public static func shaderID(_ m: BlendMode) -> UInt32 {
        switch m {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .add: 3
        case .overlay: 4
        }
    }

    /// B(cd, cs) per channel (cd = backdrop, cs = source).
    public static func channel(_ m: BlendMode, backdrop cd: SIMD3<Float>, source cs: SIMD3<Float>) -> SIMD3<Float> {
        switch m {
        case .normal: return cs
        case .multiply: return cd * cs
        case .screen: return cd + cs - cd * cs
        case .add: return cd + cs
        case .overlay:
            let lo = 2 * cd * cs
            let hi = SIMD3<Float>(repeating: 1) - 2 * (SIMD3<Float>(repeating: 1) - cd) * (SIMD3<Float>(repeating: 1) - cs)
            return SIMD3<Float>(cd.x <= 0.5 ? lo.x : hi.x, cd.y <= 0.5 ? lo.y : hi.y, cd.z <= 0.5 ? lo.z : hi.z)
        }
    }

    /// Source over destination, both premultiplied rgba.
    public static func blend(_ m: BlendMode, source s: SIMD4<Float>, destination d: SIMD4<Float>) -> SIMD4<Float> {
        let sc = SIMD3<Float>(s.x, s.y, s.z), dc = SIMD3<Float>(d.x, d.y, d.z)
        let cs = s.w > 0 ? sc / s.w : SIMD3<Float>(repeating: 0)
        let cd = d.w > 0 ? dc / d.w : SIMD3<Float>(repeating: 0)
        let b = channel(m, backdrop: cd, source: cs)
        let rgb = sc * (1 - d.w) + dc * (1 - s.w) + s.w * d.w * b
        return SIMD4(rgb.x, rgb.y, rgb.z, s.w + d.w * (1 - s.w))
    }
}
