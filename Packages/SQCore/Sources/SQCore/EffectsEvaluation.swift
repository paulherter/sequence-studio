import Foundation

/// Crop insets as fractions (0...1) of the clip's own frame.
public struct CropInsets: Sendable, Hashable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public static let none = CropInsets()
    public var isIdentity: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    /// Nothing is left of the picture.
    public var isEmpty: Bool { left + right >= 1 || top + bottom >= 1 }
    /// The larger inset per edge: two crops in a row keep what both keep.
    public func merged(with o: CropInsets) -> CropInsets {
        CropInsets(left: max(left, o.left), top: max(top, o.top), right: max(right, o.right), bottom: max(bottom, o.bottom))
    }
}

/// Crop and Rounded Corners as one coverage mask on the layer rectangle. The order of the two matters:
/// - `roundFirst` false (Crop, then Rounded Corners): the radius rounds the corners of the cropped rectangle;
/// - `roundFirst` true (Rounded Corners, then Crop): the frame is rounded first, the crop then cuts straight edges into it.
public struct EffectMasks: Sendable, Hashable {
    public var crop: CropInsets
    /// Canvas pixels of the clip's own frame, >= 0.
    public var cornerRadius: Double
    public var roundFirst: Bool
    /// Crop Softness: width of the soft edge inside the mask, canvas pixels of the clip's own frame (like `cornerRadius`);
    /// 0 = the one pixel anti-aliased edge.
    public var feather: Double
    public init(crop: CropInsets = .none, cornerRadius: Double = 0, roundFirst: Bool = false, feather: Double = 0) {
        self.crop = crop; self.cornerRadius = cornerRadius; self.roundFirst = roundFirst; self.feather = feather
    }
    public static let none = EffectMasks()
    public var isIdentity: Bool { crop.isIdentity && cornerRadius == 0 && feather == 0 }

    /// Adds Rounded Corners after what is already here, or nil when one mask cannot express the pair (Crop, Rounded Corners,
    /// Crop again): the caller then starts a new pass.
    func adding(radius r: Double) -> EffectMasks? {
        var m = self
        if cornerRadius == 0 { m.cornerRadius = r; m.roundFirst = false; return m }
        // A radius exists: with no crop, or in the order Crop then Rounded Corners, the larger radius stands for both.
        if crop.isIdentity || !roundFirst { m.cornerRadius = max(cornerRadius, r); return m }
        return nil                                  // Rounded Corners, Crop, Rounded Corners: not one mask
    }

    /// Adds a Crop after what is already here (see `adding(radius:)`). Two Crops in one mask keep the softer edge.
    func adding(crop c: CropInsets, feather f: Double = 0) -> EffectMasks? {
        var m = self
        m.feather = max(feather, f)
        if cornerRadius == 0 { m.crop = crop.merged(with: c); return m }
        if crop.isIdentity { m.crop = c; m.roundFirst = true; return m }
        if roundFirst { m.crop = crop.merged(with: c); return m }
        return nil
    }
}

/// One key at one instant, in the units the renderer uses (degrees of hue). A chroma key (Ultra Key, `.chroma`) or a luma key
/// (`.luma`); both share the matte clean-up (`MatteRefine`: shrink / grow, contrast, midpoint) and the output view.
public struct ChromaKey: Sendable, Hashable {
    public enum Mode: Int, Sendable, Hashable { case chroma = 0, luma = 1 }
    /// What the layer shows: the keyed picture, the matte as black / white, or the picture before keying.
    public enum Output: Int, Sendable, Hashable { case composite = 0, alpha = 1, source = 2 }

    public var mode: Mode
    /// Hue to remove, 0...360.
    public var hue: Double
    /// Pixels within this many degrees of `hue` are keyed out completely.
    public var halfWidth: Double
    /// Width in degrees of the soft edge beyond `halfWidth` (at least 1).
    public var soft: Double
    /// Share (0...1) of the colored spill near the key hue that is desaturated.
    public var spill: Double
    /// -1...1: shrinks (positive) or grows (negative) the kept picture: `MatteRefine.shrink`.
    public var choke: Double
    /// Matte values below this (0...1) are treated as not keyed at all.
    public var pedestal: Double
    /// The output view.
    public var output: Output
    /// 0...1 `MatteRefine.contrast` and `.midpoint` of the kept share.
    public var contrast: Double
    public var midpoint: Double
    /// 0...1: how much of bright / dark pixels are kept regardless of the key (subject highlights, shadows on the subject).
    public var keepHighlights: Double
    public var keepShadows: Double
    /// 0...1: how far around the key hue spill is desaturated (0.5 = the original zone).
    public var spillRange: Double
    /// Color correction of the kept picture: saturation and luma are factors (1 = unchanged), hue shift in degrees.
    public var saturation: Double
    public var hueShift: Double
    public var luma: Double
    /// Luma key: encoded luma (0...1) where keying ends or starts, the width of the ramp beyond it (0...1), and which side
    /// is removed.
    public var lumaThreshold: Double
    public var lumaSoftness: Double
    public var lumaKeysBrights: Bool

