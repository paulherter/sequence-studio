import Foundation

/// An effect explicitly applied to a clip (v9). Absent from `Clip.effects` = not applied: Effect Controls shows no
/// section for it and the renderer ignores it. Parameters are animatable, clip-local like `ClipAnimation`.
public struct ClipEffect: Sendable, Hashable, Codable, Identifiable {
    public static let roundedCornersKind = "roundedCorners"
    public static let radiusKey = "radius"
    public static let cropKind = "crop"
    public static let cropLeftKey = "left", cropTopKey = "top", cropRightKey = "right", cropBottomKey = "bottom"
    /// Soft edge of the crop, px of the clip's own frame (0 = hard edge). Not stored by Crops saved before it: reads 0.
    public static let cropSoftnessKey = "softness"
    public static let gaussianBlurKind = "gaussianBlur"
    /// Blurriness in Premiere's units (Premiere value = SQ value); the effect turns it into a Gaussian sigma in px with
    /// `gaussianSigma(blurriness:)`.
    public static let blurrinessKey = "blurriness"
    /// Gaussian sigma (px) per Premiere Blurriness unit. Measured with Tools/PrprojFidelity on iOS 27 Features #1
    /// (Blurriness 200, Repeat Edge Pixels on): 0.25...0.42 within 0.1 dB of Premiere's export, 1.0 is 1.3 dB worse and
    /// 4x the bad pixels; 0.35 is the middle of the flat optimum.
    public static let gaussianSigmaPerBlurriness = 0.35
    /// Gaussian sigma in px for a Blurriness value.
    public static func gaussianSigma(blurriness: Double) -> Double { max(blurriness, 0) * gaussianSigmaPerBlurriness }
    /// Drop Shadow Softness is in Premiere units too: Premiere's shadow is a Gaussian of sigma ~0.2 x Softness
    /// (fidelity sweep on the maintainer's Drop Shadow nest, softness 177: luma bias -1.9 at Softness / 2, ~0 at 0.2).
    public static let shadowSigmaPerSoftness = 0.2
    /// Gaussian Blur checkbox: samples outside the frame repeat the edge pixels and the result is cut to the frame, so the
    /// edge stays opaque (Premiere's Repeat Edge Pixels). Off: the blur fades into transparency past the frame.
    public static let repeatEdgePixelsKey = "repeatEdgePixels"
    public static let ultraKeyKind = "ultraKey"
    public static let dropShadowKind = "dropShadow"
    public static let shadowColorKey = "shadowColor"
    /// v23 and older: the shadow color as three 0...255 channel parameters (the v24 migration folds them into `shadowColorKey`).
    public static let shadowRedKey = "shadowRed", shadowGreenKey = "shadowGreen", shadowBlueKey = "shadowBlue"
    public static let shadowOpacityKey = "shadowOpacity", shadowDirectionKey = "shadowDirection"
    public static let shadowDistanceKey = "shadowDistance", shadowSoftnessKey = "shadowSoftness", shadowSpreadKey = "shadowSpread", shadowOnlyKey = "shadowOnly"
    public static let keyHueKey = "keyHue", toleranceKey = "tolerance", softenKey = "soften", spillKey = "spill",
        chokeKey = "choke", pedestalKey = "pedestal", keyOutputKey = "keyOutput"
    /// Ultra Key matte clean-up, spill range and color correction (see `ChromaKey`).
    public static let keyContrastKey = "keyContrast", keyMidpointKey = "keyMidpoint", keyHighlightKey = "keyHighlight",
        keyShadowKey = "keyShadow", spillRangeKey = "spillRange", keySaturationKey = "keySaturation",
        keyHueShiftKey = "keyHueShift", keyLumaKey = "keyLuma"
    /// Luma key.
    public static let lumaKeyKind = "lumaKey"
    public static let lumaThresholdKey = "lumaThreshold", lumaSoftnessKey = "lumaSoftness", lumaKeyOutKey = "lumaKeyOut"

