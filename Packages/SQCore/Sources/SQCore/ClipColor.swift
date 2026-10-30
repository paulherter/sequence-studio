import Foundation

/// Source color space: transfer + gamut. Stored on `MediaInfo` (detected at import) and as a per-clip override.
public enum ColorSpaceID: String, Sendable, Hashable, Codable, CaseIterable {
    case rec709
    case sLog3SGamut3Cine
    case hlgBT2020
    // W9.3 (ProjectFile v34): older builds refuse files that may hold these.
    /// SMPTE ST 2084 (HDR10), BT.2020 primaries.
    case pqBT2020
    /// Panasonic V-Log / V-Gamut.
    case vLogVGamut
    /// Apple Log (iPhone 15 Pro and later), BT.2020 primaries.
    case appleLog
    /// DJI D-Log / D-Gamut.
    case dLogDGamut
    // F7.2 Canon Log, Canon Log 2, Canon Log 3 (Canon white paper "Canon Log Gamma Curves"), each with the three
    // color spaces Canon cameras record them in: Cinema Gamut, BT.2020, BT.709. ProjectFile v68: a file that uses one
    // is written as v68 (`Project.containsV68Content`), so older builds refuse it.
    case canonLogCinemaGamut
    case canonLogBT2020
    case canonLogBT709
    case canonLog2CinemaGamut
    case canonLog2BT2020
    case canonLog2BT709
    case canonLog3CinemaGamut
    case canonLog3BT2020
    case canonLog3BT709
    // Vendor log spaces (ARRI, RED, Blackmagic, Nikon, Fujifilm, ACES). No ProjectFile version bump by decision
    // (2026-10-17): new cases only, a build without them cannot read a file that uses one.
    /// ARRI LogC3 (EI 800) / ARRI Wide Gamut 3.
    case logC3WideGamut3
    /// ARRI LogC4 / ARRI Wide Gamut 4.
    case logC4WideGamut4
    /// RED Log3G10 / REDWideGamutRGB.
    case log3G10RedWideGamut
    /// Blackmagic Film Gen 5 / Blackmagic Wide Gamut.
    case bmdFilmGen5WideGamut
    /// Nikon N-Log / Rec. 2020.
    case nLogBT2020
    /// Fujifilm F-Log2 / F-Gamut C.
    case fLog2FGamutC
    /// ACEScct / AP1.
    case acesCCTAP1
}

/// Per-clip "Interpret Footage" override; `ClipColor.source == nil` means "use what the media says".
public typealias SourceColorOverride = ColorSpaceID

/// Reference to a LUT.
public enum LUTRef: Sendable, Hashable, Codable {
    /// Conversion slot only: the camera LUT embedded in the clip's media if `ClipColor.useEmbeddedLUT` and the media
    /// has one, else none (built-in automatic conversion).
    case automatic
    /// A `.cube` file on disk.
    case file(String)
    /// The LUT embedded in the given media item.
    case embedded(UUID)

    private enum CodingKeys: String, CodingKey { case kind, path, media }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "file": self = .file(try c.decode(String.self, forKey: .path))
        case "embedded": self = .embedded(try c.decode(UUID.self, forKey: .media))
        default: self = .automatic
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try c.encode("automatic", forKey: .kind)
        case .file(let p): try c.encode("file", forKey: .kind); try c.encode(p, forKey: .path)
        case .embedded(let m): try c.encode("embedded", forKey: .kind); try c.encode(m, forKey: .media)
        }
    }
}

/// Puck position of a color wheel: hue in degrees (0 = red, same angle as the wheel control) and amount 0…1.
public struct WheelValue: Sendable, Hashable, Codable {
    public var hue: Float
    public var amount: Float
    public init(hue: Float = 0, amount: Float = 0) { self.hue = hue; self.amount = amount }
    public var isNeutral: Bool { amount == 0 }
}