    /// Output "Alpha": show the matte (white = kept, black = keyed) instead of the keyed picture.
    public var matteOutput: Bool {
        get { output == .alpha }
        set { output = newValue ? .alpha : .composite }
    }
    public init(hue: Double, halfWidth: Double, soft: Double, spill: Double, choke: Double = 0, pedestal: Double = 0,
                matteOutput: Bool = false) {
        self.mode = .chroma
        self.hue = hue; self.halfWidth = halfWidth; self.soft = soft; self.spill = spill
        self.choke = choke; self.pedestal = pedestal; self.output = matteOutput ? .alpha : .composite
        contrast = 0; midpoint = 0.5; keepHighlights = 0; keepShadows = 0; spillRange = 0.5
        saturation = 1; hueShift = 0; luma = 1
        lumaThreshold = 0; lumaSoftness = 0; lumaKeysBrights = false
    }
    /// A luma key: removes pixels darker (or brighter) than `threshold`, with a ramp of `softness`.
    public static func luma(threshold: Double, softness: Double, brights: Bool = false) -> ChromaKey {
        var k = ChromaKey(hue: 0, halfWidth: 0, soft: 1, spill: 0)
        k.mode = .luma
        k.lumaThreshold = threshold; k.lumaSoftness = softness; k.lumaKeysBrights = brights
        return k
    }
    /// The shared clean-up of this key's matte.
    public var refine: MatteRefine { MatteRefine(shrink: choke, contrast: contrast, midpoint: midpoint) }
    /// True when the color correction changes anything.
    public var correctsColor: Bool { saturation != 1 || hueShift != 0 || luma != 1 }
    /// Most keys the renderer applies in one pass.
    public static let maxPerLayer = 2
}

/// One Drop Shadow at one instant, in px of the clip's own frame (y down).
public struct DropShadow: Sendable, Hashable {
    /// Display-encoded (BT.709 OETF) 0...1 channels as picked in the color well; the renderer linearises them.
    public var color: SIMD3<Double>
    /// 0...1.
    public var opacity: Double
    /// Offset in px, y down.
    public var dx: Double, dy: Double
    /// Gaussian sigma in px (0.2 x Softness, see `ClipEffect.shadowSigmaPerSoftness`).
    public var sigma: Double
    /// 0...1: how far the blurred edge is pushed outwards (Photoshop's Spread / choke): fills the shadow, softness only acts at the rim.
    public var spread: Double
    /// Draw only the shadow, not the picture.
    public var shadowOnly: Bool
    public init(color: SIMD3<Double> = .zero, opacity: Double = 0.5, dx: Double = 0, dy: Double = 0,
                sigma: Double = 0, spread: Double = 0, shadowOnly: Bool = false) {
        self.spread = spread
        self.color = color; self.opacity = opacity; self.dx = dx; self.dy = dy; self.sigma = sigma; self.shadowOnly = shadowOnly
    }
    public var distance: Double { (dx * dx + dy * dy).squareRoot() }
    /// How far (px) the shadow can reach beyond the picture: offset plus three sigma.
    public var margin: Double { distance + 3 * sigma * (1 + spread) }
}

