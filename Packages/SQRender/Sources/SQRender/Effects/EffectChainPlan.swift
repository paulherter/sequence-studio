import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

/// The plan of a layer's effect chain (`Compositor.finishLayer`, `GPUCompositor.finishLayer`): working sizes, pass budgets
/// and the uniforms each segment writes. Pure, shared by the Metal and the portable compositor.
extension Compositor {
    /// The media identity every masked Color effect's pipeline is keyed under (it has no media of its own); engines warm
    /// the resolver with `maskedGradeColor(_:)` under this id.
    public static let maskedGradeMedia = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    /// The clip color a masked Color effect is graded with: Rec.709 in, the neutral first effect, then the effect.
    public static func maskedGradeColor(_ grade: ColorEffect) -> ClipColor {
        ClipColor(source: .rec709, useEmbeddedLUT: false, effects: [ColorEffect(id: 0), grade])
    }
    /// The resolver's fallback slot: keyed by the LUTs the effect references (never by `ColorEffect.id`, which is only the
    /// effect's index inside its clip), so a clip loading its LUT can never fall back to another clip's LUT.
    static func maskedGradeOwner(_ grade: ColorEffect) -> UUID {
        var h1 = Hasher(), h2 = Hasher()
        h1.combine(grade.inputLUT); h1.combine(grade.creative.look)
        h2.combine(1); h2.combine(grade.creative.look); h2.combine(grade.inputLUT)
        var b = [UInt8](repeating: 0, count: 16)
        for (i, v) in [h1.finalize(), h2.finalize()].enumerated() {
            for k in 0..<8 { b[i * 8 + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
        }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Working-texture pixel cap of a pass: Long Shadow and Outline can ask for a huge margin (length / width up to
    /// thousands of px), so their margin is held to `GaussianBlur.maxShapeCanvasPixels` (the picture keeps its size);
    /// others are not capped.
    static func pixelBudget(_ seg: EffectSegment) -> Int {
        switch seg.filter {
        case .longShadow?, .outline?: GaussianBlur.maxShapeCanvasPixels
        default: .max
        }
    }

    /// A pass whose look does not depend on the working resolution: a blur, a shadow, or a filter that smears or moves the
    /// picture. Sharpen, Noise, Grain, Mosaic and the per-pixel looks stay at full size.
    static func worksAtReducedSize(_ seg: EffectSegment) -> Bool {
        if seg.shadow != nil { return true }
        guard let f = seg.filter else { return seg.blurAfter > 0 }
        switch f {
        case .directionalBlur, .glow, .radialBlur, .mirror, .flip, .outline, .longShadow: return true
        default: return false
        }
    }

    /// The working size of a multi-pass chain (`segs`, the last one is the draw into the canvas), as 1/factor of the layer.
    /// `display`: `effectWorkFactor` of the layer. A plain blur of `strongBlurPixels` layer px or more keeps nothing a half-size
    /// picture cannot hold (the finest detail left is damped far below 1 %), so it works at half size at any scale; the other softening
    /// passes follow the display size; any other pass keeps the whole chain at full size.
    /// `strongBlurHalves`: false keeps the blur rule to the display size too.
    /// The blur (layer px) from which a chain works at half size at any scale. 3, not 2: at 2 px a 1 px pattern still
    /// differs visibly between the two sizes, and a blur keyframed through the threshold would step there.
    static let strongBlurPixels: Double = 3

    static func effectChainFactor(_ segs: [EffectSegment], display: Int, strongBlurHalves: Bool = true) -> Int {
        var f = 2
        for seg in segs.dropLast() {
            let plainBlur = seg.shadow == nil && seg.filter == nil && seg.blurAfter > 0
            let allowed = plainBlur && strongBlurHalves && seg.blurAfter >= strongBlurPixels ? 2 : worksAtReducedSize(seg) ? display : 1
            f = min(f, allowed)
        }
        return f
    }

    /// Writes one segment's masks and keys into the uniforms. `reduction` > 1: the pass draws at 1/reduction size.
    /// `legacyRadius`: the layer's own `cornerRadius`; when the segment says the same, the radius written by `prepareLayer` stays
    /// as it is (bit-identical to before effects existed).
    static func configure(_ u: inout Uniforms, _ seg: EffectSegment, radiusFactor: Double, reduction: Float, legacyRadius: Double?) {
        let m = seg.masks
        if !m.crop.isIdentity { u.crop = Self.cropVector(m.crop) }
        u.roundFirst = m.roundFirst && !m.crop.isIdentity && m.cornerRadius > 0 ? 1 : 0
        u.cropFeather = Float(max(m.feather, 0)) * Float(radiusFactor) / reduction
        if let legacy = legacyRadius, m.cornerRadius == legacy {
            // keep prepareLayer's value
        } else {
            u.cornerRadius = Float(m.cornerRadius) * Float(radiusFactor) / reduction
        }
        u.keyCount = UInt32(min(seg.keys.count, ChromaKey.maxPerLayer))
        if seg.keys.count > 0 {
            let k = seg.keys[0]
            u.key0 = UltraKey.vector(k); u.matte0 = UltraKey.matteVector(k); u.shape0 = UltraKey.shapeVector(k); u.cc0 = UltraKey.colorVector(k)
        }
        if seg.keys.count > 1 {
            let k = seg.keys[1]
            u.key1 = UltraKey.vector(k); u.matte1 = UltraKey.matteVector(k); u.shape1 = UltraKey.shapeVector(k); u.cc1 = UltraKey.colorVector(k)
        }
    }

    /// After a Repeat Edge Pixels blur the image holds the extended picture everywhere: the draw keeps only the clip's frame
    /// (the mask rectangle), antialiased at full size. A crop or rounded corners of the pass already cut inside that frame; a
    /// pass without them gets a vanishing crop so the shader's edge mask runs on the frame rectangle.
    static func cutToMaskRect(_ u: inout Uniforms) {
        if u.crop == .zero && u.cornerRadius == 0 { u.crop = SIMD4(repeating: 1e-6) }
    }

    static func cropVector(_ c: CropInsets) -> SIMD4<Float> {
        SIMD4(Float(c.left), Float(c.top), Float(c.right), Float(c.bottom))
    }

    /// Texture px the Repeat Edge Pixels blur clamps its reads to: the fully covered px of a `frame`-sized picture centered in
    /// a `texture`-sized image (a partly covered rim px is not repeated; the next draw cuts the frame edge antialiased).
    static func repeatEdgeRect(frame: SIMD2<Float>, texture: SIMD2<Int>) -> (lo: SIMD2<Int32>, hi: SIMD2<Int32>) {
        let t = SIMD2<Float>(Float(texture.x), Float(texture.y))
        let a = (t - frame) / 2, b = (t + frame) / 2
        let lo = SIMD2<Int32>(Int32((a.x - 1e-3).rounded(.up)), Int32((a.y - 1e-3).rounded(.up)))
        var hi = SIMD2<Int32>(Int32((b.x + 1e-3).rounded(.down)) - 1, Int32((b.y + 1e-3).rounded(.down)) - 1)
        hi = simd_max(hi, lo)
        return (simd_clamp(lo, .zero, SIMD2(Int32(texture.x - 1), Int32(texture.y - 1))),
                simd_clamp(hi, .zero, SIMD2(Int32(texture.x - 1), Int32(texture.y - 1))))
    }
}