/// Which maths renders a Basic Correction (docs/research/COLOR-CORRECTION-MATH.md). Stored with every Color effect so a
/// project keeps its look: grades made before the Lumetri-matched maths existed carry `.legacy`.
public enum BasicToneModel: Int, Sendable, Hashable, Codable {
    /// Up to 2026-10-02: linear contrast about 0.45, levels-style Whites/Blacks, luma-masked Shadows/Highlights.
    case legacy = 0
    /// Matches Premiere's Lumetri: end-point-fixed tone curves on the Rec.709 signal (`BasicToneCurves`).
    case lumetri = 1
    /// What new Color effects use.
    public static let current = BasicToneModel.lumetri
}

/// Lumetri "Basic Correction". Neutral: all 0, saturation 100. The math (SQRender) works on a display-like
/// Rec.709-encoded signal whether the block sits before the Input LUT (source signal) or after it (display).
public struct BasicCorrection: Sendable, Hashable, Codable {
    public var temperature: Float = 0   // -100…100
    public var tint: Float = 0          // -100…100
    public var exposure: Float = 0      // -5…5 stops
    public var contrast: Float = 0      // -100…100
    public var highlights: Float = 0    // -100…100
    public var shadows: Float = 0       // -100…100
    public var whites: Float = 0        // -100…100
    public var blacks: Float = 0        // -100…100
    public var saturation: Float = 100  // 0…200
    public var vibrance: Float = 0      // -100…100
    /// The maths these values are meant for (not a slider). New values use `.current`.
    public var model: BasicToneModel = .current
    public init() {}
    public init(model: BasicToneModel) { self.model = model }
    public static let neutral = BasicCorrection()
    /// No slider moved (the model does not count: a neutral block does nothing in either maths).
    public var isNeutral: Bool { var n = self; n.model = Self.neutral.model; return n == .neutral }

    private enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance, model
    }

    /// A missing `model` means the values were stored before the Lumetri maths existed: `.legacy`, unless no slider was
    /// moved (then nothing looked different, and new edits get the current maths).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ def: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? def }
        temperature = try f(.temperature, 0); tint = try f(.tint, 0); exposure = try f(.exposure, 0)
        contrast = try f(.contrast, 0); highlights = try f(.highlights, 0); shadows = try f(.shadows, 0)
        whites = try f(.whites, 0); blacks = try f(.blacks, 0); saturation = try f(.saturation, 100)
        vibrance = try f(.vibrance, 0)
        // An unknown raw value (newer build) falls back to `.current` instead of failing the project load.
        if let raw = try? c.decodeIfPresent(Int.self, forKey: .model) { model = BasicToneModel(rawValue: raw) ?? .current }
        else { model = .current; if !isNeutral { model = .legacy } }
    }
}

/// Lumetri "Creative": look LUT with intensity, faded film, vibrance/saturation, shadow/highlight tint.
public struct CreativeLook: Sendable, Hashable, Codable {
    public var look: LUTRef?            // nil = none
    public var intensity: Float = 100   // 0…100
    public var fadedFilm: Float = 0     // 0…100
    public var vibrance: Float = 0      // -100…100
    public var saturation: Float = 100  // 0…200
    public var shadowTint = WheelValue()
    public var highlightTint = WheelValue()
    public var tintBalance: Float = 0   // -100…100
    public init() {}
    /// The look LUT and its intensity are ignored when judging the tone part.
    public var hasTone: Bool {
        fadedFilm != 0 || vibrance != 0 || saturation != 100 || !shadowTint.isNeutral || !highlightTint.isNeutral
    }
    public var hasLook: Bool { look != nil && look != .automatic && intensity > 0 }
    public var isNeutral: Bool { !hasTone && !hasLook }
}

public struct CurvePoint: Sendable, Hashable, Codable {
    public var x: Float, y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
}

/// RGB curves: master + per-channel control points (x ascending, 0…1). Default = the diagonal.
public struct RGBCurves: Sendable, Hashable, Codable {
    public static let diagonal = [CurvePoint(0, 0), CurvePoint(1, 1)]
    public var master = RGBCurves.diagonal
    public var red = RGBCurves.diagonal
    public var green = RGBCurves.diagonal
    public var blue = RGBCurves.diagonal
    public init() {}
    public var isNeutral: Bool { self == RGBCurves() }
}

