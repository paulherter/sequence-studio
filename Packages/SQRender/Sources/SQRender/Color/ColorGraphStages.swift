import Foundation
#if canImport(simd)
import simd
#endif
import SQCore

// Pro grade (Color Graph) blocks. A Step lowers to: [step begin] primaries, curves, hue curves, LUT [step end]. The begin /
// end pair only exists when the Step is limited by a qualifier or a window: begin keeps the Step's input (`n0`), end mixes
// the Step's result back over it by the matte (qualifier on the input color x window on the pixel position). A begin /
// end pair always lands in one GPU pass (`ColorPipelineGPU.passes(for:)`), so `n0` lives in a register.

/// Step primaries on the display signal: lift, gain, offset, power (gamma) per channel, contrast about a pivot, then
/// saturation about the Rec.709 luma. Lift 0, contrast 1 = the ASC CDL.
struct PreparedPrimaries: Sendable, Equatable {
    let lift: SIMD3<Float>, gamma: SIMD3<Float>, gain: SIMD3<Float>, offset: SIMD3<Float>
    let contrast: Float, pivot: Float, saturation: Float
    let hasGamma: Bool, hasContrast: Bool, hasSaturation: Bool
    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    init(_ p: StepPrimaries) {
        lift = SIMD3(p.lift.r, p.lift.g, p.lift.b); gamma = SIMD3(p.gamma.r, p.gamma.g, p.gamma.b)
        gain = SIMD3(p.gain.r, p.gain.g, p.gain.b); offset = SIMD3(p.offset.r, p.offset.g, p.offset.b)
        contrast = p.contrast; pivot = p.pivot; saturation = p.saturation
        hasGamma = gamma != SIMD3(repeating: 1); hasContrast = contrast != 1; hasSaturation = saturation != 1
    }

    /// Bit 0 gamma, bit 1 contrast, bit 2 saturation (s.head.z).
    var flags: UInt32 { (hasGamma ? 1 : 0) | (hasContrast ? 2 : 0) | (hasSaturation ? 4 : 0) }

    func apply(_ c: SIMD3<Float>, pre: Bool) -> SIMD3<Float> {
        var t = pre ? TransferFunctions.bt709OETF(c) : c
        t = t + lift * (SIMD3(repeating: 1) - t)
        t = t * gain + offset
        if hasGamma {
            for i in 0..<3 where t[i] > 0 && gamma[i] != 1 { t[i] = powf(t[i], gamma[i]) }
        }
        if hasContrast { t = (t - SIMD3(repeating: pivot)) * contrast + SIMD3(repeating: pivot) }
        if hasSaturation {
            let y = simd_dot(Self.luma, t)
            t = SIMD3(repeating: y) + (t - SIMD3(repeating: y)) * saturation
        }
        return pre ? TransferFunctions.bt709InverseOETF(t) : t
    }
}

/// A Step window: an ellipse, a rectangle or a straight edge in picture space (uv 0…1, y down), rotated clockwise about
/// its center, with a soft edge. Width is a fraction of the picture width, height of its height.
struct PreparedWindow: Sendable, Equatable {
    let center: SIMD2<Float>
    let half: SIMD2<Float>
    let cosR: Float, sinR: Float
    let soft: Float
    /// 0 ellipse, 1 rectangle, 2 linear.
    let shape: Float
    let invert: Bool

    init(_ w: StepWindow) {
        center = SIMD2(w.centerX, w.centerY)
        half = SIMD2(max(w.width, 0) / 2, max(w.height, 0) / 2)
        let r = w.rotation * Float.pi / 180
        cosR = cosf(r); sinR = sinf(r)
        soft = min(max(w.softness, 1e-3), 1)
        shape = switch w.shape { case .ellipse: 0; case .rectangle: 1; case .linear: 2 }
        invert = w.invert
    }

    /// Columns of `Sec.m`: (cx, cy, half x), (half y, cos, sin), (soft, shape, invert).
    var matrix: simd_float3x3 {
        simd_float3x3(SIMD3(center.x, center.y, half.x), SIMD3(half.y, cosR, sinR), SIMD3(soft, shape, invert ? 1 : 0))
    }

    func mask(uv: SIMD2<Float>, aspect: Float) -> Float {
        let px = (uv.x - center.x) * aspect, py = uv.y - center.y
        let qx = px * cosR + py * sinR, qy = -px * sinR + py * cosR
        let hx = max(half.x * aspect, 1e-5), hy = max(half.y, 1e-5)
        var m: Float
        if shape < 0.5 {
            let ex = qx / hx, ey = qy / hy
            m = 1 - ToneMath.smooth(1 - soft, 1, (ex * ex + ey * ey).squareRoot())
        } else if shape < 1.5 {
            m = 1 - ToneMath.smooth(1 - soft, 1, max(fabsf(qx) / hx, fabsf(qy) / hy))
        } else {
            let e = max(soft * hy, 1e-4)
            m = 1 - ToneMath.smooth(-e, e, qy)
        }
        return invert ? 1 - m : m
    }
}

