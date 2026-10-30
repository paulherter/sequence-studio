import Foundation
#if canImport(simd)
import simd
#endif
import SQCore

// The layer draw's uniform blocks and placement maths, shared by the Metal `Compositor` and the portable
// `GPUCompositor` (moved here unchanged from Compositor.swift).
extension Compositor {
    struct Uniforms {
        var m = matrix_identity_float3x3
        var solid = SIMD4<Float>(0, 0, 0, 1)
        var range = SIMD4<Float>(1, 0, 1, 0)
        var canvas = SIMD2<Float>(1, 1)
        var size = SIMD2<Float>(1, 1)
        var position = SIMD2<Float>(0, 0)
        var anchor = SIMD2<Float>(0, 0)
        var scale = SIMD2<Float>(1, 1)
        var rotCos: Float = 1, rotSin: Float = 0, opacity: Float = 1
        var mode: UInt32 = 0
        var linearize: UInt32 = 1
        var cornerRadius: Float = 0
        /// Clockwise quarter turns of a source picture (0...3): the layer quad is upright, the texture lookup turns.
        var quarter: UInt32 = 0
        /// Blend mode id for the blending pipeline (0 = normal; see `BlendModes.shaderID`).
        var blend: UInt32 = 0
        /// Size of the rectangle Crop and Rounded Corners work on (the layer's own picture); zero = `size`.
        var maskSize = SIMD2<Float>(0, 0)
        /// Crop insets as fractions of `maskSize`: left, top, right, bottom.
        var crop = SIMD4<Float>(0, 0, 0, 0)
        /// Ultra Keys: hue, half width, soft edge, spill (degrees / fractions); `keyCount` of them are used.
        var key0 = SIMD4<Float>(0, 0, 0, 0)
        var key1 = SIMD4<Float>(0, 0, 0, 0)
        /// Matte shaping per key: shrink / grow, pedestal, output, mode.
        var matte0 = SIMD4<Float>(0, 0, 0, 0)
        var matte1 = SIMD4<Float>(0, 0, 0, 0)
        /// Matte contrast / midpoint / keep highlights / keep shadows, and color correction (saturation, hue shift in radians,
        /// brightness, spill range), per key.
        var shape0 = SIMD4<Float>(0, 0.5, 0, 0)
        var shape1 = SIMD4<Float>(0, 0.5, 0, 0)
        var cc0 = SIMD4<Float>(1, 0, 1, 0.5)
        var cc1 = SIMD4<Float>(1, 0, 1, 0.5)
        var keyCount: UInt32 = 0
        /// 1 = Rounded Corners came before Crop: round the whole frame, then cut straight crop edges into it.
        var roundFirst: UInt32 = 0
        /// Texture alpha of modes 1 and 4: 0 = legacy (mode 1: premultiplied with `linearize`, straight without),
        /// 1 = straight, 2 = premultiplied. 1 and 2 filter premultiplied color in the shader.
        var alphaMode: UInt32 = 0
        /// W6.7 clip masks in the draw's mask buffer (fragment buffer 1); 0 = none.
        var maskCount: UInt32 = 0
        /// Crop Softness: the edge ramp of the Crop / Rounded Corners mask widens inwards by this many layer px; 0 = hard.
        var cropFeather: Float = 0
        /// A partial buffer drawn as the whole picture (`RenderLayer.contentPart`, mode 3): where `tex0` lies in it
        /// (x and y, texels) and the whole picture's size (z and w, texels); z = 0: `tex0` is the whole picture.
        var part = SIMD4<Float>(0, 0, 0, 0)
        /// Perspective tilt (`PerspectiveTilt`): x / y turn in radians about the anchor, and the camera distance in px
        /// (`tilt.z`; 0 = flat, the plain affine placement). The vertex stage places the corners; `w` gives the fragment
        /// stage perspective-correct layer coordinates.
        var tilt = SIMD3<Float>(0, 0, 0)
    }

    /// Mirrors `ConvertU` (SQGPU Shaders/SourceConvert.slang, 16 bytes): where the dispatch starts and the source curve of
    /// the half-size average (`UInt32.max`: plain average).
    struct ConvertUniforms {
        var origin: SIMD2<UInt32>
        var transfer: UInt32
        var pad: UInt32 = 0
    }

    /// Mirrors `PreBlurU` (SQGPU Shaders/TransitionPreBlur.slang, 16 bytes).
    struct PreBlurUniforms {
        var canvas: SIMD2<Float>
        var pad: Float
        var slot: UInt32
    }

