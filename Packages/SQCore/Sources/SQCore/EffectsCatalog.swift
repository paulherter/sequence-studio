import Foundation

/// What kind of value a parameter holds, and so which row Effect Controls shows for it.
public enum EffectParamKind: Sendable, Hashable {
    /// A number (scrub field); stored in `ClipEffect.parameters`.
    case slider
    /// On / off (checkbox), stored as 0 / 1 in `ClipEffect.parameters`; on from 0.5. New keys hold.
    case checkbox
    /// One of `titles` (pop-up), stored as the index in `ClipEffect.parameters`. New keys hold.
    case choice([String])
    /// RGBA color (color well), stored in `ClipEffect.colors`; the associated value is the default.
    case color(EffectColor)
    /// A position in px of the clip's own frame (two scrub fields), stored in `ClipEffect.points`; default attached.
    case point(Vec2)

    /// Stored as a Double in `ClipEffect.parameters`.
    public var isScalar: Bool {
        switch self { case .slider, .checkbox, .choice: true; case .color, .point: false }
    }
    /// Switches from key to key instead of blending (checkbox, choice): new keys get hold interpolation.
    public var isStepped: Bool {
        switch self { case .checkbox, .choice: true; default: false }
    }
    /// Checkbox state of a stored value.
    public func isOn(_ v: Double) -> Bool { v >= 0.5 }
    /// Choice index of a stored value: rounded and kept inside the list.
    public func choiceIndex(for v: Double) -> Int {
        guard case .choice(let titles) = self, !titles.isEmpty else { return 0 }
        guard v.isFinite else { return v > 0 ? titles.count - 1 : 0 }
        return Int(min(max(v.rounded(), 0), Double(titles.count - 1)))
    }
}

public enum PictureAxis: Sendable, Hashable { case width, height }

/// One animatable parameter of an applied effect (what Effect Controls shows as a row).
public struct EffectParamSpec: Sendable, Hashable {
    public var key: String
    public var title: String
    public var unit: String
    /// Slider / checkbox / choice default (unused for color and point: their default sits in `kind`).
    public var defaultValue: Double
    public var range: ClosedRange<Double>
    public var step: Double
    public var decimals: Int
    public var kind: EffectParamKind = .slider
    /// Shown value = stored value x this (Group Transform shows Scale and Opacity as percent, like Motion). 1 = as stored.
    public var displayScale: Double = 1
    /// Stored as percent of the clip's own picture along this axis, shown in px of it (Crop). The unit and the numbers
    /// fall back to percent while the picture size is unknown. nil = no such mapping.
    public var pictureAxis: PictureAxis? = nil
    /// A hue in degrees round the color circle: keys take the short way round (COL-25). Not stored.
    public var isHue: Bool = false

    static func checkbox(_ key: String, _ title: String, on: Bool = false) -> EffectParamSpec {
        EffectParamSpec(key: key, title: title, unit: "", defaultValue: on ? 1 : 0, range: 0...1, step: 1, decimals: 0, kind: .checkbox)
    }
    static func choice(_ key: String, _ title: String, _ titles: [String], default index: Int = 0) -> EffectParamSpec {
        EffectParamSpec(key: key, title: title, unit: "", defaultValue: Double(index), range: 0...Double(max(titles.count - 1, 0)),
                        step: 1, decimals: 0, kind: .choice(titles))
    }
    static func color(_ key: String, _ title: String, _ value: EffectColor) -> EffectParamSpec {
        EffectParamSpec(key: key, title: title, unit: "", defaultValue: 0, range: 0...1, step: 0, decimals: 0, kind: .color(value))
    }
    static func point(_ key: String, _ title: String, _ value: Vec2 = .zero, unit: String = "px") -> EffectParamSpec {
        EffectParamSpec(key: key, title: title, unit: unit, defaultValue: 0, range: -100_000...100_000, step: 1, decimals: 1,
                        kind: .point(value))
    }
}