/// Lumetri "Color Wheels": shadows / midtones / highlights wheel + luminance slider each, and a master saturation.
public struct ColorWheels: Sendable, Hashable, Codable {
    public var shadows = WheelValue()
    public var midtones = WheelValue()
    public var highlights = WheelValue()
    public var shadowsLuma: Float = 0      // -100…100
    public var midtonesLuma: Float = 0
    public var highlightsLuma: Float = 0
    public var saturation: Float = 100     // 0…200
    public init() {}
    public var isNeutral: Bool { self == ColorWheels() }
}

/// Lumetri "Hue Saturation Curves": five curves keyed by hue, luma or saturation. x = hue (0...1 around the color wheel,
/// red = 0, the curve wraps), luma (0...1) or saturation (0...1); y = the adjustment, 0.5 = no change (the flat middle line), 1 = most in the
/// positive direction (more saturation, hue shifted forward, brighter), 0 = most in the negative direction.
public struct HueCurves: Sendable, Hashable, Codable {
    public static let flat = [CurvePoint(0, 0.5), CurvePoint(1, 0.5)]
    public var hueVsSat = HueCurves.flat
    public var hueVsHue = HueCurves.flat
    public var hueVsLuma = HueCurves.flat
    public var lumaVsSat = HueCurves.flat
    public var satVsSat = HueCurves.flat
    public init() {}
    /// "Hold Saturation Legal": a Sat vs Sat curve that leaves saturation up to 70 % alone and rolls the most saturated
    /// colors back, so a boosted grade stays inside broadcast-legal chroma.
    public static let saturationHoldLegal = [CurvePoint(0, 0.5), CurvePoint(0.7, 0.5), CurvePoint(0.85, 0.42), CurvePoint(1, 0.3)]
    /// True when every point of every curve sits on the middle line.
    public var isNeutral: Bool {
        [hueVsSat, hueVsHue, hueVsLuma, lumaVsSat, satVsSat].allSatisfy { $0.allSatisfy { $0.y == 0.5 } }
    }
}

public struct Vignette: Sendable, Hashable, Codable {
    public var amount: Float = 0       // -5…5
    public var midpoint: Float = 50    // 0…100
    public var roundness: Float = 0    // -100…100
    public var feather: Float = 50     // 0…100
    public init() {}
    public var isNeutral: Bool { amount == 0 }
}

/// Color Range (HSL secondary, v48): picks the pixels whose hue, saturation and luma fall in a range (with a soft
/// edge) and corrects only those. Hue in degrees (red = 0), saturation and luma in percent of the display-referred signal.
/// Stored in the effect's grade data (not keyframable, like curves); nil = no range in this effect.
public struct HSLSecondary: Sendable, Hashable, Codable {
    /// How the mask is picked (v94): three separate ranges, or one soft ball in the 3D color volume.
    public enum MaskMode: String, Sendable, Hashable, Codable, CaseIterable {
        case ranges, volume
        public var title: String { self == .ranges ? "Ranges" : "Color Volume" }
    }
    public var maskMode: MaskMode = .ranges
    /// Color volume (v94): the ball's center is `hueCenter` plus these two (percent of saturation and luma), its radius is
    /// in percent of the volume's width; `softness` is the soft edge.
    public var volumeSat: Float = 50        // 0...100
    public var volumeLum: Float = 50        // 0...100
    public var volumeRadius: Float = 25     // 0...100
    // Qualifier.
    public var hueCenter: Float = 25        // 0..<360
    public var hueWidth: Float = 50         // 0...360; 360 = every hue (grays too)
    public var satMin: Float = 10           // 0...100
    public var satMax: Float = 100
    public var lumMin: Float = 0            // 0...100
    public var lumMax: Float = 100
    public var softness: Float = 20         // 0...100: width of the soft edge of all three ranges
    public var invert = false               // correct everything outside the range
    // Correction inside the range.
    public var hueShift: Float = 0          // -180...180 degrees
    public var saturation: Float = 100      // 0...200, 100 = unchanged
    public var exposure: Float = 0          // stops
    public var temperature: Float = 0       // -100...100
    public var tint: Float = 0              // -100...100

    public static let exposureRange: ClosedRange<Float> = -3...3

