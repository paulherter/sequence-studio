import Foundation

// v27: the color grade lives in `Clip.effects` as effects of kind `color` (Premiere: Lumetri Color). Every number of a
// `ColorEffect` is a keyframable scalar parameter (W1.5 types: sliders and section checkboxes), so Effect Controls shows and
// keys them like any other effect. What is not a number (LUT references, curve points, the HSL Secondary range and its
// on / off toggle) sits in `ClipEffect.grade`. `Clip.color` stays as the view the Color inspector and the renderer work with.

/// The non-scalar part of a Color effect: LUT references and curves (not keyframable).
public struct ColorGradeData: Sendable, Hashable, Codable {
    /// Input LUT inside Basic Correction (see `ColorEffect.inputLUT`). nil = none; `.automatic` = the media's camera LUT.
    public var inputLUT: LUTRef?
    /// Creative look LUT; nil = none.
    public var look: LUTRef?
    public var curves: RGBCurves
    public var hueCurves: HueCurves
    /// The Color Range section's toggle (stored here: the section has no scalar parameters).
    public var hslSecondaryOff: Bool
    /// Color Range qualifier and correction (v48); nil = none.
    public var hslSecondary: HSLSecondary? = nil
    /// The Zone Board's toggle (v94).
    public var zoneBoardOff = false
    /// Zone Board (v94); nil = none.
    public var zoneBoard: ZoneBoard? = nil
    /// FB-B3 Color Match reference (v43); nil = none set.
    public var match: ColorMatchReference? = nil

    public init(inputLUT: LUTRef? = .automatic, look: LUTRef? = nil, curves: RGBCurves = RGBCurves(),
                hueCurves: HueCurves = HueCurves(), hslSecondaryOff: Bool = false) {
        self.inputLUT = inputLUT; self.look = look; self.curves = curves; self.hueCurves = hueCurves
        self.hslSecondaryOff = hslSecondaryOff
    }

    public static let `default` = ColorGradeData()

    private enum CodingKeys: String, CodingKey { case inputLUT, look, curves, hueCurves, hslSecondaryOff, hslSecondary, zoneBoardOff, zoneBoard, match }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // Absent = automatic (the default of a first effect); an explicit "none" is JSON null.
        inputLUT = c.contains(.inputLUT) ? try c.decodeIfPresent(LUTRef.self, forKey: .inputLUT) : .automatic
        look = try c.decodeIfPresent(LUTRef.self, forKey: .look)
        curves = try c.decodeIfPresent(RGBCurves.self, forKey: .curves) ?? RGBCurves()
        hueCurves = try c.decodeIfPresent(HueCurves.self, forKey: .hueCurves) ?? HueCurves()
        hslSecondaryOff = try c.decodeIfPresent(Bool.self, forKey: .hslSecondaryOff) ?? false
        hslSecondary = try c.decodeIfPresent(HSLSecondary.self, forKey: .hslSecondary)
        zoneBoardOff = try c.decodeIfPresent(Bool.self, forKey: .zoneBoardOff) ?? false
        zoneBoard = try c.decodeIfPresent(ZoneBoard.self, forKey: .zoneBoard)
        match = try? c.decodeIfPresent(ColorMatchReference.self, forKey: .match)   // a malformed reference is dropped
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(inputLUT, forKey: .inputLUT)   // nil encodes as null = "none"
        try c.encodeIfPresent(look, forKey: .look)
        if !curves.isNeutral { try c.encode(curves, forKey: .curves) }
        if hueCurves != HueCurves() { try c.encode(hueCurves, forKey: .hueCurves) }
        if hslSecondaryOff { try c.encode(true, forKey: .hslSecondaryOff) }
        try c.encodeIfPresent(hslSecondary, forKey: .hslSecondary)
        if zoneBoardOff { try c.encode(true, forKey: .zoneBoardOff) }
        try c.encodeIfPresent(zoneBoard, forKey: .zoneBoard)
        try c.encodeIfPresent(match, forKey: .match)
    }
}

extension ClipEffect {
    /// Kind of a Color effect (stored string: never rename).
    public static let colorKind = "color"