/// One key wire arriving at a Step or a mixer box: the donor Step's key output (its qualifier and window), optionally
/// inverted ("outside"). `mode` combines it with the wires before it; nil = the first wire, it sets the matte.
/// shortcut: the donor's qualifier is evaluated on the receiving Step's input, not on the donor's own input (the geometric
/// window is exact); upgrade when a Step's input can be kept per donor.
public struct KeyTerm: Sendable {
    public var qualifier: ColorQualifier?
    public var window: StepWindow?
    public var outside: Bool
    public var mode: KeyMixMode?
    public init(qualifier: ColorQualifier?, window: StepWindow?, outside: Bool = false, mode: KeyMixMode? = nil) {
        self.qualifier = qualifier; self.window = window; self.outside = outside; self.mode = mode
    }
}

/// A `KeyTerm` on the display signal (the constants the CPU maths and the GPU section share).
struct PreparedKeyTerm: Sendable, Equatable {
    let qualifier: PreparedHSLSecondary?
    let window: PreparedWindow?
    let outside: Bool
    /// 0 sets the matte (first wire), 1 add, 2 multiply, 3 subtract, 4 max.
    let mode: UInt32

    init(_ k: KeyTerm) {
        qualifier = k.qualifier.map { PreparedHSLSecondary($0.asColorRange, gamut: .rec709) }
        window = k.window.map(PreparedWindow.init)
        outside = k.outside
        mode = switch k.mode { case nil: 0; case .add?: 1; case .multiply?: 2; case .subtract?: 3; case .max?: 4 }
    }

    /// Bit 0 qualifier, bit 1 window, bit 2 outside, bits 5...7 mode (s.head.z).
    var flags: UInt32 { (qualifier != nil ? 1 : 0) | (window != nil ? 2 : 0) | (outside ? 4 : 0) | (mode << 5) }

    /// `km`: the matte so far; `input`: the receiving Step's input (`n0`).
    func apply(_ km: Float, input n0: SIMD3<Float>, uv: SIMD2<Float>, aspect: Float, pre: Bool) -> Float {
        var m: Float = 1
        if let qualifier { m = qualifier.mask(pre ? TransferFunctions.bt709OETF(n0) : n0) }
        if let window { m *= window.mask(uv: uv, aspect: aspect) }
        if outside { m = 1 - m }
        switch mode {
        case 1: return min(km + m, 1)
        case 2: return km * m
        case 3: return max(km - m, 0)
        case 4: return max(km, m)
        default: return m
        }
    }
}

/// The end of a limited Step: how much of the Step's result each pixel keeps.
struct PreparedStepMatte: Sendable, Equatable {
    let qualifier: PreparedHSLSecondary?
    let window: PreparedWindow?
    /// 0...1, scales the matte (bit 2 of `flags` when below 1).
    let mix: Float
    /// Key terms came before this end: the matte is also scaled by the key register (bit 4 of `flags`).
    let keyed: Bool
    /// Layer mix of a layer branch (bits 5...7 of `flags`).
    let blend: LayerMixMode

    init(qualifier: ColorQualifier?, window: StepWindow?, mix: Float = 1, keyed: Bool = false, blend: LayerMixMode = .normal) {
        self.mix = min(max(mix, 0), 1)
        self.qualifier = qualifier.map { PreparedHSLSecondary($0.asColorRange, gamut: .rec709) }
        self.window = window.map(PreparedWindow.init)
        self.keyed = keyed
        self.blend = blend
    }

    var blendIndex: UInt32 {
        switch blend { case .normal: 0; case .add: 1; case .subtract: 2; case .multiply: 3; case .screen: 4; case .lighten: 5; case .darken: 6 }
    }

    /// Bit 0 qualifier, bit 1 window (s.head.z).
    /// Bit 2 mix below 1, bit 4 keyed, bits 5...7 Layer mix (bit 3 is the layer branch, set by the GPU encoder).
    var flags: UInt32 {
        (qualifier != nil ? 1 : 0) | (window != nil ? 2 : 0) | (mix < 1 ? 4 : 0) | (keyed ? 16 : 0) | (blendIndex << 5)
    }

    /// `input`: the Step's input (`n0`), `c`: its result, both in the same domain. `key`: the key register (1 = none).
    func apply(_ c: SIMD3<Float>, input n0: SIMD3<Float>, uv: SIMD2<Float>, aspect: Float, pre: Bool, key: Float = 1) -> SIMD3<Float> {
        n0 + (c - n0) * (matte(input: n0, uv: uv, aspect: aspect, pre: pre) * key)
    }

    /// The key (qualifier on the input, window) times the mix.
    func matte(input n0: SIMD3<Float>, uv: SIMD2<Float>, aspect: Float, pre: Bool) -> Float {
        var m: Float = 1
        if let qualifier { m = qualifier.mask(pre ? TransferFunctions.bt709OETF(n0) : n0) }
        if let window { m *= window.mask(uv: uv, aspect: aspect) }
        if mix < 1 { m *= mix }
        return m
    }

    /// A layer's result `c` composited over `acc` (what is below it), before the key sets the strength.
    func composite(_ c: SIMD3<Float>, over acc: SIMD3<Float>) -> SIMD3<Float> {
        switch blend {
        case .normal: c
        case .add: acc + c
        case .subtract: acc - c
        case .multiply: acc * c
        case .screen: SIMD3<Float>(repeating: 1) - (SIMD3<Float>(repeating: 1) - acc) * (SIMD3<Float>(repeating: 1) - c)
        case .lighten: simd_max(acc, c)
        case .darken: simd_min(acc, c)
        }
    }
}