    /// Mirrors `TransitionSideU` in the shader (40 bytes; `TransitionU` 120).
    struct TransitionSideUniforms {
        var offset: SIMD2<Float>, blur: SIMD2<Float>
        var scale: Float, opacity: Float, zoomBlur: Float, taps: Float = 0
        /// Rotation (radians) about the frame center, in pixel space; was `pad0`.
        var rotation: Float = 0
        /// 1 = mirrored repeat outside the picture (a settling Zoom In / Out side below 100 %), 0 = transparent; was `pad`.
        var mirror: Float = 0
        init(_ s: TransitionSide) {
            offset = SIMD2(Float(s.offset.x), Float(s.offset.y)); blur = SIMD2(Float(s.blur.x), Float(s.blur.y))
            scale = Float(max(s.scale, 1e-4)); opacity = Float(min(max(s.opacity, 0), 1)); zoomBlur = Float(s.zoomBlur)
            rotation = Float(s.rotation)
            mirror = s.mirrorEdges ? 1 : 0
        }

        /// A directional smear longer than one pass covers smoothly (64 taps at 1.5 px) is split in two: a pre-pass that
        /// places the side on the canvas with a box smear of one comb spacing (returned; nil when not needed), and `taps`
        /// comb taps here on that already placed picture. Box * comb = the full box, samples never more than ~1.5 px apart.
        /// `pad`: how far (canvas fraction, every side) the pre-pass canvas reaches past the frame; this side then samples
        /// it at scale 1 + 2 pad.
        mutating func splitLongBlur(canvas px: SIMD2<Float>) -> (side: TransitionSideUniforms, pad: Float)? {
            guard opacity > 0, zoomBlur == 0 else { return nil }
            let d = blur * px     // canvas px: the smear is `blur` on screen whatever the scale
            let len = (d.x * d.x + d.y * d.y).squareRoot()
            guard len > 96 else { return nil }
            let m = min(256, (len / 96).rounded(.up))
            var pre = self
            pre.blur = blur / m; pre.opacity = 1; pre.taps = 0
            let pad = min(1, max(abs(d.x) / px.x, abs(d.y) / px.y) / 2 + 2 / min(px.x, px.y))
            offset = .zero; scale = 1 + 2 * pad
            mirror = 0   // the pre-pass already filled its canvas
            blur *= 1 - 1 / m
            taps = m
            return (pre, pad)
        }
    }
    struct TransitionUniforms {
        var a: TransitionSideUniforms, b: TransitionSideUniforms
        var wipeDir: SIMD2<Float>, wipeFront: Float, wipeSoft: Float
        var compose: UInt32
        /// Border band (0 = off), working-linear color; was `pad`.
        var borderWidth: Float = 0, borderR: Float = 0, borderG: Float = 0, borderB: Float = 0
        init(_ r: TransitionRender) {
            a = TransitionSideUniforms(r.outgoing); b = TransitionSideUniforms(r.incoming)
            wipeDir = SIMD2(Float(r.wipe.direction.x), Float(r.wipe.direction.y))
            wipeFront = Float(r.wipe.front); wipeSoft = Float(max(0, r.wipe.softness))
            compose = r.compose.rawValue
            if let b = r.border, r.compose != .glitch, r.compose != .staticNoise {
                borderWidth = Float(b.width); borderR = Float(b.r); borderG = Float(b.g); borderB = Float(b.b)
            }
            if r.compose == .glitch || r.compose == .staticNoise {
                // Glitch reuses the wipe fields: dir.x = seed bits, front = mix, soft = intensity.
                wipeDir = SIMD2(Float(bitPattern: r.glitch.seed), 0)
                wipeFront = Float(r.glitch.mix); wipeSoft = Float(r.glitch.intensity)
            }
        }
    }

    /// Texture of a long blur's pre-pass for a `width` x `height` transition canvas grown by `pad` on every side.
    /// The pad is rounded up to 1/16 of the canvas, so an animated blur draws into a few recurring sizes the pool reuses
    /// instead of a new texture every frame. Larger than `maxSide` (frames wider than 16384 / 3 at pad 1), both sides
    /// shrink together: both passes address that canvas in normalized coordinates and the picture on it is already
    /// smeared over a comb spacing of at least ~48 canvas px, so drawing it at up to 3x fewer pixels shows nothing.
    static func longBlurTarget(width: Int, height: Int, pad: Float, maxSide: Int) -> (pad: Float, width: Int, height: Int) {
        let q = min(1, (max(pad, 0) * 16).rounded(.up) / 16)
        let bw = (Float(width) * (1 + 2 * q)).rounded(.up), bh = (Float(height) * (1 + 2 * q)).rounded(.up)
        let s = min(1, Float(maxSide) / max(bw, bh))
        guard s < 1 else { return (q, Int(bw), Int(bh)) }
        return (q, max(1, min(maxSide, Int((bw * s).rounded()))), max(1, min(maxSide, Int((bh * s).rounded()))))
    }