    // Parameter keys (stored strings: never rename).
    public static let colorBasicOnKey = "basicCorrectionOn", colorCreativeOnKey = "creativeOn", colorCurvesOnKey = "curvesOn"
    public static let colorWheelsOnKey = "wheelsOn", colorVignetteOnKey = "vignetteOn"
    public static let colorTemperatureKey = "temperature", colorTintKey = "tint", colorExposureKey = "exposure"
    public static let colorContrastKey = "contrast", colorHighlightsKey = "highlights", colorShadowsKey = "shadows"
    public static let colorWhitesKey = "whites", colorBlacksKey = "blacks", colorSaturationKey = "saturation"
    public static let colorVibranceKey = "vibrance", colorInputLUTIntensityKey = "inputLUTIntensity"
    public static let colorLookIntensityKey = "lookIntensity", colorFadedFilmKey = "fadedFilm"
    public static let colorCreativeVibranceKey = "creativeVibrance", colorCreativeSaturationKey = "creativeSaturation"
    public static let colorShadowTintHueKey = "shadowTintHue", colorShadowTintAmountKey = "shadowTintAmount"
    public static let colorHighlightTintHueKey = "highlightTintHue", colorHighlightTintAmountKey = "highlightTintAmount"
    public static let colorTintBalanceKey = "tintBalance"
    public static let colorWheelShadowsHueKey = "wheelShadowsHue", colorWheelShadowsAmountKey = "wheelShadowsAmount"
    public static let colorWheelShadowsLumaKey = "wheelShadowsLuma"
    public static let colorWheelMidtonesHueKey = "wheelMidtonesHue", colorWheelMidtonesAmountKey = "wheelMidtonesAmount"
    public static let colorWheelMidtonesLumaKey = "wheelMidtonesLuma"
    public static let colorWheelHighlightsHueKey = "wheelHighlightsHue", colorWheelHighlightsAmountKey = "wheelHighlightsAmount"
    public static let colorWheelHighlightsLumaKey = "wheelHighlightsLuma"
    public static let colorWheelSaturationKey = "wheelSaturation"
    public static let colorVignetteAmountKey = "vignetteAmount", colorVignetteMidpointKey = "vignetteMidpoint"
    public static let colorVignetteRoundnessKey = "vignetteRoundness", colorVignetteFeatherKey = "vignetteFeather"
    /// Hidden parameter (not in the spec, never keyed): the Basic Correction maths, `BasicToneModel.rawValue`. Absent =
    /// the effect predates the Lumetri maths (`.legacy`), unless its Basic Correction sliders were never moved.
    public static let colorBasicModelKey = "basicModel"
}

/// One number of a `ColorEffect` as an effect parameter.
struct ColorScalarField: @unchecked Sendable {   // key paths into a value type, never mutated
    let key: String
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    let decimals: Int
    let path: WritableKeyPath<ColorEffect, Float>

    /// Degrees round the color circle (the only degree values of the Color effect).
    var isHue: Bool { unit == ColorGradeFields.degree }

    var spec: EffectParamSpec {
        let def = Double(ColorEffect(id: 1)[keyPath: path])
        return EffectParamSpec(key: key, title: title, unit: unit, defaultValue: def, range: range,
                               step: decimals >= 2 ? 0.01 : 0.1, decimals: decimals, isHue: isHue)
    }
}

/// A color wheel of the Color effect (Look tints, Color Wheels): its hue and amount are one puck on the disc.
struct ColorPuckField: @unchecked Sendable {   // key path into a value type, never mutated
    let hueKey: String
    let amountKey: String
    let path: WritableKeyPath<ColorEffect, WheelValue>
}

/// A section toggle of a `ColorEffect` as a checkbox parameter.
struct ColorToggleField: Sendable {
    let key: String
    let section: ColorSectionKind
}

enum ColorGradeFields {
    typealias K = ClipEffect
    static let hundred: ClosedRange<Double> = -100...100
    static let degree = "\u{00B0}"

    static func f(_ key: String, _ title: String, _ path: WritableKeyPath<ColorEffect, Float>,
                  _ range: ClosedRange<Double> = hundred, unit: String = "", decimals: Int = 1) -> ColorScalarField {
        ColorScalarField(key: key, title: title, unit: unit, range: range, decimals: decimals, path: path)
    }

