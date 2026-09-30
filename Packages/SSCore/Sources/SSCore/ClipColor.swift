import Foundation

/// Source colour space: transfer + gamut. Stored on `MediaInfo` (detected at import) and as a per-clip override.
public enum ColorSpaceID: String, Sendable, Hashable, Codable, CaseIterable {
    case rec709
    case sLog3SGamut3Cine
    case hlgBT2020
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

/// Puck position of a colour wheel: hue in degrees (0 = red, same angle as the wheel control) and amount 0…1.
public struct WheelValue: Sendable, Hashable, Codable {
    public var hue: Float
    public var amount: Float
    public init(hue: Float = 0, amount: Float = 0) { self.hue = hue; self.amount = amount }
    public var isNeutral: Bool { amount == 0 }
}

/// Lumetri "Basic Correction". Neutral: all 0, saturation 100. The math (SSRender) works on a display-like
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
    public init() {}
    public static let neutral = BasicCorrection()
    public var isNeutral: Bool { self == .neutral }
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

public struct Vignette: Sendable, Hashable, Codable {
    public var amount: Float = 0       // -5…5
    public var midpoint: Float = 50    // 0…100
    public var roundness: Float = 0    // -100…100
    public var feather: Float = 50     // 0…100
    public init() {}
    public var isNeutral: Bool { amount == 0 }
}

// MARK: - Colour effects (fixed Lumetri-like sections, v12)

/// The fixed sections of one Colour effect, in panel and processing order (Basic Correction includes the Input LUT).
public enum ColorSectionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case basicCorrection, creative, curves, wheels, hslSecondary, vignette

    public var title: String {
        switch self {
        case .basicCorrection: "Basic Correction"
        case .creative: "Creative"
        case .curves: "Curves"
        case .wheels: "Color Wheels & Match"
        case .hslSecondary: "HSL Secondary"
        case .vignette: "Vignette"
        }
    }

    /// HSL Secondary is a placeholder (no maths yet); its toggle and body are disabled in the panel.
    public var isImplemented: Bool { self != .hslSecondary }
}

/// One "Colour" effect (Premiere: one Lumetri Color). Fixed sections, each with its own enable toggle.
/// Processing order inside one effect: Basic Correction sliders -> Input LUT -> Creative -> Curves -> Wheels -> Vignette.
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
    public var wheels = ColorWheels()
    public var vignette = Vignette()
    /// Sections whose toggle is off (canonical order, so the JSON is stable).
    public private(set) var disabled: [ColorSectionKind] = []

    public init(id: Int, inputLUT: LUTRef? = nil) { self.id = id; self.inputLUT = inputLUT }

    public func isEnabled(_ k: ColorSectionKind) -> Bool { !disabled.contains(k) }

    public mutating func setEnabled(_ k: ColorSectionKind, _ on: Bool) {
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
        case .curves: curves.isNeutral
        case .wheels: wheels.isNeutral
        case .hslSecondary: true
        case .vignette: vignette.isNeutral
        }
    }

    /// Resets one section to its defaults (keeps the toggle). The first effect's Input LUT returns to `.automatic`.
    public mutating func reset(_ k: ColorSectionKind, isPrimary: Bool) {
        switch k {
        case .basicCorrection: basic = BasicCorrection(); inputLUT = isPrimary ? .automatic : nil; inputLUTIntensity = 100
        case .creative: creative = CreativeLook()
        case .curves: curves = RGBCurves()
        case .wheels: wheels = ColorWheels()
        case .hslSecondary: break
        case .vignette: vignette = Vignette()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, basic, inputLUT, inputLUTIntensity, creative, curves, wheels, vignette, disabled
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
        wheels = try c.decodeIfPresent(ColorWheels.self, forKey: .wheels) ?? ColorWheels()
        vignette = try c.decodeIfPresent(Vignette.self, forKey: .vignette) ?? Vignette()
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
        try c.encode(wheels, forKey: .wheels)
        try c.encode(vignette, forKey: .vignette)
        if !disabled.isEmpty { try c.encode(disabled, forKey: .disabled) }
    }
}

/// Static (keyframe-free) per-clip colour settings: the source interpretation plus one or more Colour effects applied
/// in order (a clip can hold several, like stacking Lumetri Color effects in Premiere; always at least one).
public struct ClipColor: Sendable, Hashable, Codable {
    /// nil = from media (`MediaInfo.colorSpace`).
    public var source: SourceColorOverride?
    /// Per-clip toggle for the embedded camera LUT (used by an `.automatic` Input LUT).
    public var useEmbeddedLUT: Bool
    public var effects: [ColorEffect]

    public static let defaultEffects: [ColorEffect] = [ColorEffect(id: 1, inputLUT: .automatic)]

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
        return effects.allSatisfy { e in
            ColorSectionKind.allCases.allSatisfy { !e.isEnabled($0) || e.isNeutral($0) }
        }
    }

    public func effect(_ id: Int) -> ColorEffect? { effects.first { $0.id == id } }

    /// Appends a default Colour effect; returns its id.
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

    private enum CodingKeys: String, CodingKey { case source, useEmbeddedLUT, effects, sections }
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
    }

    /// v11 -> v12: the ordered block list maps into the fixed sections. The first block of each kind fills the first
    /// Colour effect; further blocks of a kind fill a second effect, then a third, and so on. The Input LUT moves into
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
            effects.append(e)
            pool = rest
        }
        return effects
    }

    /// v10 single correction + conversion LUT + creative LUT as v11-style blocks in the old order (Basic Correction,
    /// Input LUT, Creative). A bypassed legacy slot becomes a disabled block.
    private static func legacySections(_ d: Decoder) throws -> [V11Section] {
        let c = try d.container(keyedBy: LegacyKeys.self)
        var b = BasicCorrection()
        if let old = try c.decodeIfPresent(LegacyCorrection.self, forKey: .correction) {
            b.temperature = old.temperature; b.tint = old.tint; b.exposure = min(max(old.exposure, -5), 5)
            b.contrast = old.contrast; b.highlights = old.highlights; b.shadows = old.shadows; b.saturation = old.saturation
        }
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