    // Film / tape look (see `FilmLook`). Film Grain (`grainKind`) is part of it; Glow covers halation and bloom.
    public static let gateWeaveKind = "gateWeave"
    public static let scanlinesKind = "scanlines"
    public static let chromaBleedKind = "chromaBleed"
    public static let trackingNoiseKind = "trackingNoise"
    /// Aged Film: dust specks, vertical scratches and exposure flicker of worn film (one effect, one pass; `FilmLook.Aged`).
    public static let agedFilmKind = "agedFilm"
    public static let dustKey = "dust", scratchesKey = "scratches", flickerKey = "flicker"
    public static let amountKey = "amount"
    public static let intensityKey = "intensity", speedKey = "speed", rotationKey = "rotation"
    public static let spacingKey = "spacing", thicknessKey = "thickness", bleedKey = "bleed", shiftKey = "shift"
    public static let bandHeightKey = "bandHeight"

    public var id: UUID
    public var kind: String
    /// fx toggle: a disabled effect stays applied (and keeps its values) but renders as if absent.
    public var enabled: Bool
    /// Slider, checkbox (0/1) and choice (index) parameters.
    public var parameters: [String: AnimatedProperty<Double>]
    /// Color parameters (v24), display-encoded 0...1 channels.
    public var colors: [String: AnimatedProperty<EffectColor>]
    /// Point parameters (v24), px of the clip's own frame.
    public var points: [String: AnimatedProperty<Vec2>]
    /// LUTs and curves of a Color effect (v27, kind `color`; see ColorGradeEffect.swift). nil for other kinds.
    public var grade: ColorGradeData?
    /// COLOR-GRADE-LINKS (v45): a Color effect that grades only this clip-local range (a range grade, never the first
    /// Color effect); nil = the whole clip. Moves with trims and retimes like keys (ColorGradeLinks.swift).
    public var colorRange: TimeRange?
    /// v50: soft edges of a range grade, durations (clip-local) of the strength ramp at the start / end of `colorRange`.
    /// nil = hard edge. Only meaningful with `colorRange`.
    public var colorFadeIn: Time?
    public var colorFadeOut: Time?
    /// v54: masks of the clip (`Clip.masks` ids, combined in the clip's list order) that limit where this effect shows;
    /// empty = the whole picture. Only kinds with `acceptsMaskInput`. Stored only when not empty ("masks").
    public var maskInput: [UUID] = []
    /// v78: the Pro grade of a Color Graph effect (kind `colorGraph`, ColorGraph.swift). nil for other kinds.
    public var colorGraph: ColorGraph?
    /// v90: the video track a Track Mask effect reads (kind `trackMask`); nil = none picked (the effect does nothing).
    /// Stored only when set ("maskTrack").
    public var maskTrack: Track.ID?

    public init(id: UUID = UUID(), kind: String, enabled: Bool = true,
                parameters: [String: AnimatedProperty<Double>] = [:],
                colors: [String: AnimatedProperty<EffectColor>] = [:],
                points: [String: AnimatedProperty<Vec2>] = [:], grade: ColorGradeData? = nil) {
        self.id = id; self.kind = kind; self.enabled = enabled; self.parameters = parameters
        self.colors = colors; self.points = points; self.grade = grade
    }

    private enum CodingKeys: String, CodingKey { case id, kind, enabled, parameters, colors, points, grade, colorRange, colorFadeIn, colorFadeOut
        case maskInput = "masks", colorGraph, maskTrack }