    static let basic: [ColorScalarField] = [
        f(K.colorTemperatureKey, "Temperature", \.basic.temperature),
        f(K.colorTintKey, "Tint", \.basic.tint),
        f(K.colorSaturationKey, "Saturation", \.basic.saturation, 0...200),
        f(K.colorExposureKey, "Exposure", \.basic.exposure, -5...5, decimals: 2),
        f(K.colorContrastKey, "Contrast", \.basic.contrast),
        f(K.colorHighlightsKey, "Highlights", \.basic.highlights),
        f(K.colorShadowsKey, "Shadows", \.basic.shadows),
        f(K.colorWhitesKey, "Whites", \.basic.whites),
        f(K.colorBlacksKey, "Blacks", \.basic.blacks),
        f(K.colorVibranceKey, "Vibrance", \.basic.vibrance),
        f(K.colorInputLUTIntensityKey, "Source LUT Intensity", \.inputLUTIntensity, 0...100),
    ]
    static let creative: [ColorScalarField] = [
        f(K.colorLookIntensityKey, "Look Intensity", \.creative.intensity, 0...100),
        f(K.colorFadedFilmKey, "Fade", \.creative.fadedFilm, 0...100),
        f(K.colorCreativeVibranceKey, "Look Vibrance", \.creative.vibrance),
        f(K.colorCreativeSaturationKey, "Look Saturation", \.creative.saturation, 0...200),
        f(K.colorShadowTintHueKey, "Shadow Tint Hue", \.creative.shadowTint.hue, 0...360, unit: degree),
        f(K.colorShadowTintAmountKey, "Shadow Tint Amount", \.creative.shadowTint.amount, 0...1, decimals: 2),
        f(K.colorHighlightTintHueKey, "Highlight Tint Hue", \.creative.highlightTint.hue, 0...360, unit: degree),
        f(K.colorHighlightTintAmountKey, "Highlight Tint Amount", \.creative.highlightTint.amount, 0...1, decimals: 2),
        f(K.colorTintBalanceKey, "Tint Balance", \.creative.tintBalance),
    ]
    static let wheels: [ColorScalarField] = [
        f(K.colorWheelShadowsHueKey, "Shadows Hue", \.wheels.shadows.hue, 0...360, unit: degree),
        f(K.colorWheelShadowsAmountKey, "Shadows Amount", \.wheels.shadows.amount, 0...1, decimals: 2),
        f(K.colorWheelShadowsLumaKey, "Shadows Luma", \.wheels.shadowsLuma),
        f(K.colorWheelMidtonesHueKey, "Midtones Hue", \.wheels.midtones.hue, 0...360, unit: degree),
        f(K.colorWheelMidtonesAmountKey, "Midtones Amount", \.wheels.midtones.amount, 0...1, decimals: 2),
        f(K.colorWheelMidtonesLumaKey, "Midtones Luma", \.wheels.midtonesLuma),
        f(K.colorWheelHighlightsHueKey, "Highlights Hue", \.wheels.highlights.hue, 0...360, unit: degree),
        f(K.colorWheelHighlightsAmountKey, "Highlights Amount", \.wheels.highlights.amount, 0...1, decimals: 2),
        f(K.colorWheelHighlightsLumaKey, "Highlights Luma", \.wheels.highlightsLuma),
        f(K.colorWheelSaturationKey, "Wheels Saturation", \.wheels.saturation, 0...200),
    ]
    static let vignette: [ColorScalarField] = [
        f(K.colorVignetteAmountKey, "Vignette Amount", \.vignette.amount, -5...5, decimals: 2),
        f(K.colorVignetteMidpointKey, "Vignette Midpoint", \.vignette.midpoint, 0...100),
        f(K.colorVignetteRoundnessKey, "Vignette Roundness", \.vignette.roundness),
        f(K.colorVignetteFeatherKey, "Vignette Feather", \.vignette.feather, 0...100),
    ]
    static let scalars: [ColorScalarField] = basic + creative + wheels + vignette

    static let pucks: [ColorPuckField] = [
        ColorPuckField(hueKey: K.colorShadowTintHueKey, amountKey: K.colorShadowTintAmountKey, path: \.creative.shadowTint),
        ColorPuckField(hueKey: K.colorHighlightTintHueKey, amountKey: K.colorHighlightTintAmountKey,
                       path: \.creative.highlightTint),
        ColorPuckField(hueKey: K.colorWheelShadowsHueKey, amountKey: K.colorWheelShadowsAmountKey, path: \.wheels.shadows),
        ColorPuckField(hueKey: K.colorWheelMidtonesHueKey, amountKey: K.colorWheelMidtonesAmountKey, path: \.wheels.midtones),
        ColorPuckField(hueKey: K.colorWheelHighlightsHueKey, amountKey: K.colorWheelHighlightsAmountKey,
                       path: \.wheels.highlights),
    ]

    static let toggles: [ColorToggleField] = [
        ColorToggleField(key: K.colorBasicOnKey, section: .basicCorrection),
        ColorToggleField(key: K.colorCreativeOnKey, section: .creative),
        ColorToggleField(key: K.colorCurvesOnKey, section: .curves),
        ColorToggleField(key: K.colorWheelsOnKey, section: .wheels),
        ColorToggleField(key: K.colorVignetteOnKey, section: .vignette),
    ]