/// A whole-picture effect at one instant (W3.1), in px of the clip's own frame (y down). Like a blur or a shadow it ends its
/// segment: the renderer runs it on the image the segment's masks and keys made.
public enum ImageFilter: Sendable, Hashable {
    /// p + amount * (p - mean of its 3 x 3 neighborhood); amount 1 = Sharpen Amount 100.
    case sharpen(amount: Double)
    /// p + amount * (p - Gaussian(sigma px)) where the largest channel difference exceeds `threshold` (0...1, working
    /// linear); the blur repeats the picture's edge pixels. Amount 1 = Unsharp Mask Amount 100.
    case unsharpMask(sigma: Double, amount: Double, threshold: Double)
    /// Box smear along (dx, dy), the whole length, centered on each pixel.
    case directionalBlur(dx: Double, dy: Double)
    /// Reflection line through `center` (offset from the frame center, px, y down); `angle` degrees, 0 = left onto right,
    /// 90 = top onto bottom (the side the normal (cos, sin) points to shows the other side).
    case mirror(center: Vec2, angle: Double)
    /// `amount` 0...1; `seed` changes per instant so the grain moves.
    case noise(amount: Double, color: Bool, clip: Bool, seed: UInt32)
    /// `threshold` 0...1 luma; `sigma` px; `color` display-encoded tint, nil = the picture's own colors.
    case glow(threshold: Double, sigma: Double, intensity: Double, color: SIMD3<Double>?)
    /// Blocks over the frame, average color each (or the block's center pixel when `sharp`).
    case mosaic(columns: Int, rows: Int, sharp: Bool)
    // FB-T2 style filters (StyleEffects.swift). Color operations work on display-encoded, un-premultiplied values like
    // Premiere's 8-bit effects; px are px of the clip's own frame; points are offsets from the frame center (y down).
    /// Lumetri-style vignette: `amount` stops (-5...5), `midpoint` 0...1, `roundness` -1...1, `feather` 0...1.
    case vignette(amount: Double, midpoint: Double, roundness: Double, feather: Double)
    /// Red moved by (dx, dy), blue by -(dx, dy); `radial`: the length grows from 0 at the center to |d| at the corners and
    /// points away from the center. `mix` = Blend With Original 0...1.
    case rgbSplit(dx: Double, dy: Double, radial: Bool, mix: Double)
    /// Spin: `amount` degrees around `center`; zoom: `amount` % of the distance to it.
    case radialBlur(center: Vec2, amount: Double, zoom: Bool, high: Bool)
    case flip(horizontal: Bool, vertical: Bool)
    /// `channel`: 0 RGB, 1 red, 2 green, 3 blue, 4 alpha. `blend` = Blend With Original 0...1.
    case invert(channel: Int, blend: Double)
    case posterize(levels: Int)
    /// Luma mapped from `black` to `white` (display-encoded), mixed in by `amount` 0...1.
    case tint(black: SIMD3<Double>, white: SIMD3<Double>, amount: Double)
    /// Both -1...1.
    case brightnessContrast(brightness: Double, contrast: Double)
    /// `angle` degrees at the center; `radius` = share of the frame's longer side.
    case twirl(center: Vec2, angle: Double, radius: Double)
    /// Each corner of the picture moved by its offset (px from the corner, y down); the picture is stretched to that
    /// quadrilateral in perspective, transparent outside it.
    case cornerPin(topLeft: Vec2, topRight: Vec2, bottomRight: Vec2, bottomLeft: Vec2)
    /// `type` 0 sine, 1 square, 2 triangle, 3 sawtooth; `height`/`width` px; `direction` degrees (0 up, clockwise);
    /// `phase` 0..<1 cycles; `pinning` 0 none, 1 all edges, 2 horizontal edges, 3 vertical edges.
    case waveWarp(type: Int, height: Double, width: Double, direction: Double, phase: Double, pinning: Int)
    /// `radius` px; `strength` -1...1 (negative pinches).
    case spherize(center: Vec2, radius: Double, strength: Double)
    /// A flash: `color` display-encoded, `op` 0 copy, 1 add, 2 multiply, 3 screen, 4 difference; `transparent` hides the
    /// picture instead. `blend` = Blend With Original 0...1.
    case strobe(color: SIMD3<Double>, blend: Double, op: Int, transparent: Bool)
    /// `opacity` 0...1 multiplies alpha after Ignore / Invert; Mask Only draws the alpha as white.
    case alphaAdjust(opacity: Double, ignore: Bool, invert: Bool, maskOnly: Bool)
    /// `curvature` -1...1 (negative bulges); `decenter` share of half the frame; outside the picture: transparent
    /// (`fillAlpha`) or `fill` (display-encoded).
    /// `exactModel` false = the look of effects saved before F7.15 (`ClipEffect.lensModelKey`).
    case lensDistortion(curvature: Double, decenter: Vec2, fillAlpha: Bool, fill: SIMD3<Double>, autoScale: Bool = false,
                        exactModel: Bool = false)
    /// Screen-blended soft light: `center` in shares of half the frame from its center (y down), `size` share of the
    /// frame diagonal, `angle` radians of the color gradient (color1 -> color2), colors display-encoded.
    /// Linear or radial ramp from `color1` at `start` to `color2` at `end` (display-encoded colors; points are offsets from the
    /// frame center, px, y down), mixed over the picture by `blend` 0...1; alpha kept.
    case gradient(color1: SIMD3<Double>, color2: SIMD3<Double>, start: Vec2, end: Vec2, radial: Bool, blend: Double)
    /// A rotated dot screen: `size` px pitch, `angle` degrees, `softness` 0...1 edge width; `color` = bright dots in the
    /// picture's colors on black instead of ink on white. `blend` = Amount 0...1.
    case halftone(size: Double, angle: Double, softness: Double, color: Bool, blend: Double)
    /// The picture repeated `columns` x `rows` times, scrolled by `offset` (share of a tile); `mirror` flips alternate tiles.
    case tile(columns: Double, rows: Double, offset: Vec2, mirror: Bool)
    /// A wedge mirrored into `segments` slices around `center` (px from the frame center); `angle` degrees; `zoom` 1 = as is.
    case kaleidoscope(center: Vec2, segments: Int, angle: Double, zoom: Double)
    /// The picture's alpha fading to 0 over `amount` px (clip px) inward from the frame edges (smoothstep).
    case edgeFeather(amount: Double)
    /// Digital glitch: horizontal bands `block` px high; a share `density` 0...1 of them (chosen by `seed`) slides sideways by up
    /// to +-`amount` px; red and blue are pulled `split` px apart horizontally.
    case glitch(amount: Double, block: Double, split: Double, density: Double, seed: Int)
    case lightLeak(color1: SIMD3<Double>, color2: SIMD3<Double>, intensity: Double, center: Vec2, size: Double, angle: Double)
    /// A Transform effect with a mask input, drawn on the picture: the output point p (px from the frame center, y down) reads
    /// the picture at (a p.x + b p.y + tx, c p.x + d p.y + ty), times `opacity` (the stage's inverse map, `stage(_:)`).
    case stageWarp(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double, opacity: Double)
    /// The Stabilizer's correction as a picture warp (same inverse map as `stageWarp`, no opacity) whose reads past the
    /// picture's edge are filled: `.mirror` folds them back over the edge, `.blur` also blurs them wide (Edge Fill).
    case stageFill(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double, fill: StabilizerEdgeFill)
    /// Rolling shutter correction (RollingShutter.swift): rows shifted back by `shear` (fraction of the scan extent) times their scan position.
    case rollingShutter(shear: Vec2, alongX: Bool)
    /// The Stabilizer's one warp pass when it also carries the residual perspective: the Rolling Shutter shear (zero when
    /// the option is off) and the correction homography `perspective` (8 terms, `PerspectiveResidual`, picture px about
    /// the frame center): the output point p reads the picture at the rolling shutter source of (I + perspective)^-1 p.
    case stabilizeWarp(shear: Vec2, alongX: Bool, perspective: [Double])
    /// C5 Outline: a stroke `width` px (clip px) along the picture's alpha edge (alpha 0.5), in `color` (display-encoded),
    /// its edge ramped over `softness` px. Outside: under the picture, around it; inside: over the picture, within it;
    /// center: over the picture, half each side.
    case outline(width: Double, color: SIMD3<Double>, softness: Double, position: OutlinePosition)
    /// C5 Long Shadow: the picture's silhouette dragged `length` px along `angle` (degrees, 0 = up, clockwise), under the
    /// picture, in `color` at `opacity`; its alpha falls linearly by `fade` (0...1) over the length.
    case longShadow(angle: Double, length: Double, color: SIMD3<Double>, fade: Double, opacity: Double)