/// Two scalar parameters shown and edited as one X/Y row (Transform / Auto Reframe Position and Anchor). Storage stays
/// two separate scalar tracks (format-variant overrides work per key); `KeyframesPair` aligns and zips them.
public struct EffectParamPair: Sendable, Hashable {
    public var title: String
    /// Parameter keys of the two members (`EffectParamSpec.key`).
    public var x: String
    public var y: String
    /// Y is stored only while the pair is unlinked: absent = Y follows X (Transform Scale, P5). Never created by default.
    public var linkable = false
    public init(title: String, x: String, y: String, linkable: Bool = false) {
        self.title = title; self.x = x; self.y = y; self.linkable = linkable
    }

    /// Position and Anchor of an effect transform stage, in row order.
    public static let stagePairs = [
        EffectParamPair(title: "Position", x: ClipEffect.stagePositionXKey, y: ClipEffect.stagePositionYKey),
        EffectParamPair(title: "Scale", x: ClipEffect.stageScaleKey, y: ClipEffect.stageScaleYKey, linkable: true),
        EffectParamPair(title: "Anchor", x: ClipEffect.stageAnchorXKey, y: ClipEffect.stageAnchorYKey),
    ]
}

/// An effect the Effects panel can apply. Kinds are the strings stored in `ClipEffect.kind`.
public struct EffectSpec: Sendable, Hashable {
    public var kind: String
    public var title: String
    public var params: [EffectParamSpec]
    /// X/Y parameter pairs shown as one row each (empty for most effects).
    public var pairs: [EffectParamPair] = []

    /// The pair `key` belongs to, if any.
    public func pair(containing key: String) -> EffectParamPair? {
        pairs.first { $0.x == key || $0.y == key }
    }
}

extension ClipEffect {
    // W3.1 kinds and parameter keys (stored strings: never rename).
    public static let sharpenKind = "sharpen", sharpenAmountKey = "sharpenAmount"
    public static let directionalBlurKind = "directionalBlur", blurDirectionKey = "blurDirection", blurLengthKey = "blurLength"
    public static let mirrorKind = "mirror", mirrorCenterKey = "reflectionCenter", mirrorAngleKey = "reflectionAngle"
    public static let noiseKind = "noise", noiseAmountKey = "noiseAmount", noiseColorKey = "colorNoise", noiseClipKey = "clipResult"
    public static let glowKind = "glow", glowThresholdKey = "glowThreshold", glowRadiusKey = "glowRadius"
    public static let glowIntensityKey = "glowIntensity", glowColorsKey = "glowColors", glowColorKey = "glowColor"
    public static let mosaicKind = "mosaic", mosaicColumnsKey = "horizontalBlocks", mosaicRowsKey = "verticalBlocks"
    public static let mosaicSharpKey = "sharpColors"
    public static let unsharpMaskKind = "unsharpMask", unsharpRadiusKey = "unsharpRadius"
    public static let unsharpAmountKey = "unsharpAmount", unsharpThresholdKey = "unsharpThreshold"
}