    /// Effect Controls rows: each section's toggle, then its numbers (Lumetri order).
    static let params: [EffectParamSpec] = {
        func toggle(_ k: String, _ title: String) -> EffectParamSpec { .checkbox(k, title, on: true) }
        return [toggle(K.colorBasicOnKey, "Basic")] + basic.map(\.spec)
            + [toggle(K.colorCreativeOnKey, "Creative")] + creative.map(\.spec)
            + [toggle(K.colorCurvesOnKey, "Curves")]
            + [toggle(K.colorWheelsOnKey, "Wheels & Match")] + wheels.map(\.spec)
            + [toggle(K.colorVignetteOnKey, "Vignette")] + vignette.map(\.spec)
    }()

    static let spec = EffectSpec(kind: ClipEffect.colorKind, title: "Color", params: params)
}

/// How Effect Controls groups the parameters of a Color effect like the Color page: one group per switch
/// (Basic Correction, Creative, Curves, Color Wheels, Vignette), the switch first, then its numbers.
public enum ColorEffectGroups {
    /// Switch keys in display order; each starts a group.
    public static var toggleKeys: [String] { ColorGradeFields.toggles.map(\.key) }
    public static func isGroupToggle(_ key: String) -> Bool { ColorGradeFields.toggles.contains { $0.key == key } }
    /// The switch key of the group `key` belongs to (a switch is its own group's key).
    public static func groupKey(of key: String) -> String? {
        var current: String?
        for p in ColorGradeFields.params {
            if isGroupToggle(p.key) { current = p.key }
            if p.key == key { return current }
        }
        return nil
    }
    /// Groups that open on a freshly shown Color effect.
    public static let openByDefault: Set<String> = [ClipEffect.colorBasicOnKey]
}

extension ClipEffect {
    public var isColor: Bool { kind == Self.colorKind }

    /// The grade data of a Color effect (defaults when not stored).
    public var colorData: ColorGradeData { grade ?? .default }

    /// This Color effect moved onto a clip of `media` (paste, preset). A LUT embedded in other media does not exist
    /// there: the conversion slot of the first (`primary`) effect falls back to automatic, anything else to none.
    /// `.automatic` means something only in the first effect, so a later one gets none. File LUTs travel unchanged.
    func adaptingLUTs(toMedia media: UUID, primary: Bool) -> ClipEffect {
        guard isColor else { return self }
        var d = colorData
        if case .embedded(let m)? = d.inputLUT, m != media { d.inputLUT = primary ? .automatic : nil }
        if d.inputLUT == .automatic, !primary { d.inputLUT = nil }
        if case .embedded(let m)? = d.look, m != media { d.look = nil }
        var e = self
        e.grade = d
        return e
    }

    /// A static Color effect holding `e` (fresh id; `e.id` is not stored, the position in the clip gives it).
    public static func colorGrade(_ e: ColorEffect) -> ClipEffect {
        var fx = ClipEffect(kind: colorKind, parameters: defaultParameters(for: colorKind))
        fx.grade = ColorGradeData()
        fx.setColorEffect(e, atLocal: nil)
        return fx
    }

    /// The Color effect's values at clip-local `t` (nil = the static values), as the stored numbers (not clamped,
    /// so a migrated grade renders exactly as before). `id` is the inspector's index (1-based) of this effect.
    public func colorEffect(atLocal t: Time?, id: Int) -> ColorEffect {
        let d = colorData
        var e = ColorEffect(id: id, inputLUT: d.inputLUT)
        func raw(_ key: String) -> Double? {
            guard let p = parameters[key] else { return nil }
            return t.map { p.value(atLocal: $0) } ?? p.value
        }
        for f in ColorGradeFields.scalars {
            if let t, f.isHue, let p = parameters[f.key] { e[keyPath: f.path] = Float(p.hueValue(atLocal: t)) }
            else if let v = raw(f.key) { e[keyPath: f.path] = Float(v) }
        }
        if let t {
            for pk in ColorGradeFields.pucks {
                if let (h, a) = puckValue(pk, atLocal: t) { e[keyPath: pk.path] = WheelValue(hue: Float(h), amount: Float(a)) }
            }
        }
        for tg in ColorGradeFields.toggles { if let v = raw(tg.key) { e.setEnabled(tg.section, v >= 0.5) } }
        e.basic.model = basicToneModel
        e.setEnabled(.hslSecondary, !d.hslSecondaryOff)
        e.creative.look = d.look
        e.curves = d.curves
        e.hueCurves = d.hueCurves
        e.hslSecondary = d.hslSecondary
        e.setEnabled(.zoneBoard, !d.zoneBoardOff)
        e.zoneBoard = d.zoneBoard
        return e
    }