    /// `colors` / `points` are optional on decode (absent before v24) and only written when not empty; `grade` (v27)
    /// only when set.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), kind: try c.decode(String.self, forKey: .kind),
                  enabled: try c.decode(Bool.self, forKey: .enabled),
                  parameters: try c.decode([String: AnimatedProperty<Double>].self, forKey: .parameters),
                  colors: try c.decodeIfPresent([String: AnimatedProperty<EffectColor>].self, forKey: .colors) ?? [:],
                  points: try c.decodeIfPresent([String: AnimatedProperty<Vec2>].self, forKey: .points) ?? [:],
                  grade: try c.decodeIfPresent(ColorGradeData.self, forKey: .grade))
        colorRange = try c.decodeIfPresent(TimeRange.self, forKey: .colorRange)
        colorFadeIn = try c.decodeIfPresent(Time.self, forKey: .colorFadeIn)
        colorFadeOut = try c.decodeIfPresent(Time.self, forKey: .colorFadeOut)
        maskInput = try c.decodeIfPresent([UUID].self, forKey: .maskInput) ?? []
        colorGraph = try c.decodeIfPresent(ColorGraph.self, forKey: .colorGraph)
        maskTrack = try c.decodeIfPresent(Track.ID.self, forKey: .maskTrack)
        // A Color effect stored before the Basic Correction maths flag: pin the model it is read with now, so a later
        // slider move (from any panel) cannot flip an untouched effect back to the legacy maths.
        if kind == Self.colorKind, parameters[Self.colorBasicModelKey] == nil {
            parameters[Self.colorBasicModelKey] = AnimatedProperty(Double(basicToneModel.rawValue))
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(enabled, forKey: .enabled)
        try c.encode(parameters, forKey: .parameters)
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
        if !points.isEmpty { try c.encode(points, forKey: .points) }
        try c.encodeIfPresent(grade, forKey: .grade)
        try c.encodeIfPresent(colorRange, forKey: .colorRange)
        try c.encodeIfPresent(colorFadeIn, forKey: .colorFadeIn)
        try c.encodeIfPresent(colorFadeOut, forKey: .colorFadeOut)
        if !maskInput.isEmpty { try c.encode(maskInput, forKey: .maskInput) }
        try c.encodeIfPresent(colorGraph, forKey: .colorGraph)
        try c.encodeIfPresent(maskTrack, forKey: .maskTrack)
    }

    /// Radius in sequence pixels of the clip's own frame; 0 = square.
    public static func roundedCorners(radius: Double = 24) -> ClipEffect {
        ClipEffect(kind: roundedCornersKind, parameters: [radiusKey: AnimatedProperty(radius)])
    }

    /// Slider, checkbox and choice values an effect starts with (what "Reset" restores).
    public static func defaultParameters(for kind: String) -> [String: AnimatedProperty<Double>] {
        var out: [String: AnimatedProperty<Double>] = [:]
        let spec = EffectCatalog.spec(for: kind)
        let linkedY = Set((spec?.pairs ?? []).filter(\.linkable).map(\.y))      // stored only while unlinked
        for p in spec?.params ?? [] where p.kind.isScalar && !linkedY.contains(p.key) { out[p.key] = AnimatedProperty(p.defaultValue) }
        if kind == colorKind { out[colorBasicModelKey] = AnimatedProperty(Double(BasicToneModel.current.rawValue)) }
        if kind == lensDistortionKind { out[lensModelKey] = AnimatedProperty(1) }
        return out
    }

    /// Color values an effect starts with.
    public static func defaultColors(for kind: String) -> [String: AnimatedProperty<EffectColor>] {
        var out: [String: AnimatedProperty<EffectColor>] = [:]
        for p in EffectCatalog.spec(for: kind)?.params ?? [] { if case .color(let c) = p.kind { out[p.key] = AnimatedProperty(c) } }
        return out
    }

    /// Point values an effect starts with.
    public static func defaultPoints(for kind: String) -> [String: AnimatedProperty<Vec2>] {
        var out: [String: AnimatedProperty<Vec2>] = [:]
        for p in EffectCatalog.spec(for: kind)?.params ?? [] { if case .point(let v) = p.kind { out[p.key] = AnimatedProperty(v) } }
        return out
    }

    /// Values a kind gets when the user applies it to a clip (`Clip.addEffect`), where they differ from the stored default:
    /// Blur, Sharpen and Spherize would show nothing at 0, Stereo Width at 150 % changes the sound on drop (AUDIT A10, G13).
    /// Only NEW instances use them: `defaultParameters` (Reset, stored files, internal effects) is unchanged, so existing
    /// projects render identically.
    public static let appliedStartValues: [String: [String: Double]] = [
        gaussianBlurKind: [blurrinessKey: 20],
        sharpenKind: [sharpenAmountKey: 50],
        spherizeKind: [spherizeRadiusKey: 400],
        audioStereoWidthKind: [stereoWidthKey: 100],
    ]

    /// A new instance of `kind` with its default values; nil for an unknown kind.
    public static func make(kind: String) -> ClipEffect? {
        EffectCatalog.spec(for: kind) == nil ? nil
            : ClipEffect(kind: kind, parameters: defaultParameters(for: kind), colors: defaultColors(for: kind),
                         points: defaultPoints(for: kind))
    }

    /// Clip-local times of every key of every parameter.
    public var keyTimes: [Time] {
        parameters.values.flatMap { $0.track.keys.map(\.time) } + colors.values.flatMap { $0.track.keys.map(\.time) }
            + points.values.flatMap { $0.track.keys.map(\.time) }
    }

    func remapped(_ f: (Time) -> Time) -> ClipEffect {
        var e = self
        e.parameters = parameters.mapValues { $0.remapped(f) }
        e.colors = colors.mapValues { $0.remapped(f) }
        e.points = points.mapValues { $0.remapped(f) }
        e.colorRange = colorRange.map { r in
            let a = f(r.start), b = f(r.end)
            return TimeRange(start: min(a, b), end: max(a, b))
        }
        if let r = colorRange {
            // A fade is a duration: its retimed length is the distance between its mapped ends.
            func dist(_ a: Time, _ b: Time) -> Time { a < b ? b - a : a - b }
            e.colorFadeIn = colorFadeIn.map { dist(f(r.start + $0), f(r.start)) }
            e.colorFadeOut = colorFadeOut.map { dist(f(r.end), f(r.end - $0)) }
        }
        return e
    }

    public func shifted(by delta: Time) -> ClipEffect {
        var e = self
        e.parameters = parameters.mapValues { $0.shifted(by: delta) }
        e.colors = colors.mapValues { $0.shifted(by: delta) }
        e.points = points.mapValues { $0.shifted(by: delta) }
        e.colorRange = colorRange.map { TimeRange(start: $0.start + delta, duration: $0.duration) }
        return e
    }

    /// Every parameter frozen at clip-local `t` (no keys): what a frame hold keeps.
    func frozen(atLocal t: Time) -> ClipEffect {
        var e = self
        e.parameters = parameters.mapValues { AnimatedProperty($0.value(atLocal: t)) }
        e.colors = colors.mapValues { AnimatedProperty($0.value(atLocal: t)) }
        e.points = points.mapValues { AnimatedProperty($0.value(atLocal: t)) }
        return e
    }
}