    /// Where an Outline sits against the picture's edge (stored as the effect's choice index).
    public enum OutlinePosition: Int, Sendable, Hashable, CaseIterable { case outside = 0, inside = 1, centre = 2 }

    /// Unit direction (y down) a Long Shadow runs for `degrees` (the RGB Split convention: 0 = up, clockwise).
    public static func longShadowDirection(degrees: Double) -> Vec2 {
        let a = degrees * .pi / 180
        return Vec2(sin(a), -cos(a))
    }

    /// The picture warp of a transform stage; nil for the identity. A stage scaled to 0 shows nothing (opacity 0).
    public static func stage(_ s: StageTransform) -> ImageFilter? {
        guard !s.isIdentity else { return nil }
        let f = Affine2(s)
        let det = f.a * f.d - f.b * f.c
        let opacity = min(max(s.opacity, 0), 1)
        guard abs(det) > 1e-12, s.scale > 0, s.scaleY > 0 else {
            return .stageWarp(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0, opacity: 0)
        }
        let a = f.d / det, b = -f.b / det, c = -f.c / det, d = f.a / det
        return .stageWarp(a: a, b: b, c: c, d: d, tx: -(a * f.t.x + b * f.t.y), ty: -(c * f.t.x + d * f.t.y), opacity: opacity)
    }

    /// The Stabilizer's correction `s` as a filling picture warp; nil for the identity or `.zoom` (that one moves the clip).
    public static func stageFill(_ s: StageTransform, fill: StabilizerEdgeFill) -> ImageFilter? {
        guard fill != .zoom, case .stageWarp(let a, let b, let c, let d, let tx, let ty, _)? = stage(s) else { return nil }
        guard s.scale > 0, s.scaleY > 0 else { return nil }
        return .stageFill(a: a, b: b, c: c, d: d, tx: tx, ty: ty, fill: fill)
    }

    /// How far (px) the result can reach beyond the picture.
    public var margin: Double {
        switch self {
        case .directionalBlur(let dx, let dy): (dx * dx + dy * dy).squareRoot() / 2
        case .glow(_, let sigma, _, _): 3 * sigma
        case .rgbSplit(let dx, let dy, _, _): (dx * dx + dy * dy).squareRoot()
        case .waveWarp(_, let h, _, _, _, _): abs(h)
        case .outline(let w, _, let s, let pos):
            switch pos {
            case .outside: w + s + 1
            case .centre: w / 2 + s + 1
            case .inside: 1
            }
        case .longShadow(_, let length, _, _, _): length + 1
        default: 0
        }
    }

    /// `margin` per axis (x, y), applied on both sides of that axis so the picture stays centered. Long Shadow only grows
    /// along the axes its angle runs on (a sideways shadow adds no rows); every other filter uses `margin` on both.
    public var axisMargin: Vec2 {
        if case .longShadow(let angle, let length, _, _, _) = self {
            let d = Self.longShadowDirection(degrees: angle)
            return Vec2(abs(d.x) * length + 1, abs(d.y) * length + 1)
        }
        return Vec2(margin, margin)
    }
}