    /// The Basic Correction maths of this Color effect (see `colorBasicModelKey`).
    public var basicToneModel: BasicToneModel {
        if let v = parameters[Self.colorBasicModelKey]?.value {
            return BasicToneModel(rawValue: Int(v.rounded())) ?? .current
        }
        // Stored before the model existed: legacy, unless every Basic slider is static at its default.
        let untouched = ColorGradeFields.basic.allSatisfy { f in
            guard let p = parameters[f.key] else { return true }
            return !p.isAnimated && Float(p.value) == Float(f.spec.defaultValue)
        }
        return untouched ? .current : .legacy
    }

    /// Writes `e` into this Color effect. Only values that differ from what is shown at `t` change: a keyframed
    /// parameter gets a key at `t` (an existing key there keeps its interpolation), an unkeyed one its static value.
    /// Without `t` keyed parameters change their static value only. LUTs and curves are not keyframable.
    public mutating func setColorEffect(_ e: ColorEffect, atLocal t: Time?) {
        let before = self
        func write(_ key: String, _ v: Double, stepped: Bool) {
            var p = parameters[key] ?? AnimatedProperty(v)
            let shown = t.flatMap { before.colorShownValue(key, atLocal: $0) } ?? (t.map { p.value(atLocal: $0) } ?? p.value)
            guard parameters[key] == nil || Float(shown) != Float(v) else { return }
            if let t, p.isAnimated {
                if let k = p.track.keys.first(where: { $0.time == t }) { p.track.set(k.id, value: v) }
                else { p.track.insert(Keyframe(time: t, value: v, interpolation: stepped ? .hold : .linear)) }
            } else {
                p.value = v
            }
            parameters[key] = p
        }
        for f in ColorGradeFields.scalars { write(f.key, Double(e[keyPath: f.path]), stepped: false) }
        for tg in ColorGradeFields.toggles { write(tg.key, e.isEnabled(tg.section) ? 1 : 0, stepped: true) }
        if let t { keyWheelPartners(atLocal: t, before: before) }
        if parameters[Self.colorBasicModelKey] == nil || basicToneModel != e.basic.model {
            parameters[Self.colorBasicModelKey] = AnimatedProperty(Double(e.basic.model.rawValue))
        }
        var d = colorData
        d.inputLUT = e.inputLUT
        d.look = e.creative.look
        d.curves = e.curves
        d.hueCurves = e.hueCurves
        d.hslSecondaryOff = !e.isEnabled(.hslSecondary)
        d.hslSecondary = e.hslSecondary
        d.zoneBoardOff = !e.isEnabled(.zoneBoard)
        d.zoneBoard = e.zoneBoard
        grade = d
    }

    /// Writes only what an edit changed (`base` = the values the editor showed, `e` = after the edit). A keyframed
    /// parameter gets a key at `t`; without `t` such an edit is refused (false, nothing changes). Values the edit did not
    /// touch are never written, so a stale `base` cannot key the other parameters.
    public mutating func applyColorEdit(from base: ColorEffect, to e: ColorEffect, atLocal t: Time?) -> Bool {
        var out = self
        func write(_ key: String, _ v: Double, stepped: Bool) -> Bool {
            var p = out.parameters[key] ?? AnimatedProperty(v)
            if p.isAnimated {
                guard let t else { return false }
                if let k = p.track.keys.first(where: { $0.time == t }) { p.track.set(k.id, value: v) }
                else { p.track.insert(Keyframe(time: t, value: v, interpolation: stepped ? .hold : .linear)) }
            } else {
                p.value = v
            }
            out.parameters[key] = p
            return true
        }
        for f in ColorGradeFields.scalars where base[keyPath: f.path] != e[keyPath: f.path] {
            guard write(f.key, Double(e[keyPath: f.path]), stepped: false) else { return false }
        }
        for tg in ColorGradeFields.toggles where base.isEnabled(tg.section) != e.isEnabled(tg.section) {
            guard write(tg.key, e.isEnabled(tg.section) ? 1 : 0, stepped: true) else { return false }
        }
        if let t { out.keyWheelPartners(atLocal: t, before: self) }
        // The maths flag follows the edit (e.g. a Reset) and pins down an implicit model before the sliders move away
        // from the defaults it was inferred from.
        if base.basic.model != e.basic.model || out.parameters[Self.colorBasicModelKey] == nil {
            out.parameters[Self.colorBasicModelKey] = AnimatedProperty(Double(e.basic.model.rawValue))
        }
        var d = out.colorData
        if base.inputLUT != e.inputLUT { d.inputLUT = e.inputLUT }
        if base.creative.look != e.creative.look { d.look = e.creative.look }
        if base.curves != e.curves { d.curves = e.curves }
        if base.hueCurves != e.hueCurves { d.hueCurves = e.hueCurves }
        if base.isEnabled(.hslSecondary) != e.isEnabled(.hslSecondary) { d.hslSecondaryOff = !e.isEnabled(.hslSecondary) }
        if base.hslSecondary != e.hslSecondary { d.hslSecondary = e.hslSecondary }
        if base.isEnabled(.zoneBoard) != e.isEnabled(.zoneBoard) { d.zoneBoardOff = !e.isEnabled(.zoneBoard) }
        if base.zoneBoard != e.zoneBoard { d.zoneBoard = e.zoneBoard }
        if d != out.colorData { out.grade = d }
        self = out
        return true
    }
}

