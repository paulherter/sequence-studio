import Foundation
import SQCore
#if canImport(simd)
import simd
#endif

extension Compositor {
    /// A pixel rectangle of a source texture.
    public struct SourceRegion: Sendable, Equatable {
        public var x, y, width, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    }

    /// The part of a layer's source texture that lands on the canvas (playback perf: a 4K clip in a vertical canvas shows
    /// about a quarter of its pixels, so its color stage only needs to run there). Inverts the composite vertex mapping
    /// `canvas/2 + position + R((local - anchor) * scale)`, `uv = local / size + 0.5`, then the quarter turn of the fragment
    /// shader. `canvasPad`: canvas px added around the canvas first (edge antialiasing grows the quad by 1 screen px);
    /// `pad`: texture px added around the result (the bilinear footprint). nil when nothing of the layer is on the canvas.
    static func visibleSourceRegion(canvas: SIMD2<Float>, transform t: ClipTransform, size: SIMD2<Float>,
                                    texture: (width: Int, height: Int), quarter: UInt32, pad: Int,
                                    canvasPad: Float = 0) -> SourceRegion? {
        let sx = Float(max(0, t.scale.x)), sy = Float(max(0, t.scale.y))
        guard sx > 1e-6, sy > 1e-6, size.x > 0, size.y > 0, texture.width > 0, texture.height > 0 else { return nil }
        // shortcut: a tilted layer keeps its whole texture (the perspective inverse is not folded in here); upgrade when a
        // large tilted clip needs the region trim.
        if t.isTilted { return SourceRegion(x: 0, y: 0, width: texture.width, height: texture.height) }
        let r = t.rotation * .pi / 180
        let c = Float(cos(r)), s = Float(sin(r))
        let pos = SIMD2(Float(t.position.x), Float(t.position.y)), anchor = SIMD2(Float(t.anchor.x), Float(t.anchor.y))
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for corner in [SIMD2<Float>(-canvasPad, -canvasPad), SIMD2(canvas.x + canvasPad, -canvasPad),
                       SIMD2(-canvasPad, canvas.y + canvasPad), SIMD2(canvas.x + canvasPad, canvas.y + canvasPad)] {
            let q = corner - canvas * 0.5 - pos
            let p = SIMD2(c * q.x + s * q.y, -s * q.x + c * q.y)          // R^-1
            var uv = (p / SIMD2(sx, sy) + anchor) / size + 0.5
            switch quarter {                                               // upright uv -> stored texture uv
            case 1: uv = SIMD2(uv.y, 1 - uv.x)
            case 2: uv = SIMD2(1 - uv.x, 1 - uv.y)
            case 3: uv = SIMD2(1 - uv.y, uv.x)
            default: break
            }
            lo = simd_min(lo, uv); hi = simd_max(hi, uv)
        }
        let tw = Float(texture.width), th = Float(texture.height)
        // Snap away float noise (cos 90 degrees is not 0) before rounding outwards.
        let eps: Float = 1e-3
        let x0 = Int((lo.x * tw + eps).rounded(.down)) - pad, y0 = Int((lo.y * th + eps).rounded(.down)) - pad
        let x1 = Int((hi.x * tw - eps).rounded(.up)) + pad, y1 = Int((hi.y * th - eps).rounded(.up)) + pad
        let cx0 = max(0, x0), cy0 = max(0, y0), cx1 = min(texture.width, x1), cy1 = min(texture.height, y1)
        guard cx1 > cx0, cy1 > cy0 else { return nil }
        return SourceRegion(x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0)
    }

    /// Where a frame layer's convert + color passes run: an intermediate of `width` x `height` (the source size, or half of
    /// it) and the region of it to process (nil: nothing of the layer is on the canvas).
    struct ColorWork: Equatable {
        var width: Int, height: Int
        var region: SourceRegion?
    }

    /// Playback perf (docs/PLAYBACK-PERF.md). Half resolution when the canvas shows at most one pixel per 2 x 2 source
    /// texels (a 4K clip at 50 % or less): the 2 x 2 box the draw would average anyway is averaged first, then graded, so
    /// every canvas pixel still gets its own graded sample (a pixel-level difference only where a strong curve meets a
    /// hard edge; export renders the same way). Only the visible region when the layer is drawn in one pass (a blur,
    /// shadow or filter pass reads beyond it). Positions stay those of the whole picture (vignette unchanged). Also half
    /// resolution under a strong blur at any scale (`strongBlur`).
    static func colorWork(canvas: SIMD2<Float>, transform t: ClipTransform, size: SIMD2<Float>, texture: (width: Int, height: Int),
                          texelsPerNativePixel: Float, quarter: UInt32, onePass: Bool, strongBlur: Bool = false,
                          halves: Bool = true) -> ColorWork {
        // `strongBlur`: the layer's effect chain starts with a blur strong enough to keep nothing a half-resolution picture
        // cannot hold (see `effectChainFactor`), whatever the scale. `halves` false: the source curve does not allow the
        // 2 x 2 average before grading (`averagesBeforeGrading`).
        let tpn = Double(texelsPerNativePixel)
        let fine = shownAtHalfOrLess(t, texelsPerNativePixel: tpn) || strongBlur && tpn >= 1
        let half = halves && fine && texture.width >= 64 && texture.height >= 64
        let w = half ? (texture.width + 1) / 2 : texture.width, h = half ? (texture.height + 1) / 2 : texture.height
        let all = SourceRegion(x: 0, y: 0, width: w, height: h)
        guard onePass else { return ColorWork(width: w, height: h, region: all) }
        let r = visibleSourceRegion(canvas: canvas, transform: t, size: size, texture: (w, h), quarter: quarter, pad: 2, canvasPad: 2)
        return ColorWork(width: w, height: h, region: r)
    }