    /// Placeholder display colors (sRGB-ish, then linearised): offline = dark red, damaged = amber, loading = gray.
    static func placeholderLinear(_ k: PlaceholderKind) -> SIMD4<Float> {
        let d: SIMD3<Float>
        switch k {
        case .offline: d = SIMD3(0.45, 0.10, 0.10)
        case .damaged: d = SIMD3(0.45, 0.33, 0.05)
        case .loading: d = SIMD3(0.20, 0.20, 0.20)
        }
        return SIMD4(lin(d.x), lin(d.y), lin(d.z), 1)
    }

    /// Inverse BT.709 OETF: display-encoded -> working-linear.
    static func lin(_ e: Float) -> Float { e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }

    /// Corner radii are given in px of the layer fitted into the canvas (what they meant before Scale became relative to
    /// source pixels); the layer is now drawn at its own size, so the radius is converted: native / fitted.
    static func radiusFactor(_ w: Int, _ h: Int, canvas: SequenceFormat) -> Double {
        let fit = fitSize(w, h, canvas: canvas.displayWidth, canvas.height)
        return fit.x > 0 ? Double(Float(w) / fit.x) : 1
    }

    /// Aspect-fit size of `w x h` into the canvas.
    static func fitSize(_ w: Int, _ h: Int, canvas cw: Int, _ ch: Int) -> SIMD2<Float> {
        let s = min(Float(cw) / Float(w), Float(ch) / Float(h))
        return SIMD2(Float(w) * s, Float(h) * s)
    }

    /// Camera distance (px) of a tilted draw, from the draw's own `size` (after any blur or shadow padding), anchor, scale
    /// and canvas, so the depth never reaches the camera plane (`PerspectiveTilt.focal`, radius + 2 px as the overlay does).
    static func tiltFocal(_ u: Uniforms) -> Float {
        let r = PerspectiveTilt.layerRadius(size: Vec2(Double(u.size.x), Double(u.size.y)),
                                            anchor: Vec2(Double(u.anchor.x), Double(u.anchor.y)),
                                            scale: Vec2(Double(u.scale.x), Double(u.scale.y)))
        return Float(PerspectiveTilt.focal(layerRadius: r + 2, canvas: Vec2(Double(u.canvas.x), Double(u.canvas.y))))
    }

    func geometry(_ u: inout Uniforms, transform t: ClipTransform, canvas: SequenceFormat, size: SIMD2<Float>,
                  cornerRadius: Double = 0) {
        Self.layerGeometry(&u, transform: t, canvas: canvas, size: size, cornerRadius: cornerRadius)
    }

    /// The layer draw's placement uniforms (`CompositeU`): canvas, size, transform, opacity, corner radius and tilt.
    static func layerGeometry(_ u: inout Uniforms, transform t: ClipTransform, canvas: SequenceFormat, size: SIMD2<Float>,
                              cornerRadius: Double = 0) {
        u.cornerRadius = Float(max(0, cornerRadius))
        // Display space: with a non-square pixel shape the canvas is the picture as shown; its edges still map to the whole
        // target in the vertex stage, which squeezes it into the stored pixels (no extra uniform or pass). Square: unchanged.
        u.canvas = SIMD2(Float(canvas.displayWidth), Float(canvas.height))
        u.size = size
        u.position = SIMD2(Float(t.position.x), Float(t.position.y))
        u.anchor = SIMD2(Float(t.anchor.x), Float(t.anchor.y))
        u.scale = SIMD2(Float(max(0, t.scale.x)), Float(max(0, t.scale.y)))
        let r = t.rotation * .pi / 180
        u.rotCos = Float(cos(r)); u.rotSin = Float(sin(r))
        u.opacity = Float(min(1, max(0, t.opacity)))
        // Picture masks and effect mask scopes read `screenFromLocal`, which carries this tilt (`ScreenMap.tilt`).
        if t.isTilted {
            let focal = Double(tiltFocal(u))
            u.tilt = SIMD3(Float(PerspectiveTilt.clamped(t.tiltX) * .pi / 180), Float(PerspectiveTilt.clamped(t.tiltY) * .pi / 180), Float(focal))
        }
    }
}