/// The footage interpretation of a clip (Interpret Footage): stored under the clip's `color` key since v27.
public struct ClipFootageColor: Sendable, Hashable, Codable {
    /// nil = from media (`MediaInfo.colorSpace`).
    public var source: SourceColorOverride?
    /// Per-clip toggle for the embedded camera LUT (used by an `.automatic` Input LUT).
    public var useEmbeddedLUT: Bool
    /// How a log source is converted (v93; default camera LUT).
    public var logMode: LogMode
    /// The space the conversion delivers (v93; default Rec.709).
    public var targetSpace: TargetSpace
    /// Automatic HDR/SDR conform before the grade (v93; default on).
    public var hdrConform: Bool
    public init(source: SourceColorOverride? = nil, useEmbeddedLUT: Bool = true,
                logMode: LogMode = .cameraLUT, targetSpace: TargetSpace = .rec709, hdrConform: Bool = true) {
        self.source = source; self.useEmbeddedLUT = useEmbeddedLUT
        self.logMode = logMode; self.targetSpace = targetSpace; self.hdrConform = hdrConform
    }
    /// The footage part of an edited grade.
    public init(_ c: ClipColor) {
        self.init(source: c.source, useEmbeddedLUT: c.useEmbeddedLUT, logMode: c.logMode,
                  targetSpace: c.targetSpace, hdrConform: c.hdrConform)
    }
    /// True when a v93 field differs from its default (the file then needs v93).
    var hasV93Content: Bool { logMode != .cameraLUT || targetSpace != .rec709 || !hdrConform }
    private enum CodingKeys: String, CodingKey { case source, useEmbeddedLUT, logMode, targetSpace, hdrConform }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(ColorSpaceID.self, forKey: .source)
        useEmbeddedLUT = try c.decodeIfPresent(Bool.self, forKey: .useEmbeddedLUT) ?? true
        logMode = try c.decodeIfPresent(LogMode.self, forKey: .logMode) ?? .cameraLUT
        targetSpace = try c.decodeIfPresent(TargetSpace.self, forKey: .targetSpace) ?? .rec709
        hdrConform = try c.decodeIfPresent(Bool.self, forKey: .hdrConform) ?? true
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(useEmbeddedLUT, forKey: .useEmbeddedLUT)
        if logMode != .cameraLUT { try c.encode(logMode, forKey: .logMode) }
        if targetSpace != .rec709 { try c.encode(targetSpace, forKey: .targetSpace) }
        if !hdrConform { try c.encode(false, forKey: .hdrConform) }
    }
}

extension Clip {
    /// Indices of the Color effects in `effects`, in list order.
    var colorEffectIndices: [Int] { effects.indices.filter { effects[$0].isColor } }

    /// The clip's color as the Color inspector edits it: the footage interpretation plus every Color effect (static
    /// values; ids 1, 2, ... in list order). No Color effect = the neutral default. Setting it maps by id: ids that exist
    /// update their effect, new ids append Color effects (behind the last one, or in front of the list), missing ids
    /// remove theirs. A neutral default grade on a clip without Color effects adds none.
    public var color: ClipColor {
        get { color(at: nil) }
        set { setColor(newValue, at: nil) }
    }

    /// The color shown at clip-local `t` (keyframed values evaluated there).
    public func color(atLocal t: Time) -> ClipColor { color(at: t) }

    /// Writes a grade edited at clip-local `t`: keyframed values get a key at `t`.
    public mutating func setColor(_ c: ClipColor, atLocal t: Time) { setColor(c, at: t) }

    private func color(at t: Time?) -> ClipColor {
        let fx = colorEffectIndices.enumerated().map { effects[$0.element].colorEffect(atLocal: t, id: $0.offset + 1) }
        return ClipColor(footage: footageColor, effects: fx)
    }