    /// A new range: skin tones (orange hues, not grays), nothing corrected yet.
    public init() {}

    /// The correction does nothing (the qualifier alone never changes the picture).
    public var isCorrectionNeutral: Bool {
        hueShift == 0 && saturation == 100 && exposure == 0 && temperature == 0 && tint == 0
    }

    /// Every value in its range; a crossed min / max pair is swapped; the hue center wraps into 0..<360.
    public func clamped() -> HSLSecondary {
        func c(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v.isFinite ? min(max(v, lo), hi) : lo }
        var r = self
        let h = hueCenter.isFinite ? hueCenter.truncatingRemainder(dividingBy: 360) : 0
        r.hueCenter = h < 0 ? h + 360 : h
        r.hueWidth = c(hueWidth, 0, 360)
        (r.satMin, r.satMax) = (c(min(satMin, satMax), 0, 100), c(max(satMin, satMax), 0, 100))
        (r.lumMin, r.lumMax) = (c(min(lumMin, lumMax), 0, 100), c(max(lumMin, lumMax), 0, 100))
        r.softness = c(softness, 0, 100)
        r.volumeSat = c(volumeSat, 0, 100); r.volumeLum = c(volumeLum, 0, 100); r.volumeRadius = c(volumeRadius, 0, 100)
        r.hueShift = c(hueShift, -180, 180)
        r.saturation = c(saturation, 0, 200)
        r.exposure = c(exposure, Self.exposureRange.lowerBound, Self.exposureRange.upperBound)
        r.temperature = c(temperature, -100, 100)
        r.tint = c(tint, -100, 100)
        return r
    }

    private enum CodingKeys: String, CodingKey {
        case hueCenter, hueWidth, satMin, satMax, lumMin, lumMax, softness, invert
        case hueShift, saturation, exposure, temperature, tint
        case maskMode, volumeSat, volumeLum, volumeRadius
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = HSLSecondary()
        func f(_ k: CodingKeys, _ v: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? v }
        hueCenter = try f(.hueCenter, def.hueCenter); hueWidth = try f(.hueWidth, def.hueWidth)
        satMin = try f(.satMin, def.satMin); satMax = try f(.satMax, def.satMax)
        lumMin = try f(.lumMin, def.lumMin); lumMax = try f(.lumMax, def.lumMax)
        softness = try f(.softness, def.softness)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        hueShift = try f(.hueShift, def.hueShift); saturation = try f(.saturation, def.saturation)
        exposure = try f(.exposure, def.exposure); temperature = try f(.temperature, def.temperature)
        tint = try f(.tint, def.tint)
        maskMode = try c.decodeIfPresent(MaskMode.self, forKey: .maskMode) ?? .ranges
        volumeSat = try f(.volumeSat, def.volumeSat); volumeLum = try f(.volumeLum, def.volumeLum)
        volumeRadius = try f(.volumeRadius, def.volumeRadius)
    }

    /// Written only when the color volume is on, so a range-mode file stays byte-identical and opens in older builds.
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(hueCenter, forKey: .hueCenter); try c.encode(hueWidth, forKey: .hueWidth)
        try c.encode(satMin, forKey: .satMin); try c.encode(satMax, forKey: .satMax)
        try c.encode(lumMin, forKey: .lumMin); try c.encode(lumMax, forKey: .lumMax)
        try c.encode(softness, forKey: .softness); try c.encode(invert, forKey: .invert)
        try c.encode(hueShift, forKey: .hueShift); try c.encode(saturation, forKey: .saturation)
        try c.encode(exposure, forKey: .exposure); try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        if maskMode != .ranges {
            try c.encode(maskMode, forKey: .maskMode)
            try c.encode(volumeSat, forKey: .volumeSat); try c.encode(volumeLum, forKey: .volumeLum)
            try c.encode(volumeRadius, forKey: .volumeRadius)
        }
    }
}

// MARK: - Color effects (fixed Lumetri-like sections, v12)