/// What happens to the picture between two blurs: masks and keys. They commute with each other (both only change alpha or
/// per-pixel color), so they share one pass; a blur is a neighborhood operation and ends the segment.
public struct EffectSegment: Sendable, Hashable {
    public var masks: EffectMasks
    public var keys: [ChromaKey]
    /// Gaussian sigma in px applied after this segment's masks and keys; 0 = none. A segment with 0 that is not the last
    /// one is an extra pass (the effects before and after it could not be merged).
    public var blurAfter: Double
    /// `blurAfter` repeats the edge pixels outside the picture and is cut to the picture (Repeat Edge Pixels): the edge
    /// stays opaque and the image does not grow. Off: zero outside, the blur spreads past the picture.
    public var blurRepeatsEdges: Bool
    /// Drop Shadow cast by this segment's picture (after masks and keys). Never set together with `blurAfter`.
    public var shadow: DropShadow?
    /// Whole-picture effect run on this segment's picture (after masks and keys). Never set together with `blurAfter` or
    /// `shadow`.
    public var filter: ImageFilter?
    /// Unified masks: the input masks of the effect that made `blurAfter` / `filter` (top first). Not empty: the
    /// renderer mixes the blurred or filtered picture over the picture before it by their coverage, so the effect shows
    /// only there. Empty = everywhere.
    /// A segment with `keys`, a `scope` and nothing else (no blur, shadow, filter or grade): the scope limits the keys.
    public var scope: [MaskShape]
    /// A Color effect with a mask input, run on this segment's picture (after masks and keys) as its own grade
    /// (display-referred, like a later Color effect); `scope` limits it. Never set together with `blurAfter`, `shadow` or
    /// `filter`.
    public var grade: ColorEffect?
    public init(masks: EffectMasks = .none, keys: [ChromaKey] = [], blurAfter: Double = 0, blurRepeatsEdges: Bool = false,
                shadow: DropShadow? = nil, filter: ImageFilter? = nil, scope: [MaskShape] = [], grade: ColorEffect? = nil) {
        self.masks = masks; self.keys = keys; self.blurAfter = blurAfter; self.blurRepeatsEdges = blurRepeatsEdges
        self.shadow = shadow; self.filter = filter; self.scope = scope; self.grade = grade
    }
    var isPlain: Bool { masks.isIdentity && keys.isEmpty && shadow == nil && filter == nil && grade == nil }
    /// The scope limits this segment's keys (a masked key is a pass of its own).
    public var scopesKeys: Bool {
        !scope.isEmpty && !keys.isEmpty && blurAfter == 0 && shadow == nil && filter == nil && grade == nil
    }
}

/// Evaluated clip effects at one instant (siblings of `ClipTransform`, already clamped). The effect list is walked in
/// order and cut into segments at every active blur, so [Blur, Ultra Key] keys the blurred picture and [Ultra Key, Blur]
/// blurs the keyed one. Without any effect there are no segments.
public struct ClipEffects: Sendable, Hashable {
    public var segments: [EffectSegment]
    /// Film Grain, Gate Weave, Scanlines, Chroma Bleed, Tracking Noise: one pass after all segments.
    public var look: FilmLook = .none
    /// W6.7 clip masks (Opacity masks), top first: cut the finished picture of all segments, in the clip's own frame.
    public var masks: [MaskShape] = []
    /// Video Denoise / Deflicker: run on the decoded source frame (with its neighbors) before everything else. Not part of
    /// `isIdentity` (the frame is replaced before the effect chain; see TemporalEffects.swift).
    public var temporal: TemporalFilter?
    /// Motion's Anti-flicker Filter at this instant, 0...1 (`ClipAnimation.antiFlicker`): a vertical-only softening of the
    /// clip's picture before its effects. 0 = untouched (no pass runs).
    public var antiFlicker: Double = 0

    public init(segments: [EffectSegment] = [], masks: [MaskShape] = [], look: FilmLook = .none) {
        self.segments = segments; self.masks = masks; self.look = look
    }

    /// Simple form: masks before a blur, the blur, masks after it (what most clips have).
    public init(pre: EffectMasks = .none, blur: Double = 0, post: EffectMasks = .none, keys: [ChromaKey] = []) {
        if blur > 0 {
            segments = [EffectSegment(masks: pre, keys: keys, blurAfter: blur), EffectSegment(masks: post)]
        } else if !pre.isIdentity || !keys.isEmpty {
            segments = [EffectSegment(masks: pre, keys: keys)]
        } else {
            segments = []
        }
    }
    public init(cornerRadius: Double) { self.init(pre: EffectMasks(cornerRadius: cornerRadius)) }

    public static let none = ClipEffects()

    // MARK: Simple-form views (the first segment, the blur, the last segment)

    /// Masks of the first pass (the whole stack when there is no blur).
    public var pre: EffectMasks {
        get { segments.first?.masks ?? .none }
        set { if segments.isEmpty { segments = [EffectSegment()] }; segments[0].masks = newValue }
    }
    /// Masks of the last pass when a blur comes before it.
    public var post: EffectMasks {
        get { segments.count > 1 ? segments[segments.count - 1].masks : .none }
        set {
            if segments.count < 2 { segments = [segments.first ?? EffectSegment(), EffectSegment()] }
            segments[segments.count - 1].masks = newValue
        }
    }
    /// All blurs together (Gaussians add in quadrature).
    public var blur: Double {
        get { segments.map { $0.blurAfter * $0.blurAfter }.reduce(0, +).squareRoot() }
        set {
            guard newValue > 0 else { segments = segments.map { var s = $0; s.blurAfter = 0; return s }.filter { !$0.isPlain }; return }
            if segments.isEmpty { segments = [EffectSegment(), EffectSegment()] }
            if segments.count < 2 { segments.append(EffectSegment()) }
            segments[0].blurAfter = newValue
        }
    }
    public var keys: [ChromaKey] {
        get { segments.flatMap(\.keys) }
        set { if segments.isEmpty { segments = [EffectSegment()] }; segments[0].keys = newValue }
    }
    /// Rounded Corners radius of the first pass.
    public var cornerRadius: Double { pre.cornerRadius }

    /// Nothing to do: the renderer takes the plain path and runs none of the effect maths.
    public var isIdentity: Bool {
        masks.isEmpty && segments.allSatisfy { $0.isPlain && $0.blurAfter == 0 } && segments.count <= 1 && look.isIdentity
            && antiFlicker == 0
    }
    /// A crop took away the whole picture: the layer draws nothing.
    public var isEmpty: Bool { segments.contains { $0.masks.crop.isEmpty } }
}