    private mutating func setColor(_ c: ClipColor, at t: Time?) {
        footageColor = ClipFootageColor(c)
        let existing = colorEffectIndices
        if existing.isEmpty && c.effects == ClipColor.defaultEffects { return }
        let ids = existing.map { effects[$0].id }
        // Update or remove the existing ones (by inspector id = position + 1).
        for (n, fxID) in ids.enumerated() {
            if let e = c.effect(n + 1) {
                if let i = effects.firstIndex(where: { $0.id == fxID }) { effects[i].setColorEffect(e, atLocal: t) }
            } else {
                removeEffect(fxID)
            }
        }
        // Append new ones behind the last Color effect (or in front of the list).
        let added = c.effects.filter { $0.id > ids.count }
        guard !added.isEmpty, acceptsColor else { return }
        var at = (colorEffectIndices.last.map { $0 + 1 }) ?? 0
        for e in added {
            effects.insert(ClipEffect.colorGrade(e), at: at)
            at += 1
        }
    }

    /// Writes an inspector edit: `base` is the grade the inspector showed, `c` the grade after the edit. Only what
    /// changed between the two is written (keyed values get a key at `t`), so values loaded at an earlier playhead are
    /// never written back. Effects the edit added or removed are added or removed. False (and nothing changes) when the
    /// edit touches a keyed value and `t` is nil (the playhead is outside the clip).
    @discardableResult
    public mutating func setColor(_ c: ClipColor, editedFrom base: ClipColor, atLocal t: Time?) -> Bool {
        var out = self
        if ClipFootageColor(c) != ClipFootageColor(base) {
            out.footageColor = ClipFootageColor(c)
        }
        let ids = out.colorEffectIndices.map { out.effects[$0].id }
        for (n, fxID) in ids.enumerated() {
            guard let i = out.effects.firstIndex(where: { $0.id == fxID }) else { continue }
            switch (c.effect(n + 1), base.effect(n + 1)) {
            case let (e?, b?): guard out.effects[i].applyColorEdit(from: b, to: e, atLocal: t) else { return false }
            case let (e?, nil): out.effects[i].setColorEffect(e, atLocal: t)
            case (nil, _?): out.removeEffect(fxID)
            case (nil, nil): break
            }
        }
        // Without Color effects the clip shows the neutral default as effect 1: an edit creates every shown effect.
        let added = ids.isEmpty ? (c.effects == ClipColor.defaultEffects ? [] : c.effects)
                                : c.effects.filter { $0.id > ids.count && base.effect($0.id) == nil }
        if !added.isEmpty, out.acceptsColor {
            var at = (out.colorEffectIndices.last.map { $0 + 1 }) ?? 0
            for e in added { out.effects.insert(ClipEffect.colorGrade(e), at: at); at += 1 }
        }
        self = out
        return true
    }

    /// Clip-local time an inspector edit at `playhead` keys at: on the clip's frames (the last one at most), nil when
    /// the playhead is not over the clip.
    public func colorEditTime(atPlayhead playhead: Time, frameDuration: Time) -> Time? {
        guard playhead >= start, playhead < start + duration else { return nil }
        let last = max(duration - frameDuration, .zero)
        return min(max(playhead - start, .zero), last)
    }

    /// The renderer runs the color chain on media, stills and Adjustment Layers (on the picture below them): nested
    /// sequences, other generators (text, shapes, solids) and audio take no Color effect.
    public var acceptsColor: Bool { kind == .video && !isNested && (!isGenerator || isAdjustment) }

    /// The Color effects as stored (keys, the effect switch and all), in order.
    public var colorGradeEffects: [ClipEffect] { colorEffectIndices.map { effects[$0] } }

    /// Replaces every Color effect with copies of `fx` (new ids, keys and switches kept), first in the list. The
    /// footage interpretation stays. Empty = no grade (Reset). Ignored on clips that take no color.
    public mutating func replaceColorGrade(with fx: [ClipEffect]) {
        guard acceptsColor else { return }
        for i in colorEffectIndices.reversed() { removeEffect(effects[i].id) }
        // Range grades are cut to this clip (dropped when they miss it); the first Color effect never keeps a range.
        var colors: [ClipEffect] = []
        for e in fx where e.isColor {
            var c = e.copy()
            if let r = c.colorRange {
                guard let x = clampedColorRange(r) else { continue }
                if colors.isEmpty { colors.append(Self.neutralBaseGrade()) }
                c.colorRange = x
            }
            colors.append(c.adaptingLUTs(toMedia: media, primary: colors.isEmpty))
        }
        effects.insert(contentsOf: colors, at: 0)
    }