/// The fixed sections of one Color effect, in panel and processing order (Basic Correction includes the Input LUT).
public enum ColorSectionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case basicCorrection, creative, curves, wheels, zoneBoard, hslSecondary, vignette

    public var title: String {
        switch self {
        case .basicCorrection: "Basic"
        case .creative: "Creative"
        case .curves: "Curves"
        case .wheels: "Wheels & Match"
        case .hslSecondary: "Color Range"
        case .zoneBoard: "Zone Board"
        case .vignette: "Vignette"
        }
    }
}

/// One "Color" effect (Premiere: one Lumetri Color). Fixed sections, each with its own enable toggle.
/// Processing order inside one effect: Basic Correction sliders -> Input LUT -> Creative -> Curves -> Wheels -> Color Range
/// -> Vignette.
/// In the first effect the sliders work on the source signal and the Input LUT is the conversion step; later effects
/// work on display-referred Rec.709 and their Input LUT is an ordinary look (with intensity).
public struct ColorEffect: Sendable, Hashable, Codable, Identifiable {
    public var id: Int
    public var basic = BasicCorrection()
    /// Input LUT inside Basic Correction. nil = none (built-in conversion in the first effect). `.automatic` = the
    /// media's embedded camera LUT (first effect only).
    public var inputLUT: LUTRef?
    /// 0…100; only used by the Input LUT of a later effect (the conversion LUT of the first effect runs at full strength).
    public var inputLUTIntensity: Float = 100
    public var creative = CreativeLook()
    public var curves = RGBCurves()
    /// Hue Saturation Curves; part of the Curves section (its toggle, neutral check and Reset).
    public var hueCurves = HueCurves()
    public var wheels = ColorWheels()
    public var vignette = Vignette()
    /// Color Range (HSL secondary); nil = none. Grade data, not keyframable.
    public var hslSecondary: HSLSecondary?
    /// Zone Board (v94); nil = none. Grade data, not keyframable.
    public var zoneBoard: ZoneBoard?
    /// Sections whose toggle is off (canonical order, so the JSON is stable).
    public private(set) var disabled: [ColorSectionKind] = []

    public init(id: Int, inputLUT: LUTRef? = nil) { self.id = id; self.inputLUT = inputLUT }

    public func isEnabled(_ k: ColorSectionKind) -> Bool { !disabled.contains(k) }

    public mutating func setEnabled(_ k: ColorSectionKind, _ on: Bool) {
        guard isEnabled(k) != on else { return }            // no-op: `disabled` is already canonical (init and decode)
        var set = Set(disabled)
        if on { set.remove(k) } else { set.insert(k) }
        disabled = ColorSectionKind.allCases.filter(set.contains)
    }

    /// The Input LUT does nothing when it is none or automatic (automatic only acts for S-Log3 media with an embedded
    /// look; the caller decides that).
    public var inputLUTIsNeutral: Bool { inputLUT == nil || inputLUT == .automatic }

    /// Has no effect on the picture (neutral parameters), ignoring the toggle.
    public func isNeutral(_ k: ColorSectionKind) -> Bool {
        switch k {
        case .basicCorrection: basic.isNeutral && inputLUTIsNeutral
        case .creative: creative.isNeutral
        case .curves: curves.isNeutral && hueCurves.isNeutral
        case .wheels: wheels.isNeutral
        case .hslSecondary: hslSecondary?.isCorrectionNeutral ?? true
        case .zoneBoard: zoneBoard?.isNeutral ?? true
        case .vignette: vignette.isNeutral
        }
    }