/// A keyframable RGBA color of an effect parameter: display-encoded (as picked in the color well) 0...1 channels.
public struct EffectColor: Sendable, Hashable, Codable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let black = EffectColor(red: 0, green: 0, blue: 0)
    public static let white = EffectColor(red: 1, green: 1, blue: 1)
    /// Every channel inside 0...1.
    public var clamped: EffectColor {
        func c(_ v: Double) -> Double { min(max(v, 0), 1) }
        return EffectColor(red: c(red), green: c(green), blue: c(blue), alpha: c(alpha))
    }
    public var rgb: SIMD3<Double> { SIMD3(red, green, blue) }
}

extension EffectColor: KeyframeValue {
    public static func lerp(_ a: EffectColor, _ b: EffectColor, _ t: Double) -> EffectColor { a + (b - a) * t }
    public static func + (a: EffectColor, b: EffectColor) -> EffectColor {
        EffectColor(red: a.red + b.red, green: a.green + b.green, blue: a.blue + b.blue, alpha: a.alpha + b.alpha)
    }
    public static func - (a: EffectColor, b: EffectColor) -> EffectColor {
        EffectColor(red: a.red - b.red, green: a.green - b.green, blue: a.blue - b.blue, alpha: a.alpha - b.alpha)
    }
    public static func * (a: EffectColor, k: Double) -> EffectColor {
        EffectColor(red: a.red * k, green: a.green * k, blue: a.blue * k, alpha: a.alpha * k)
    }
    public var speedMagnitude: Double { (red * red + green * green + blue * blue + alpha * alpha).squareRoot() }
}

extension Clip {
    public func effect(ofKind kind: String) -> ClipEffect? { effects.first { $0.kind == kind } }

    /// The Rounded Corners effect when applied. Setting nil removes it, a value replaces or appends it.
    public var roundedCorners: ClipEffect? {
        get { effect(ofKind: ClipEffect.roundedCornersKind) }
        set {
            let i = effects.firstIndex { $0.kind == ClipEffect.roundedCornersKind }
            switch (i, newValue) {
            case (let i?, let n?): effects[i] = n
            case (let i?, nil): effects.remove(at: i)
            case (nil, let n?): effects.append(n)
            case (nil, nil): break
            }
        }
    }
}