    /// Paste Grade "Add on top": copies of `fx` (new ids, keys and switches kept) go behind the clip's own Color
    /// effects, which stay untouched. Without a grade this is `replaceColorGrade`. Ignored on clips that take no color.
    public mutating func addColorGradeOnTop(_ fx: [ClipEffect]) {
        guard acceptsColor else { return }
        guard let last = colorEffectIndices.last else { replaceColorGrade(with: fx); return }
        var add: [ClipEffect] = []
        for e in fx where e.isColor {
            var c = e.copy()
            if let r = c.colorRange {
                guard let x = clampedColorRange(r) else { continue }
                c.colorRange = x
            }
            add.append(c.adaptingLUTs(toMedia: media, primary: false))
        }
        effects.insert(contentsOf: add, at: last + 1)
    }

    /// True when a copy of `e` may be pasted onto this clip: a known effect, audio effects onto audio clips and the others onto video clips, Color only on clips that take
    /// it, generator-owned effects only on their generator.
    public func canAcceptPastedEffect(_ e: ClipEffect) -> Bool {
        guard EffectCatalog.spec(for: e.kind) != nil else { return false }
        if e.isAudio || kind == .audio { return e.isAudio && kind == .audio }   // audio effects onto audio clips only
        if e.isColor { return acceptsColor }
        if let owner = EffectCatalog.owningGenerator(of: e.kind) { return generator?.kind == owner }
        return true
    }

    /// Adds a pasted effect (new id). A Color effect goes behind the clip's Color effects (color stays first) and
    /// only on a clip that takes color; other effects are appended. Returns false when refused.
    public mutating func insertPastedEffect(_ e: ClipEffect) -> Bool {
        guard e.isColor else { effects.append(e.copy()); return true }
        guard acceptsColor else { return false }
        var at = colorEffectIndices.last.map { $0 + 1 } ?? 0
        var c = e.copy()
        if let r = c.colorRange {
            guard let x = clampedColorRange(r) else { return false }
            c.colorRange = x
            if at == 0 { effects.insert(Self.neutralBaseGrade(), at: 0); at = 1 }
        }
        effects.insert(c.adaptingLUTs(toMedia: media, primary: at == 0), at: at)
        return true
    }

    /// The color the renderer uses at clip-local `t`: switched-off Color effects are skipped; when the first one is
    /// off, a neutral first effect with the same conversion stands in (its Input LUT and Basic Correction switch), so the
    /// footage converts exactly as before and later effects stay display-referred.
    public func renderColor(atLocal t: Time) -> ClipColor {
        if let g = renderGraph {
            // Pro is active: the Color effects stay dimmed; the graph's In LUT is the conversion.
            var c = ClipColor(source: footageColor.source, useEmbeddedLUT: footageColor.useEmbeddedLUT,
                              effects: [ColorEffect(id: 1, inputLUT: g.inputLUT)])
            c.graph = g
            return c
        }
        let all = colorEffectIndices
        guard !all.isEmpty else { return ClipColor(source: footageColor.source, useEmbeddedLUT: footageColor.useEmbeddedLUT) }
        var fx: [ColorEffect] = []
        for (n, i) in all.enumerated() {
            // A masked Color effect is a grade pass in the effect chain (`effects(at:)`), not part of the clip's grade.
            if n > 0, hasLiveMaskInput(effects[i]) { continue }
            if colorEffectRenders(effects[i], position: n, atLocal: t) {
                var ce = effects[i].colorEffect(atLocal: t, id: n + 1)
                if n > 0 { let w = effects[i].rangeStrength(atLocal: t); if w < 1 { ce = ce.scaled(by: Float(w)) } }
                fx.append(ce)
            }
            else if n == 0 {
                let off = effects[i].colorEffect(atLocal: t, id: 1)
                var stand = ColorEffect(id: 1, inputLUT: off.inputLUT)
                stand.setEnabled(.basicCorrection, off.isEnabled(.basicCorrection))
                fx.append(stand)
            }
        }
        return ClipColor(footage: footageColor, effects: fx)
    }

    /// v26 and older stored the grade inside `color`: its effects become Color effects in front of the list (unless the
    /// clip already has some, or the grade is the neutral default).
    mutating func adoptLegacyGrade(_ old: ClipColor) {
        footageColor = ClipFootageColor(old)
        guard old.effects != ClipColor.defaultEffects, colorEffectIndices.isEmpty, acceptsColor else { return }
        effects.insert(contentsOf: old.effects.map(ClipEffect.colorGrade), at: 0)
    }
}