    /// Resets one section to its defaults (keeps the toggle). The first effect's Input LUT returns to `.automatic`.
    public mutating func reset(_ k: ColorSectionKind, isPrimary: Bool) {
        switch k {
        case .basicCorrection: basic = BasicCorrection(); inputLUT = isPrimary ? .automatic : nil; inputLUTIntensity = 100
        case .creative: creative = CreativeLook()
        case .curves: curves = RGBCurves(); hueCurves = HueCurves()
        case .wheels: wheels = ColorWheels()
        case .hslSecondary: hslSecondary = nil
        case .zoneBoard: zoneBoard = nil
        case .vignette: vignette = Vignette()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, basic, inputLUT, inputLUTIntensity, creative, curves, hueCurves, wheels, vignette, hslSecondary, zoneBoard, disabled
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 1
        basic = try c.decodeIfPresent(BasicCorrection.self, forKey: .basic) ?? BasicCorrection()
        // Absent key = none; an explicit "none" is JSON null.
        inputLUT = c.contains(.inputLUT) ? try c.decodeIfPresent(LUTRef.self, forKey: .inputLUT) : nil
        inputLUTIntensity = try c.decodeIfPresent(Float.self, forKey: .inputLUTIntensity) ?? 100
        creative = try c.decodeIfPresent(CreativeLook.self, forKey: .creative) ?? CreativeLook()
        curves = try c.decodeIfPresent(RGBCurves.self, forKey: .curves) ?? RGBCurves()
        hueCurves = try c.decodeIfPresent(HueCurves.self, forKey: .hueCurves) ?? HueCurves()
        wheels = try c.decodeIfPresent(ColorWheels.self, forKey: .wheels) ?? ColorWheels()
        vignette = try c.decodeIfPresent(Vignette.self, forKey: .vignette) ?? Vignette()
        hslSecondary = try c.decodeIfPresent(HSLSecondary.self, forKey: .hslSecondary)
        zoneBoard = try c.decodeIfPresent(ZoneBoard.self, forKey: .zoneBoard)
        let off = Set(try c.decodeIfPresent([ColorSectionKind].self, forKey: .disabled) ?? [])
        disabled = ColorSectionKind.allCases.filter(off.contains)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(basic, forKey: .basic)
        try c.encode(inputLUT, forKey: .inputLUT)   // nil encodes as null = "none"
        try c.encode(inputLUTIntensity, forKey: .inputLUTIntensity)
        try c.encode(creative, forKey: .creative)
        try c.encode(curves, forKey: .curves)
        if !hueCurves.isNeutral { try c.encode(hueCurves, forKey: .hueCurves) }
        try c.encode(wheels, forKey: .wheels)
        try c.encode(vignette, forKey: .vignette)
        try c.encodeIfPresent(hslSecondary, forKey: .hslSecondary)
        try c.encodeIfPresent(zoneBoard, forKey: .zoneBoard)
        if !disabled.isEmpty { try c.encode(disabled, forKey: .disabled) }
    }
}

/// Static (keyframe-free) per-clip color settings: the source interpretation plus one or more Color effects applied
/// in order (a clip can hold several, like stacking Lumetri Color effects in Premiere; always at least one).
public struct ClipColor: Sendable, Hashable, Codable {
    /// nil = from media (`MediaInfo.colorSpace`).
    public var source: SourceColorOverride?
    /// Per-clip toggle for the embedded camera LUT (used by an `.automatic` Input LUT).
    public var useEmbeddedLUT: Bool
    /// How a log source is converted; see `LogMode` (stored on the clip's `ClipFootageColor`, v93).
    public var logMode: LogMode = .cameraLUT
    /// The space the conversion delivers; see `TargetSpace` (v93).
    public var targetSpace: TargetSpace = .rec709
    /// Automatic HDR/SDR conform before the grade (v93, default on).
    public var hdrConform: Bool = true
    public var effects: [ColorEffect] {
        didSet { if effects.isEmpty { effects = ClipColor.defaultEffects } }   // `primary` needs one
    }

    public static let defaultEffects: [ColorEffect] = [ColorEffect(id: 1, inputLUT: .automatic)]

    /// The Pro grade to render instead of `effects` (set by `Clip.renderColor` while Pro is active; never stored).
    public var graph: ColorGraph?

    public init(source: SourceColorOverride? = nil, useEmbeddedLUT: Bool = true,
                effects: [ColorEffect] = ClipColor.defaultEffects) {
        self.source = source; self.useEmbeddedLUT = useEmbeddedLUT
        self.effects = effects.isEmpty ? ClipColor.defaultEffects : effects
    }

    public static let `default` = ClipColor()
    public var isDefault: Bool { self == .default }

    /// The first effect: its Input LUT is the conversion step.
    public var primary: ColorEffect { effects[0] }

