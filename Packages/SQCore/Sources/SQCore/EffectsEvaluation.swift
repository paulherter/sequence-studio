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

/// The mask-like effects of one render pass: Crop and Rounded Corners (drawn as a coverage mask, no extra pass).
public struct EffectMasks: Sendable, Hashable {
    public var crop: CropInsets
    /// Canvas pixels of the clip's own frame, >= 0.
    public var cornerRadius: Double
    public init(crop: CropInsets = .none, cornerRadius: Double = 0) { self.crop = crop; self.cornerRadius = cornerRadius }
    public static let none = EffectMasks()
    public var isIdentity: Bool { crop.isIdentity && cornerRadius == 0 }
    public func merged(with o: EffectMasks) -> EffectMasks {
        EffectMasks(crop: crop.merged(with: o.crop), cornerRadius: max(cornerRadius, o.cornerRadius))
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
    /// Most keys the renderer applies to one layer.
    public static let maxPerLayer = 2
}

/// Evaluated clip effects at one instant (siblings of `ClipTransform`, already clamped). The effect list is walked in
/// order: masks that come before the first active blur land in `pre` (drawn into the image that is then blurred),
/// masks after it in `post` (cut out of the blurred image). Without a blur everything is in `pre`.
public struct ClipEffects: Sendable, Hashable {
    public var pre: EffectMasks
    /// Gaussian standard deviation in px of the clip's own frame; 0 = no blur (the blur pass never runs).
    public var blur: Double
    public var post: EffectMasks
    /// Ultra Keys, applied to the picture before everything else (at most `ChromaKey.maxPerLayer`; later ones are ignored).
    public var keys: [ChromaKey]

    public init(pre: EffectMasks = .none, blur: Double = 0, post: EffectMasks = .none, keys: [ChromaKey] = []) {
        self.pre = pre; self.blur = blur; self.post = post; self.keys = keys
    }
    public init(cornerRadius: Double) { self.init(pre: EffectMasks(cornerRadius: cornerRadius)) }

    public static let none = ClipEffects()
    /// Rounded Corners radius of the first pass (the whole effect stack when there is no blur).
    public var cornerRadius: Double { pre.cornerRadius }
    /// Nothing to do: the renderer takes the plain path and runs none of the effect maths.
    public var isIdentity: Bool { pre.isIdentity && blur == 0 && post.isIdentity && keys.isEmpty }
    /// A crop took away the whole picture: the layer draws nothing.
    public var isEmpty: Bool { pre.crop.isEmpty || post.crop.isEmpty }
}

extension Clip {
    /// Effects at timeline time `t`, in list order.
    public func effects(at t: Time) -> ClipEffects {
        let local = t - start
        var pre = EffectMasks.none, post = EffectMasks.none
        var variance = 0.0
        var keys: [ChromaKey] = []
        func value(_ e: ClipEffect, _ key: String) -> Double {
            let spec = EffectCatalog.param(e.kind, key)
            let v = e.parameters[key]?.value(atLocal: local) ?? spec?.defaultValue ?? 0
            guard let r = spec?.range else { return v }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        // Pass 1: where does the first active blur sit?
        var blurIndex: Int?
        for (i, e) in effects.enumerated() where e.enabled && e.kind == ClipEffect.gaussianBlurKind {
            let b = value(e, ClipEffect.blurrinessKey)
            variance += b * b
            if b > 0, blurIndex == nil { blurIndex = i }
        }
        for (i, e) in effects.enumerated() where e.enabled {
            var m = EffectMasks.none
            switch e.kind {
            case ClipEffect.ultraKeyKind:
                let tolerance = value(e, ClipEffect.toleranceKey)
                if tolerance > 0, keys.count < ChromaKey.maxPerLayer {      // tolerance 0 keys nothing: identity
                    keys.append(ChromaKey(hue: value(e, ClipEffect.keyHueKey), halfWidth: tolerance * 0.9,
                                          soft: 1 + value(e, ClipEffect.softenKey) * 0.6,
                                          spill: value(e, ClipEffect.spillKey) / 100))
                }
                continue
            case ClipEffect.roundedCornersKind:
                m.cornerRadius = value(e, ClipEffect.radiusKey)
            case ClipEffect.cropKind:
                m.crop = CropInsets(left: value(e, ClipEffect.cropLeftKey) / 100, top: value(e, ClipEffect.cropTopKey) / 100,
                                    right: value(e, ClipEffect.cropRightKey) / 100, bottom: value(e, ClipEffect.cropBottomKey) / 100)
            default: continue
            }
            if let bi = blurIndex, i > bi { post = post.merged(with: m) } else { pre = pre.merged(with: m) }
        }
        return ClipEffects(pre: pre, blur: variance.squareRoot(), post: post, keys: keys)
    }
}