    /// Playback perf: the size the effect passes (blur, shadow, filters) of a layer run at, as 1/factor of the layer. 2 when
    /// the layer is shown at half size or less on both axes (the draw into the canvas averages 2 x 2 layer px anyway, the
    /// same rule as `colorWork`); 1 otherwise. Depends only on the transform, so export renders the same picture.
    static func effectWorkFactor(transform t: ClipTransform, size: SIMD2<Float>) -> Int {
        shownAtHalfOrLess(t) && min(size.x, size.y) >= 128 ? 2 : 1
    }

    /// The one half-size test of `colorWork` and `effectWorkFactor` (Double, on the transform's own values, so the color
    /// stage and the effect chain flip at the same frame of a keyframed scale): at most one canvas px per 2 x 2 texels.
    /// `texelsPerNativePixel` < 1 for a reduced proxy (its texel already covers several layer px).
    static func shownAtHalfOrLess(_ t: ClipTransform, texelsPerNativePixel: Double = 1) -> Bool {
        if t.isTilted { return false }   // the near edge of a tilted layer is shown larger than its scale
        let shown = max(t.scale.x, t.scale.y)
        return shown > 0 && shown * 2 <= texelsPerNativePixel
    }

    /// A color chain whose every op works per pixel (its result at a pixel depends only on that pixel's color and
    /// position, not on neighbors): it can run on a downscaled picture. Exhaustive on purpose: a new op with a spatial
    /// kernel (sharpen, grain, glow...) must be listed here as `false`.
    static func isPointwise(_ pipeline: ColorPipeline) -> Bool {
        pipeline.ops.allSatisfy { op in
            switch op {
            case .conversion, .basic, .creative, .look, .curves, .hueCurves, .wheels, .hslSecondary, .zoneBoard, .vignette,
                 .primaries, .stepBegin, .stepEnd, .groupBegin, .branchEnd, .groupMerge, .groupEnd, .keyTerm, .keyApply, .layerMix: true
            }
        }
    }

    /// The layer's whole chain is pointwise: the grade, and effects that ride along in the one draw (Crop, Rounded
    /// Corners, keys, masks). A blur, shadow or whole-picture filter (more than one segment) is spatial.
    static func isPointwise(_ pipeline: ColorPipeline, effects: ClipEffects) -> Bool {
        isPointwise(pipeline) && effects.segments.count <= 1
    }

    /// Above this many canvas px per texel the display-size grade saves too little to be worth the resample.
    static let displayGradeMaxShown = 0.9

    /// Preview (`gradesAtDisplaySize`): where a pointwise layer's convert + grade run when it is graded at the size it is
    /// shown: the texture scaled by the canvas px per texel (rounded up), only its visible region. nil when the layer is
    /// shown at (nearly) its texture size or larger: the normal path runs.
    static func displayColorWork(canvas: SIMD2<Float>, transform t: ClipTransform, size: SIMD2<Float>,
                                 texture: (width: Int, height: Int), texelsPerNativePixel: Float, quarter: UInt32,
                                 halves: Bool = true) -> ColorWork? {
        // `halves` false (`averagesBeforeGrading`): the source cannot be averaged before its tone map; the normal path grades
        // at full size.
        guard halves else { return nil }
        let tpn = Double(texelsPerNativePixel)
        guard tpn > 0 else { return nil }
        let shown = max(t.scale.x, t.scale.y) / tpn
        guard shown > 0, shown <= displayGradeMaxShown else { return nil }
        let w = max(1, Int((Double(texture.width) * shown).rounded(.up)))
        let h = max(1, Int((Double(texture.height) * shown).rounded(.up)))
        let r = visibleSourceRegion(canvas: canvas, transform: t, size: size, texture: (w, h), quarter: quarter, pad: 2, canvasPad: 2)
        return ColorWork(width: w, height: h, region: r)
    }

    /// Sources whose 2 x 2 average in their own light, graded afterwards, matches grading first and averaging the result
    /// (the half-size color stage, `colorWork`): Rec.709 (exact) and HLG (mean 0.004 on a 1 px checker). Log and PQ
    /// sources go through a strongly compressing tone map, where the order changes a hard 1 px pattern by mean 0.02 to 0.2
    /// (EffectWorkSizeTests): their color stage stays at full resolution.
    static func averagesBeforeGrading(_ source: SourceColorSpace) -> Bool {
        source == .rec709 || source == .hlgBT2020
    }
}