    /// True when the picture is unchanged: every enabled section of every effect is neutral. A non-Rec.709 source
    /// always needs the conversion, so it is never identity.
    public func isIdentity(rec709Source: Bool) -> Bool {
        if !rec709Source { return false }
        if let graph {
            return graph.isNeutral && (graph.inputLUT == nil || graph.inputLUT == .automatic)
        }
        return effects.allSatisfy { e in
            ColorSectionKind.allCases.allSatisfy { !e.isEnabled($0) || e.isNeutral($0) }
        }
    }

    public func effect(_ id: Int) -> ColorEffect? { effects.first { $0.id == id } }

    /// Appends a default Color effect; returns its id.
    @discardableResult
    public mutating func addEffect() -> Int {
        let id = (effects.map(\.id).max() ?? 0) + 1
        effects.append(ColorEffect(id: id))
        return id
    }

    /// Removes an effect; the last one cannot be removed (reset it instead).
    public mutating func removeEffect(_ id: Int) {
        guard effects.count > 1 else { return }
        effects.removeAll { $0.id == id }
    }

    /// Resets one section of an effect to its defaults (keeps its toggle).
    public mutating func resetSection(_ k: ColorSectionKind, in id: Int) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        effects[i].reset(k, isPrimary: i == 0)
    }

    // MARK: Codable (v12; v11 `sections` and v10 `correction` / LUT fields are migrated on decode)

    private enum CodingKeys: String, CodingKey { case source, useEmbeddedLUT, effects, sections, logMode, targetSpace, hdrConform }
    private enum LegacyKeys: String, CodingKey {
        case correction, conversionLUT, creativeLUT, creativeIntensity
        case bypassCorrection, bypassConversionLUT, bypassCreativeLUT
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let source = try c.decodeIfPresent(ColorSpaceID.self, forKey: .source)
        let embedded = try c.decodeIfPresent(Bool.self, forKey: .useEmbeddedLUT) ?? true
        if let effects = try c.decodeIfPresent([ColorEffect].self, forKey: .effects) {
            self.init(source: source, useEmbeddedLUT: embedded, effects: effects)
        } else if let sections = try c.decodeIfPresent([V11Section].self, forKey: .sections) {
            self.init(source: source, useEmbeddedLUT: embedded, effects: Self.migrate(v11: sections))
        } else {
            self.init(source: source, useEmbeddedLUT: embedded, effects: Self.migrate(v11: try Self.legacySections(d)))
        }
        logMode = try c.decodeIfPresent(LogMode.self, forKey: .logMode) ?? .cameraLUT
        targetSpace = try c.decodeIfPresent(TargetSpace.self, forKey: .targetSpace) ?? .rec709
        hdrConform = try c.decodeIfPresent(Bool.self, forKey: .hdrConform) ?? true
    }

    /// v11 -> v12: the ordered block list maps into the fixed sections. The first block of each kind fills the first
    /// Color effect; further blocks of a kind fill a second effect, then a third, and so on. The Input LUT moves into
    /// Basic Correction (a bypassed LUT becomes "none"). The block order is lost: inside one effect it is fixed.
    static func migrate(v11 sections: [V11Section]) -> [ColorEffect] {
        var pool = sections
        var effects: [ColorEffect] = []
        while !pool.isEmpty {
            var e = ColorEffect(id: effects.count + 1, inputLUT: effects.isEmpty ? .automatic : nil)
            var taken = Set<String>()
            var rest: [V11Section] = []
            for s in pool {
                let slot: String
                switch s.params {
                case .inputLUT: slot = "lut"
                case .basic: slot = "basic"
                case .creative: slot = "creative"
                case .curves: slot = "curves"
                case .wheels: slot = "wheels"
                case .vignette: slot = "vignette"
                }
                guard taken.insert(slot).inserted else { rest.append(s); continue }
                switch s.params {
                case .inputLUT(let r): e.inputLUT = s.enabled ? r : nil
                case .basic(let b): e.basic = b; e.setEnabled(.basicCorrection, s.enabled)
                case .creative(let k): e.creative = k; e.setEnabled(.creative, s.enabled)
                case .curves(let k): e.curves = k; e.setEnabled(.curves, s.enabled)
                case .wheels(let w): e.wheels = w; e.setEnabled(.wheels, s.enabled)
                case .vignette(let v): e.vignette = v; e.setEnabled(.vignette, s.enabled)
                }
            }
            // The Basic toggle now gates the Input LUT too: a bypassed Basic with a live LUT keeps the LUT (the bypassed
            // slider values are dropped) so the picture does not change.
            if !e.isEnabled(.basicCorrection), e.inputLUT != nil {
                e.basic = BasicCorrection()
                e.setEnabled(.basicCorrection, true)
            }
            effects.append(e)
            pool = rest
        }
        return effects
    }