extension ClipEffect {
    /// Slider, checkbox or choice value at clip-local `t`, clamped to the catalog range (catalog default when missing).
    public func scalar(_ key: String, atLocal t: Time) -> Double {
        let spec = EffectCatalog.param(kind, key)
        let p = parameters[key]
        var v = (spec?.isHue == true ? p?.hueValue(atLocal: t) : p?.value(atLocal: t)) ?? spec?.defaultValue ?? 0
        // A hue is a place on a circle: an out-of-range key (an imported 370) is that color, not the 360 the range
        // clamp would make of it.
        if spec?.isHue == true { v = HueMath.wrap(v) }
        return Self.sanitized(v, kind: kind, key: key)
    }

    /// `v` as a parameter may hold it: NaN becomes the catalog default, the catalog range clamps, infinity without a
    /// range becomes 0. A NaN from a file or the agent API would pass min/max unchanged and trap later in Int(...) conversions.
    public static func sanitized(_ v: Double, kind: String, key: String) -> Double {
        let spec = EffectCatalog.param(kind, key)
        let v = v.isNaN ? (spec?.defaultValue ?? 0) : v
        guard let r = spec?.range else { return v.isFinite ? v : 0 }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    /// Checkbox state at clip-local `t` (on from 0.5, so a v23 0/1 slider reads the same).
    public func flag(_ key: String, atLocal t: Time) -> Bool { EffectParamKind.checkbox.isOn(scalar(key, atLocal: t)) }

    /// Choice index at clip-local `t`.
    public func choice(_ key: String, atLocal t: Time) -> Int {
        (EffectCatalog.param(kind, key)?.kind ?? .choice([])).choiceIndex(for: scalar(key, atLocal: t))
    }

    /// Color at clip-local `t`, channels clamped to 0...1 (catalog default, else black, when missing).
    public func color(_ key: String, atLocal t: Time) -> EffectColor {
        if let p = colors[key] { return p.value(atLocal: t).clamped }
        if case .color(let d)? = EffectCatalog.param(kind, key)?.kind { return d }
        return .black
    }

    /// Point at clip-local `t` (catalog default, else zero, when missing).
    public func point(_ key: String, atLocal t: Time) -> Vec2 {
        if let p = points[key] { return p.value(atLocal: t) }
        if case .point(let d)? = EffectCatalog.param(kind, key)?.kind { return d }
        return .zero
    }
}

extension Clip {
    /// Effects at timeline time `t`, in list order.
    public func effects(at t: Time) -> ClipEffects {
        var out = effectsWithoutAntiFlicker(at: t)
        let strength = motionEnabled ? animation.antiFlickerStrength(atLocal: t - start) : 0
        if strength > 0 { out.antiFlicker = strength }
        return out
    }