public enum EffectCatalog {
    /// Every video spec, hidden ones included (`spec(for:)` resolves them); `all` is what the UI offers.
    static let everySpec: [EffectSpec] = [
        EffectSpec(kind: ClipEffect.roundedCornersKind, title: "Rounded Corners", params: [
            EffectParamSpec(key: ClipEffect.radiusKey, title: "Radius", unit: "px", defaultValue: 24,
                            range: 0...10_000, step: 1, decimals: 0),
        ]),
        EffectSpec(kind: ClipEffect.cropKind, title: "Crop", params: [
            EffectParamSpec(key: ClipEffect.cropLeftKey, title: "Left", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1, pictureAxis: .width),
            EffectParamSpec(key: ClipEffect.cropTopKey, title: "Top", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1, pictureAxis: .height),
            EffectParamSpec(key: ClipEffect.cropRightKey, title: "Right", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1, pictureAxis: .width),
            EffectParamSpec(key: ClipEffect.cropBottomKey, title: "Bottom", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1, pictureAxis: .height),
            EffectParamSpec(key: ClipEffect.cropSoftnessKey, title: "Softness", unit: "px", defaultValue: 0, range: 0...1_000, step: 1, decimals: 0),
        ]),
        EffectSpec(kind: ClipEffect.gaussianBlurKind, title: "Blur", params: [
            EffectParamSpec(key: ClipEffect.blurrinessKey, title: "Amount", unit: "", defaultValue: 0,
                            range: 0...3_000, step: 0.5, decimals: 1),
            .checkbox(ClipEffect.repeatEdgePixelsKey, "Repeat Edge Pixels"),
        ]),
        // Premiere's Drop Shadow: direction 0 = up, clockwise; distance and softness in px of the clip's own frame.
        // Shadow Color is one keyframable color (v24; before: three 0...255 channels); Shadow Only is a checkbox.
        EffectSpec(kind: ClipEffect.dropShadowKind, title: "Drop Shadow", params: [
            .color(ClipEffect.shadowColorKey, "Shadow Color", .black),
            EffectParamSpec(key: ClipEffect.shadowOpacityKey, title: "Opacity", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.shadowDirectionKey, title: "Direction", unit: "\u{00B0}", defaultValue: 135, range: -3_600...3_600, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.shadowDistanceKey, title: "Distance", unit: "px", defaultValue: 5, range: 0...1_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.shadowSpreadKey, title: "Spread", unit: "%", defaultValue: 0, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.shadowSoftnessKey, title: "Softness", unit: "px", defaultValue: 5, range: 0...1_000, step: 1, decimals: 0),
            .checkbox(ClipEffect.shadowOnlyKey, "Shadow Only"),
        ]),
        // Chroma key (Ultra Key family): pick the hue to remove (green 120, blue 220), how far around it and how soft. Matte
        // generation: Keep Highlights / Keep Shadows leave bright / dark pixels of the subject alone, Black level drops weak
        // keying. Matte clean-up (shared `MatteRefine`): Shrink / Grow, Contrast, Midpoint. Spill: Spill amount and Range.
        // Color correction applies to the kept picture. Defaults leave every new control neutral; the "Green Screen" and
        // "Blue Screen" presets (`KeyingPresets`) carry the starting values.
        EffectSpec(kind: ClipEffect.ultraKeyKind, title: "Color Key", params: [
            EffectParamSpec(key: ClipEffect.keyHueKey, title: "Key Hue", unit: "\u{00B0}", defaultValue: 120, range: 0...360, step: 1, decimals: 0, isHue: true),
            EffectParamSpec(key: ClipEffect.toleranceKey, title: "Tolerance", unit: "%", defaultValue: 40, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.softenKey, title: "Soften", unit: "%", defaultValue: 20, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyHighlightKey, title: "Keep Highlights", unit: "%", defaultValue: 0, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyShadowKey, title: "Keep Shadows", unit: "%", defaultValue: 0, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.pedestalKey, title: "Black level", unit: "%", defaultValue: 0, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.chokeKey, title: "Shrink / Grow", unit: "%", defaultValue: 0, range: -100...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyContrastKey, title: "Matte Contrast", unit: "%", defaultValue: 0, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyMidpointKey, title: "Matte Midpoint", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.spillKey, title: "Spill", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.spillRangeKey, title: "Spill Range", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keySaturationKey, title: "Saturation", unit: "%", defaultValue: 100, range: 0...200, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyHueShiftKey, title: "Hue Shift", unit: "\u{00B0}", defaultValue: 0, range: -180...180, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyLumaKey, title: "Brightness", unit: "%", defaultValue: 100, range: 0...200, step: 1, decimals: 0),
            // Output: Composite = the keyed picture; Alpha = the matte as black / white (white kept), for tuning the key;
            // Source = the picture before keying, for comparing.
            .choice(ClipEffect.keyOutputKey, "Output", ["Composite", "Alpha", "Source"]),
        ]),
        // Luma key: removes the darks (or brights) of a picture, e.g. a title on white or black, a light flash.
        EffectSpec(kind: ClipEffect.lumaKeyKind, title: "Luma Key", params: [
            .choice(ClipEffect.lumaKeyOutKey, "Key Out", ["Darks", "Brights"]),
            EffectParamSpec(key: ClipEffect.lumaThresholdKey, title: "Threshold", unit: "%", defaultValue: 20, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.lumaSoftnessKey, title: "Softness", unit: "%", defaultValue: 10, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.chokeKey, title: "Shrink / Grow", unit: "%", defaultValue: 0, range: -100...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyContrastKey, title: "Matte Contrast", unit: "%", defaultValue: 0, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.keyMidpointKey, title: "Matte Midpoint", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            .choice(ClipEffect.keyOutputKey, "Output", ["Composite", "Alpha", "Source"]),
        ]),
        // Track Mask: another video track's picture limits this clip (its alpha, or its brightness). The track itself is not a
        // number: it is `ClipEffect.maskTrack`, picked on its own row. Evaluates to a Picture mask (`TrackMaskEffect.swift`).
        EffectSpec(kind: ClipEffect.trackMaskKind, title: "Track Mask", params: [
            .choice(ClipEffect.trackMaskModeKey, "Mode", ["Alpha", "Luma"]),
            .checkbox(ClipEffect.trackMaskInvertKey, "Invert"),
        ]),
    ] + batch1 + [ColorGradeFields.spec, ClipEffect.colorGraphSpec, EffectTransformStage.transformSpec] + MotionEffects.offeredSpecs + StyleEffects.specs

    /// The video effects the Effects panel, palette and Add Effect lists offer (`HiddenCatalog` ones left out).
    /// The Color Graph (Pro grade) is left out: the Color panel's Simple | Pro switch adds it.
    public static let all: [EffectSpec] = offeredVideo(hiding: HiddenCatalog.isActive)
    /// The same list for an explicit switch (tests; `all` uses the app-level default).
    public static func offeredVideo(hiding: Bool) -> [EffectSpec] {
        everySpec.filter { !HiddenCatalog.isHidden(effectKind: $0.kind, active: hiding) && $0.kind != ClipEffect.colorGraphKind }
    }

    /// W3.1. Each evaluates into one `ImageFilter` (see `Clip.effects(at:)`); px are px of the clip's own frame.
    static let batch1: [EffectSpec] = [
        // Premiere's Sharpen: 0 does nothing, 100 adds the full difference to a 3 x 3 neighborhood once.
        EffectSpec(kind: ClipEffect.sharpenKind, title: "Sharpen", params: [
            EffectParamSpec(key: ClipEffect.sharpenAmountKey, title: "Amount", unit: "", defaultValue: 0,
                            range: 0...4_000, step: 1, decimals: 0),
        ]),
        // Unsharp Mask: adds Amount % of the difference to a blur of Radius px, only where that difference is above
        // Threshold. Amount 0 does nothing (the drop-in default). Radius 2 px = a Gaussian of sigma 1 px.
        EffectSpec(kind: ClipEffect.unsharpMaskKind, title: "Unsharp Mask", params: [
            EffectParamSpec(key: ClipEffect.unsharpRadiusKey, title: "Radius", unit: "px", defaultValue: 2,
                            range: 0...12, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.unsharpAmountKey, title: "Amount", unit: "%", defaultValue: 0,
                            range: 0...500, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.unsharpThresholdKey, title: "Threshold", unit: "%", defaultValue: 0,
                            range: 0...100, step: 0.5, decimals: 1),
        ]),
        // Premiere's Directional Blur: direction 0 smears vertically, clockwise; Blur Length is the whole smear in px.
        EffectSpec(kind: ClipEffect.directionalBlurKind, title: "Directional Blur", params: [
            EffectParamSpec(key: ClipEffect.blurDirectionKey, title: "Direction", unit: "\u{00B0}", defaultValue: 0,
                            range: -3_600...3_600, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.blurLengthKey, title: "Length", unit: "px", defaultValue: 0,
                            range: 0...1_000, step: 0.5, decimals: 1),
        ]),
        // Premiere's Mirror: a line through Reflection Center; at 0 degrees the left side is reflected onto the right, at 90
        // the top onto the bottom. The center is an offset from the frame center (like Position / Anchor Point), y down.
        EffectSpec(kind: ClipEffect.mirrorKind, title: "Mirror", params: [
            .point(ClipEffect.mirrorCenterKey, "Reflection Center"),
            EffectParamSpec(key: ClipEffect.mirrorAngleKey, title: "Angle", unit: "\u{00B0}", defaultValue: 0,
                            range: -3_600...3_600, step: 1, decimals: 0),
        ]),
        // Premiere's Noise: a new grain pattern every frame. Color noise varies each channel on its own; Clip Result keeps
        // values inside the picture's range.
        EffectSpec(kind: ClipEffect.noiseKind, title: "Noise", params: [
            EffectParamSpec(key: ClipEffect.noiseAmountKey, title: "Amount", unit: "%", defaultValue: 0,
                            range: 0...100, step: 0.5, decimals: 1),
            .checkbox(ClipEffect.noiseColorKey, "Use Color Noise", on: true),
            .checkbox(ClipEffect.noiseClipKey, "Clip Result Values", on: true),
        ]),
        // Glow: what is brighter than Threshold (luma) is blurred (Radius = 2 sigma) and added on top, Intensity times.
        EffectSpec(kind: ClipEffect.glowKind, title: "Glow", params: [
            EffectParamSpec(key: ClipEffect.glowThresholdKey, title: "Threshold", unit: "%", defaultValue: 60,
                            range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.glowRadiusKey, title: "Radius", unit: "px", defaultValue: 20,
                            range: 0...1_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.glowIntensityKey, title: "Intensity", unit: "", defaultValue: 1,
                            range: 0...10, step: 0.05, decimals: 2),
            .choice(ClipEffect.glowColorsKey, "Glow Colors", ["Original Colors", "Glow Color"]),
            .color(ClipEffect.glowColorKey, "Glow Color", .white),
        ]),
        // Premiere's Mosaic: the frame cut into blocks, each filled with its average color (Sharp Colors: its center pixel).
        EffectSpec(kind: ClipEffect.mosaicKind, title: "Mosaic", params: [
            EffectParamSpec(key: ClipEffect.mosaicColumnsKey, title: "Columns", unit: "", defaultValue: 10,
                            range: 1...4_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.mosaicRowsKey, title: "Rows", unit: "", defaultValue: 10,
                            range: 1...4_000, step: 1, decimals: 0),
            .checkbox(ClipEffect.mosaicSharpKey, "Sharp Colors"),
        ]),
    ] + filmLook + temporal + posterizeTime + dateStamp

    // Film / tape look. Defaults are chosen values (the design notes), tuned to be visible but tasteful at once: gate weave a few px,
    // scanlines and tracking noise visible at once. Grain (Film Grain) and glow (Glow) live in the single effects.
    static let filmLook: [EffectSpec] = {
        func p(_ key: String, _ title: String, _ unit: String, _ def: Double, _ range: ClosedRange<Double>,
               step: Double = 1, decimals: Int = 0) -> EffectParamSpec {
            EffectParamSpec(key: key, title: title, unit: unit, defaultValue: def, range: range, step: step, decimals: decimals)
        }
        return [
            EffectSpec(kind: ClipEffect.gateWeaveKind, title: "Gate Weave", params: [
                p(ClipEffect.amountKey, "Amount", "px", 3, 0...30, step: 0.1, decimals: 1),
                p(ClipEffect.speedKey, "Speed", "Hz", 2.5, 0.1...12, step: 0.1, decimals: 1),
                p(ClipEffect.rotationKey, "Rotation", "\u{00B0}", 0.15, 0...2, step: 0.01, decimals: 2),
            ]),
            EffectSpec(kind: ClipEffect.agedFilmKind, title: "Aged Film", params: [
                p(ClipEffect.dustKey, "Dust", "%", 40, 0...100),
                p(ClipEffect.scratchesKey, "Scratches", "%", 30, 0...100),
                p(ClipEffect.flickerKey, "Flicker", "%", 25, 0...100),
            ]),
            EffectSpec(kind: ClipEffect.scanlinesKind, title: "Scanlines", params: [
                p(ClipEffect.intensityKey, "Intensity", "%", 30, 0...100),
                p(ClipEffect.spacingKey, "Line Spacing", "px", 4, 2...32),
                p(ClipEffect.thicknessKey, "Thickness", "%", 50, 10...90),
            ]),
            EffectSpec(kind: ClipEffect.chromaBleedKind, title: "Chroma Bleed", params: [
                p(ClipEffect.bleedKey, "Bleed", "px", 6, 0...60, step: 0.5, decimals: 1),
                p(ClipEffect.shiftKey, "Shift", "px", 2, -30...30, step: 0.5, decimals: 1),
            ]),
            EffectSpec(kind: ClipEffect.trackingNoiseKind, title: "Tracking Noise", params: [
                p(ClipEffect.amountKey, "Amount", "%", 35, 0...100),
                p(ClipEffect.bandHeightKey, "Band Height", "%", 12, 2...50),
                p(ClipEffect.speedKey, "Speed", "Hz", 0.4, 0...4, step: 0.05, decimals: 2),
            ]),
        ]
    }()

    /// Every known kind, including the generator-owned ones (`generatorSpecs`) the Effects panel does not offer.
    public static func spec(for kind: String) -> EffectSpec? {
        if MotionEffects.retiredKinds.contains(kind) { return MotionEffects.specs.first { $0.kind == kind } }
        if let s = everySpec.first(where: { $0.kind == kind }) ?? everyAudioSpec.first(where: { $0.kind == kind })
            ?? generatorSpecs.first(where: { $0.kind == kind }) { return s }
        switch kind {
        case ClipEffect.reframeKind: return EffectTransformStage.reframeSpec
        case ClipEffect.dynamicZoomKind: return EffectTransformStage.dynamicZoomSpec
        case ClipEffect.stabilizeKind: return EffectTransformStage.stabilizeSpec
        case ClipEffect.groupTransformKind: return ClipEffect.groupTransformSpec
        default: return nil
        }
    }
    public static func title(for kind: String) -> String { spec(for: kind)?.title ?? EffectStackPresets.preset(rowID: kind)?.name ?? kind }
    public static func param(_ kind: String, _ key: String) -> EffectParamSpec? {
        spec(for: kind)?.params.first { $0.key == key }
    }
}

extension ClipEffect {
    /// The W3.1 filter this effect makes at clip-local `t`, or nil when it is not such an effect or does nothing.
    func imageFilter(atLocal t: Time) -> ImageFilter? {
        func v(_ key: String) -> Double { scalar(key, atLocal: t) }
        switch kind {
        case Self.sharpenKind:
            let a = v(Self.sharpenAmountKey) / 100
            return a > 0 ? .sharpen(amount: a) : nil
        case Self.unsharpMaskKind:
            let a = v(Self.unsharpAmountKey) / 100, r = v(Self.unsharpRadiusKey)
            return a > 0 && r > 0 ? .unsharpMask(sigma: r / 2, amount: a, threshold: v(Self.unsharpThresholdKey) / 100) : nil
        case Self.directionalBlurKind:
            let len = v(Self.blurLengthKey), a = v(Self.blurDirectionKey) * .pi / 180
            return len > 0 ? .directionalBlur(dx: len * sin(a), dy: -len * cos(a)) : nil
        case Self.mirrorKind:
            return .mirror(center: point(Self.mirrorCenterKey, atLocal: t), angle: v(Self.mirrorAngleKey))
        case Self.noiseKind:
            let a = v(Self.noiseAmountKey) / 100
            guard a > 0 else { return nil }
            return .noise(amount: a, color: flag(Self.noiseColorKey, atLocal: t), clip: flag(Self.noiseClipKey, atLocal: t),
                          seed: Self.noiseSeed(t))
        case Self.glowKind:
            let i = v(Self.glowIntensityKey), th = v(Self.glowThresholdKey) / 100
            guard i > 0, th < 1 else { return nil }
            let tint = choice(Self.glowColorsKey, atLocal: t) == 1 ? color(Self.glowColorKey, atLocal: t).rgb : nil
            return .glow(threshold: th, sigma: v(Self.glowRadiusKey) / 2, intensity: i, color: tint)
        case Self.mosaicKind:
            return .mosaic(columns: max(1, Int(v(Self.mosaicColumnsKey).rounded())), rows: max(1, Int(v(Self.mosaicRowsKey).rounded())),
                           sharp: flag(Self.mosaicSharpKey, atLocal: t))
        default:
            return styleFilter(atLocal: t)
        }
    }

    /// One seed per instant (rational: 1/25 and 2/50 are the same instant), well mixed so neighboring frames differ.
    static func noiseSeed(_ t: Time) -> UInt32 {
        var h = UInt64(bitPattern: t.value) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: t.timescale) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 31; h &*= 0xBF58_476D_1CE4_E5B9; h ^= h >> 29
        return UInt32(truncatingIfNeeded: h)
    }
}