    /// v10 single correction + conversion LUT + creative LUT as v11-style blocks in the old order (Basic Correction,
    /// Input LUT, Creative). A bypassed legacy slot becomes a disabled block.
    private static func legacySections(_ d: Decoder) throws -> [V11Section] {
        let c = try d.container(keyedBy: LegacyKeys.self)
        var b = BasicCorrection(model: .legacy)
        if let old = try c.decodeIfPresent(LegacyCorrection.self, forKey: .correction) {
            b.temperature = old.temperature; b.tint = old.tint; b.exposure = min(max(old.exposure, -5), 5)
            b.contrast = old.contrast; b.highlights = old.highlights; b.shadows = old.shadows; b.saturation = old.saturation
        }
        if b.isNeutral { b.model = .current }
        let bypassBasic = try c.decodeIfPresent(Bool.self, forKey: .bypassCorrection) ?? false
        // An absent key = default (.automatic); an explicit "none" is stored as JSON null.
        let conv: LUTRef? = c.contains(.conversionLUT) ? try c.decodeIfPresent(LUTRef.self, forKey: .conversionLUT) : .automatic
        let bypassConv = try c.decodeIfPresent(Bool.self, forKey: .bypassConversionLUT) ?? false
        var out = [V11Section(id: 1, enabled: !bypassBasic, params: .basic(b)),
                   V11Section(id: 2, enabled: !bypassConv, params: .inputLUT(conv))]
        if let look = try c.decodeIfPresent(LUTRef.self, forKey: .creativeLUT), look != .automatic {
            var cl = CreativeLook()
            cl.look = look
            cl.intensity = Float(min(max(try c.decodeIfPresent(Double.self, forKey: .creativeIntensity) ?? 1, 0), 1)) * 100
            let bypass = try c.decodeIfPresent(Bool.self, forKey: .bypassCreativeLUT) ?? false
            out.append(V11Section(id: 3, enabled: !bypass, params: .creative(cl)))
        }
        return out
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(useEmbeddedLUT, forKey: .useEmbeddedLUT)
        try c.encode(effects, forKey: .effects)
        if logMode != .cameraLUT { try c.encode(logMode, forKey: .logMode) }
        if targetSpace != .rec709 { try c.encode(targetSpace, forKey: .targetSpace) }
        if !hdrConform { try c.encode(false, forKey: .hdrConform) }
    }
}

// MARK: - Legacy (decode only)

/// A v11 block. Shape matches the v11 encoding (its params were a synthesised enum).
struct V11Section: Decodable {
    var id: Int
    var enabled: Bool
    var params: V11Params
}

enum V11Params: Decodable {
    case inputLUT(LUTRef?)
    case basic(BasicCorrection)
    case creative(CreativeLook)
    case curves(RGBCurves)
    case wheels(ColorWheels)
    case vignette(Vignette)
}

/// The v10 correction object (decode only).
private struct LegacyCorrection: Decodable {
    var temperature: Float = 0, tint: Float = 0, exposure: Float = 0, contrast: Float = 0
    var highlights: Float = 0, shadows: Float = 0, saturation: Float = 100
    private enum CodingKeys: String, CodingKey { case temperature, tint, exposure, contrast, highlights, shadows, saturation }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ def: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? def }
        temperature = try f(.temperature, 0); tint = try f(.tint, 0); exposure = try f(.exposure, 0)
        contrast = try f(.contrast, 0); highlights = try f(.highlights, 0); shadows = try f(.shadows, 0)
        saturation = try f(.saturation, 100)
    }
}