    private func effectsWithoutAntiFlicker(at t: Time) -> ClipEffects {
        let local = t - start
        if effects.isEmpty {                                  // the common case: only the clip masks (same result as below)
            let masks = maskShapes(atLocal: local)
            return masks.isEmpty ? .none : ClipEffects(segments: [], masks: masks, look: FilmLook())
        }
        func value(_ e: ClipEffect, _ key: String) -> Double { e.scalar(key, atLocal: local) }
        var segs = [EffectSegment()]
        var look = FilmLook()
        var temporal: TemporalFilter?
        let seed = FilmLook.seed(atLocal: local)
        let localSeconds = Double(local.value) / Double(max(1, local.timescale))
        /// The current segment is complete: start a new one (after a blur, or as an extra pass when a merge is impossible).
        func split(blur: Double = 0, repeatEdges: Bool = false) {
            segs[segs.count - 1].blurAfter = blur
            segs[segs.count - 1].blurRepeatsEdges = blur > 0 && repeatEdges
            segs.append(EffectSegment())
        }
        let colorOrder = colorEffectIndices.map { effects[$0].id }
        let proGrade = activeGrade == .pro
        /// A masked key is a pass of its own: what came before is finished first, the keyed image ends the pass.
        func appendKey(_ k: ChromaKey, scope: [MaskShape]) {
            if !scope.isEmpty {
                if !segs[segs.count - 1].isPlain { split() }
                segs[segs.count - 1].keys = [k]
                segs[segs.count - 1].scope = scope
                split()
                return
            }
            if segs[segs.count - 1].keys.count >= ChromaKey.maxPerLayer || segs[segs.count - 1].scopesKeys { split() }
            segs[segs.count - 1].keys.append(k)
        }
        // Anonymize: a cover whose matte no longer fits the picture it reads (an effect in front of it moved pixels) or
        // whose mask is switched off covers the whole frame (AnonymizeOrder.swift).
        let guardsCovers = hasCoverMask
        var moved = false
        for e in effects where e.enabled {
            var scope = inputMaskShapes(e, atLocal: local)
            if guardsCovers {
                if isCover(e), moved || coverInputIsOff(e) { scope = [] }
                if !moved, movesPixels(e, atLocal: local) { moved = true }
            }
            switch e.kind {
            case ClipEffect.colorKind:
                // Unmasked Color effects are the clip's grade (`renderColor`); a masked one is a grade pass here.
                guard !proGrade, hasLiveMaskInput(e), let n = colorOrder.firstIndex(of: e.id), colorEffectRenders(e, position: n, atLocal: local)
                else { continue }
                var ce = e.colorEffect(atLocal: local, id: n + 1)
                let w = e.rangeStrength(atLocal: local)
                if w < 1 { ce = ce.scaled(by: Float(w)) }
                segs[segs.count - 1].grade = ce
                segs[segs.count - 1].scope = scope
                segs.append(EffectSegment())
            case ClipEffect.colorGraphKind:
                continue   // the Pro grade is the clip's grade (`renderColor`)
            case ClipEffect.transformKind where hasLiveMaskInput(e):
                // A masked Transform moves the picture inside its masks instead of moving the clip.
                guard let f = ImageFilter.stage(e.stageTransform(atLocal: local, clipDuration: duration, frame: .zero)) else { continue }
                segs[segs.count - 1].filter = f
                segs[segs.count - 1].scope = scope
                segs.append(EffectSegment())
            case ClipEffect.gaussianBlurKind:
                let b = ClipEffect.gaussianSigma(blurriness: value(e, ClipEffect.blurrinessKey))
                guard b > 0 else { continue }                        // blur 0 is identity: it does not even cut the list
                let edges = e.flag(ClipEffect.repeatEdgePixelsKey, atLocal: local)
                if scope.isEmpty, segs.count > 1, segs[segs.count - 1].isPlain, segs[segs.count - 2].shadow == nil,
                   segs[segs.count - 2].filter == nil, segs[segs.count - 2].scope.isEmpty,
                   segs[segs.count - 2].blurRepeatsEdges == edges {   // two blurs in a row, same edge mode: one Gaussian
                    let prev = segs[segs.count - 2].blurAfter
                    segs[segs.count - 2].blurAfter = (prev * prev + b * b).squareRoot()
                } else {
                    segs[segs.count - 1].scope = scope
                    split(blur: b, repeatEdges: edges)
                }
            case ClipEffect.roundedCornersKind:
                let r = value(e, ClipEffect.radiusKey)
                guard r > 0 else { continue }
                if let m = segs[segs.count - 1].masks.adding(radius: r) { segs[segs.count - 1].masks = m }
                else { split(); segs[segs.count - 1].masks = EffectMasks().adding(radius: r)! }
            case ClipEffect.cropKind:
                let c = CropInsets(left: value(e, ClipEffect.cropLeftKey) / 100, top: value(e, ClipEffect.cropTopKey) / 100,
                                   right: value(e, ClipEffect.cropRightKey) / 100, bottom: value(e, ClipEffect.cropBottomKey) / 100)
                let f = max(0, value(e, ClipEffect.cropSoftnessKey))
                guard !c.isIdentity || f > 0 else { continue }     // softness alone softens the frame edge
                if let m = segs[segs.count - 1].masks.adding(crop: c, feather: f) { segs[segs.count - 1].masks = m }
                else { split(); segs[segs.count - 1].masks = EffectMasks().adding(crop: c, feather: f)! }
            case ClipEffect.ultraKeyKind:
                let tolerance = value(e, ClipEffect.toleranceKey)
                guard tolerance > 0 else { continue }                 // tolerance 0 keys nothing: identity
                var k = ChromaKey(hue: value(e, ClipEffect.keyHueKey), halfWidth: tolerance * 0.9,
                                  soft: 1 + value(e, ClipEffect.softenKey) * 0.6,
                                  spill: value(e, ClipEffect.spillKey) / 100,
                                  choke: value(e, ClipEffect.chokeKey) / 100,
                                  pedestal: value(e, ClipEffect.pedestalKey) / 100)
                k.output = ChromaKey.Output(rawValue: Int(value(e, ClipEffect.keyOutputKey).rounded())) ?? .composite
                k.contrast = value(e, ClipEffect.keyContrastKey) / 100
                k.midpoint = value(e, ClipEffect.keyMidpointKey) / 100
                k.keepHighlights = value(e, ClipEffect.keyHighlightKey) / 100
                k.keepShadows = value(e, ClipEffect.keyShadowKey) / 100
                k.spillRange = value(e, ClipEffect.spillRangeKey) / 100
                k.saturation = value(e, ClipEffect.keySaturationKey) / 100
                k.hueShift = value(e, ClipEffect.keyHueShiftKey)
                k.luma = value(e, ClipEffect.keyLumaKey) / 100
                appendKey(k, scope: scope)
            case ClipEffect.lumaKeyKind:
                let thr = value(e, ClipEffect.lumaThresholdKey) / 100, soft = value(e, ClipEffect.lumaSoftnessKey) / 100
                let brights = value(e, ClipEffect.lumaKeyOutKey) >= 0.5
                var k = ChromaKey.luma(threshold: thr, softness: soft, brights: brights)
                k.choke = value(e, ClipEffect.chokeKey) / 100
                k.contrast = value(e, ClipEffect.keyContrastKey) / 100
                k.midpoint = value(e, ClipEffect.keyMidpointKey) / 100
                k.output = ChromaKey.Output(rawValue: Int(value(e, ClipEffect.keyOutputKey).rounded())) ?? .composite
                appendKey(k, scope: scope)
            // Film / tape look: when a kind is applied twice the later instance wins (one pass, one set of values).
            case ClipEffect.grainKind:
                let amount = value(e, ClipEffect.grainAmountKey) / 100
                look.grain = amount > 0 ? .init(amount: amount, size: value(e, ClipEffect.grainSizeKey),
                                                softness: value(e, ClipEffect.grainSoftnessKey) / 100,
                                                lumaWeight: value(e, ClipEffect.grainResponseKey) / 100,
                                                color: value(e, ClipEffect.grainColorKey) / 100,
                                                seed: value(e, ClipEffect.grainAnimateKey) >= 0.5 ? seed : 0) : nil
            case ClipEffect.agedFilmKind:
                let d = value(e, ClipEffect.dustKey) / 100, s = value(e, ClipEffect.scratchesKey) / 100
                let f = value(e, ClipEffect.flickerKey) / 100
                look.aged = d > 0 || s > 0 || f > 0 ? .init(dust: d, scratches: s, flicker: f, seed: seed) : nil
            case ClipEffect.gateWeaveKind:
                let amount = value(e, ClipEffect.amountKey), rot = value(e, ClipEffect.rotationKey)
                look.weave = amount > 0 || rot > 0
                    ? GateWeave.evaluate(amount: amount, speed: value(e, ClipEffect.speedKey), rotation: rot, atLocalSeconds: localSeconds)
                    : nil
            case ClipEffect.scanlinesKind:
                let i = value(e, ClipEffect.intensityKey) / 100
                look.scanlines = i > 0 ? .init(intensity: i, spacing: value(e, ClipEffect.spacingKey),
                                               thickness: value(e, ClipEffect.thicknessKey) / 100) : nil
            case ClipEffect.chromaBleedKind:
                let b = value(e, ClipEffect.bleedKey), s = value(e, ClipEffect.shiftKey)
                look.chromaBleed = b > 0 || s != 0 ? .init(bleed: b, shift: s) : nil
            case ClipEffect.trackingNoiseKind:
                let a = value(e, ClipEffect.amountKey) / 100
                let phase = (localSeconds * value(e, ClipEffect.speedKey)).truncatingRemainder(dividingBy: 1)
                look.tracking = a > 0 ? .init(amount: a, bandHeight: value(e, ClipEffect.bandHeightKey) / 100,
                                              phase: phase, seed: seed) : nil
            case ClipEffect.videoDenoiseKind, ClipEffect.deflickerKind, ClipEffect.trailsKind:
                var f = temporal ?? TemporalFilter()
                e.applyTemporal(to: &f, atLocal: local)
                temporal = f.isIdentity ? nil : f
            case ClipEffect.posterizeTimeKind, ClipEffect.dateStampKind:
                continue                                              // a time remap / an extra text layer (see `Timeline.videoLayers`)
            case ClipEffect.motionBlurKind:
                continue                                             // blurs the motion (`Clip.motionBlur`), not the picture
            case ClipEffect.dropShadowKind:
                let opacity = value(e, ClipEffect.shadowOpacityKey) / 100
                let only = e.flag(ClipEffect.shadowOnlyKey, atLocal: local)
                guard opacity > 0 || only else { continue }          // invisible shadow, picture kept: identity
                let a = value(e, ClipEffect.shadowDirectionKey) * .pi / 180
                let d = value(e, ClipEffect.shadowDistanceKey)
                let sh = DropShadow(color: e.color(ClipEffect.shadowColorKey, atLocal: local).rgb,
                                    opacity: opacity, dx: d * sin(a), dy: -d * cos(a),
                                    sigma: max(value(e, ClipEffect.shadowSoftnessKey), 0) * ClipEffect.shadowSigmaPerSoftness,
                                    spread: value(e, ClipEffect.shadowSpreadKey) / 100, shadowOnly: only)
                segs[segs.count - 1].shadow = sh
                segs.append(EffectSegment())
            case ClipEffect.stabilizeKind:
                // The correction itself moves the clip, unless Edge Fill warps the picture instead (after the rolling shutter pass).
                if let f = e.rollingShutterFilter(atLocal: local) {
                    segs[segs.count - 1].filter = f
                    segs.append(EffectSegment())
                }
                if e.stabilizeFillsEdges,
                   let f = ImageFilter.stageFill(e.stageTransform(atLocal: local, clipDuration: duration, frame: .zero), fill: e.stabilizeEdgeFill) {
                    segs[segs.count - 1].filter = f
                    segs.append(EffectSegment())
                }
            default:
                guard let f = e.imageFilter(atLocal: local) else { continue }
                segs[segs.count - 1].filter = f
                segs[segs.count - 1].scope = scope
                segs.append(EffectSegment())
            }
        }
        let masks = maskShapes(atLocal: local) + trackMaskShapes(atLocal: local)
        // A lone plain segment is no effect at all; a trailing plain segment after a blur stays (the blurred image is drawn).
        var out: ClipEffects
        if segs.count == 1, segs[0].isPlain {
            out = masks.isEmpty && look.isIdentity ? .none : ClipEffects(segments: [], masks: masks, look: look)
        } else {
            out = ClipEffects(segments: segs, masks: masks, look: look)
        }
        if temporal?.trails != nil { temporal?.trails?.backward = playsBackward(atLocal: local) }
        out.temporal = temporal
        return out
    }
}
