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
    public init(crop: CropInsets = .none, cornerRadius: Double = 0, roundFirst: Bool = false) {
        self.crop = crop; self.cornerRadius = cornerRadius; self.roundFirst = roundFirst
    }
    public static let none = EffectMasks()
    public var isIdentity: Bool { crop.isIdentity && cornerRadius == 0 }

    /// Adds Rounded Corners after what is already here, or nil when one mask cannot express the pair (Crop, Rounded Corners,
    /// Crop again): the caller then starts a new pass.
    func adding(radius r: Double) -> EffectMasks? {
        var m = self
        if cornerRadius == 0 { m.cornerRadius = r; m.roundFirst = false; return m }
        // A radius exists: with no crop, or in the order Crop then Rounded Corners, the larger radius stands for both.
        if crop.isIdentity || !roundFirst { m.cornerRadius = max(cornerRadius, r); return m }
        return nil                                  // Rounded Corners, Crop, Rounded Corners: not one mask
    }

    /// Adds a Crop after what is already here (see `adding(radius:)`).
    func adding(crop c: CropInsets) -> EffectMasks? {
        var m = self
        if cornerRadius == 0 { m.crop = crop.merged(with: c); return m }
        if crop.isIdentity { m.crop = c; m.roundFirst = true; return m }
        if roundFirst { m.crop = crop.merged(with: c); return m }
        return nil
    }
}

/// One Ultra Key at one instant, in the units the renderer uses (degrees of hue).
public struct ChromaKey: Sendable, Hashable {
    /// Hue to remove, 0...360.
    public var hue: Double
    /// Pixels within this many degrees of `hue` are keyed out completely.
    public var halfWidth: Double
    /// Width in degrees of the soft edge beyond `halfWidth` (at least 1).
    public var soft: Double
    /// Share (0...1) of the coloured spill near the key hue that is desaturated.
    public var spill: Double
    public init(hue: Double, halfWidth: Double, soft: Double, spill: Double) {
        self.hue = hue; self.halfWidth = halfWidth; self.soft = soft; self.spill = spill
    }
    /// Most keys the renderer applies in one pass.
    public static let maxPerLayer = 2
}

/// What happens to the picture between two blurs: masks and keys. They commute with each other (both only change alpha or
/// per-pixel colour), so they share one pass; a blur is a neighbourhood operation and ends the segment.
public struct EffectSegment: Sendable, Hashable {
    public var masks: EffectMasks
    public var keys: [ChromaKey]
    /// Gaussian sigma in px applied after this segment's masks and keys; 0 = none. A segment with 0 that is not the last
    /// one is an extra pass (the effects before and after it could not be merged).
    public var blurAfter: Double
    public init(masks: EffectMasks = .none, keys: [ChromaKey] = [], blurAfter: Double = 0) {
        self.masks = masks; self.keys = keys; self.blurAfter = blurAfter
    }
    var isPlain: Bool { masks.isIdentity && keys.isEmpty }
}

/// Evaluated clip effects at one instant (siblings of `ClipTransform`, already clamped). The effect list is walked in
/// order and cut into segments at every active blur, so [Blur, Ultra Key] keys the blurred picture and [Ultra Key, Blur]
/// blurs the keyed one. Without any effect there are no segments.
public struct ClipEffects: Sendable, Hashable {
    public var segments: [EffectSegment]

    public init(segments: [EffectSegment] = []) { self.segments = segments }

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
    public var isIdentity: Bool { segments.allSatisfy { $0.isPlain && $0.blurAfter == 0 } && segments.count <= 1 }
    /// A crop took away the whole picture: the layer draws nothing.
    public var isEmpty: Bool { segments.contains { $0.masks.crop.isEmpty } }
}

extension Clip {
    /// Effects at timeline time `t`, in list order.
    public func effects(at t: Time) -> ClipEffects {
        let local = t - start
        func value(_ e: ClipEffect, _ key: String) -> Double {
            let spec = EffectCatalog.param(e.kind, key)
            let v = e.parameters[key]?.value(atLocal: local) ?? spec?.defaultValue ?? 0
            guard let r = spec?.range else { return v }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        var segs = [EffectSegment()]
        /// The current segment is complete: start a new one (after a blur, or as an extra pass when a merge is impossible).
        func split(blur: Double = 0) {
            segs[segs.count - 1].blurAfter = blur
            segs.append(EffectSegment())
        }
        for e in effects where e.enabled {
            switch e.kind {
            case ClipEffect.gaussianBlurKind:
                let b = value(e, ClipEffect.blurrinessKey)
                guard b > 0 else { continue }                        // blur 0 is identity: it does not even cut the list
                if segs.count > 1, segs[segs.count - 1].isPlain {     // two blurs in a row: one Gaussian
                    let prev = segs[segs.count - 2].blurAfter
                    segs[segs.count - 2].blurAfter = (prev * prev + b * b).squareRoot()
                } else {
                    split(blur: b)
                }
            case ClipEffect.roundedCornersKind:
                let r = value(e, ClipEffect.radiusKey)
                guard r > 0 else { continue }
                if let m = segs[segs.count - 1].masks.adding(radius: r) { segs[segs.count - 1].masks = m }
                else { split(); segs[segs.count - 1].masks = EffectMasks().adding(radius: r)! }
            case ClipEffect.cropKind:
                let c = CropInsets(left: value(e, ClipEffect.cropLeftKey) / 100, top: value(e, ClipEffect.cropTopKey) / 100,
                                   right: value(e, ClipEffect.cropRightKey) / 100, bottom: value(e, ClipEffect.cropBottomKey) / 100)
                guard !c.isIdentity else { continue }
                if let m = segs[segs.count - 1].masks.adding(crop: c) { segs[segs.count - 1].masks = m }
                else { split(); segs[segs.count - 1].masks = EffectMasks().adding(crop: c)! }
            case ClipEffect.ultraKeyKind:
                let tolerance = value(e, ClipEffect.toleranceKey)
                guard tolerance > 0 else { continue }                 // tolerance 0 keys nothing: identity
                if segs[segs.count - 1].keys.count >= ChromaKey.maxPerLayer { split() }
                segs[segs.count - 1].keys.append(ChromaKey(hue: value(e, ClipEffect.keyHueKey), halfWidth: tolerance * 0.9,
                                                           soft: 1 + value(e, ClipEffect.softenKey) * 0.6,
                                                           spill: value(e, ClipEffect.spillKey) / 100))
            default: continue
            }
        }
        // A lone plain segment is no effect at all; a trailing plain segment after a blur stays (the blurred image is drawn).
        if segs.count == 1, segs[0].isPlain { return .none }
        return ClipEffects(segments: segs)
    }
}
