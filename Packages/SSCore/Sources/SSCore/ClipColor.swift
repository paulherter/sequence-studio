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

// MARK: - Sections (Lumetri-like, modular)

/// Kinds of colour sections in a clip's ordered stack.
public enum ColorSectionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case basicCorrection, inputLUT, creative, curves, wheels, vignette

    public var title: String {
        switch self {
        case .inputLUT: "Input LUT"
        case .basicCorrection: "Basic Correction"
        case .creative: "Creative"
        case .curves: "Curves"
        case .wheels: "Color Wheels"
        case .vignette: "Vignette"
        }
    }

    /// Kinds the "+" menu offers. The Input LUT block exists exactly once per clip (it is the conversion step).
    public static let addable: [ColorSectionKind] = [.basicCorrection, .creative, .curves, .wheels, .vignette]
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

/// Parameters of one section.
public enum ColorSectionParams: Sendable, Hashable, Codable {
    /// nil = none (built-in automatic conversion); `.automatic` = the media's embedded camera LUT when enabled.
    case inputLUT(LUTRef?)
    case basic(BasicCorrection)
    case creative(CreativeLook)
    case curves(RGBCurves)
    case wheels(ColorWheels)
    case vignette(Vignette)

    public var kind: ColorSectionKind {
        switch self {
        case .inputLUT: .inputLUT
        case .basic: .basicCorrection
        case .creative: .creative
        case .curves: .curves
        case .wheels: .wheels
        case .vignette: .vignette
        }
    }

    public static func defaults(for kind: ColorSectionKind) -> ColorSectionParams {
        switch kind {
        case .inputLUT: .inputLUT(.automatic)
        case .basicCorrection: .basic(BasicCorrection())
        case .creative: .creative(CreativeLook())
        case .curves: .curves(RGBCurves())
        case .wheels: .wheels(ColorWheels())
        case .vignette: .vignette(Vignette())
        }
    }
}

/// One entry of the stack. `id` is unique within a clip's stack (stable across edits and reorders).
public struct ColorSection: Sendable, Hashable, Codable, Identifiable {
    public var id: Int
    public var enabled: Bool
    public var params: ColorSectionParams
    public var kind: ColorSectionKind { params.kind }

    public init(id: Int, enabled: Bool = true, params: ColorSectionParams) {
        self.id = id; self.enabled = enabled; self.params = params
    }

    /// Has no effect on the picture (neutral parameters). The Input LUT is neutral when it is "none" or "automatic"
    /// (automatic only acts for S-Log3 media with an embedded look; the caller decides that).
    public var isNeutral: Bool {
        switch params {
        case .inputLUT(let l): l == nil || l == .automatic
        case .basic(let b): b.isNeutral
        case .creative(let c): c.isNeutral
        case .curves(let c): c.isNeutral
        case .wheels(let w): w.isNeutral
        case .vignette(let v): v.isNeutral
        }
    }
}

/// Static (keyframe-free) per-clip colour settings: the source interpretation plus an ordered stack of sections.
/// Processing order is the list order (DECISIONS 2026-10-01). The single Input LUT section is the conversion step
/// (camera LUT or the built-in automatic conversion): blocks above it work on the source signal, blocks below it on
/// display-referred Rec.709.
public struct ClipColor: Sendable, Hashable, Codable {
    /// nil = from media (`MediaInfo.colorSpace`).
    public var source: SourceColorOverride?
    /// Per-clip toggle for the embedded camera LUT (used by an `.automatic` Input LUT).
    public var useEmbeddedLUT: Bool
    public var sections: [ColorSection]

    /// Default stack: Basic Correction, then the Input LUT directly beneath it.
    public static let defaultSections: [ColorSection] = [
        ColorSection(id: 1, params: .defaults(for: .basicCorrection)),
        ColorSection(id: 2, params: .defaults(for: .inputLUT)),
    ]

    public init(source: SourceColorOverride? = nil, useEmbeddedLUT: Bool = true,
                sections: [ColorSection] = ClipColor.defaultSections) {
        self.source = source; self.useEmbeddedLUT = useEmbeddedLUT; self.sections = sections
    }

    public static let `default` = ClipColor()
    public var isDefault: Bool { self == .default }

    /// True when the picture is unchanged: every enabled section is neutral (for a Rec.709 source an automatic or
    /// empty Input LUT is neutral; for other sources the conversion always does something).
    public func isIdentity(rec709Source: Bool) -> Bool {
        sections.allSatisfy { !$0.enabled || ($0.isNeutral && (rec709Source || $0.kind != .inputLUT)) }
    }

    public func section(_ id: Int) -> ColorSection? { sections.first { $0.id == id } }

    /// Adds a default section of `kind` (at the end unless `index` is given); returns its id. The Input LUT exists once.
    @discardableResult
    public mutating func addSection(_ kind: ColorSectionKind, at index: Int? = nil) -> Int? {
        if kind == .inputLUT, sections.contains(where: { $0.kind == .inputLUT }) { return nil }
        let id = (sections.map(\.id).max() ?? 0) + 1
        let s = ColorSection(id: id, params: .defaults(for: kind))
        sections.insert(s, at: min(max(index ?? sections.count, 0), sections.count))
        return id
    }

    /// The Input LUT cannot be removed (disable it instead).
    public mutating func removeSection(_ id: Int) {
        sections.removeAll { $0.id == id && $0.kind != .inputLUT }
    }

    /// Moves a section so it ends up at `destination` (index in the list after removal).
    public mutating func moveSection(_ id: Int, to destination: Int) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        let s = sections.remove(at: i)
        sections.insert(s, at: min(max(destination, 0), sections.count))
    }

    /// Resets a section's parameters to the defaults of its kind (keeps id, position and enabled state).
    public mutating func resetSection(_ id: Int) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[i].params = .defaults(for: sections[i].kind)
    }

    // MARK: Codable (v11; v10 `correction` / LUT fields are migrated on decode)

    private enum CodingKeys: String, CodingKey { case source, useEmbeddedLUT, sections }
    private enum LegacyKeys: String, CodingKey {
        case correction, conversionLUT, creativeLUT, creativeIntensity
        case bypassCorrection, bypassConversionLUT, bypassCreativeLUT
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let source = try c.decodeIfPresent(ColorSpaceID.self, forKey: .source)
        let embedded = try c.decodeIfPresent(Bool.self, forKey: .useEmbeddedLUT) ?? true
        if var sections = try c.decodeIfPresent([ColorSection].self, forKey: .sections) {
            // Invariant: exactly one Input LUT.
            if !sections.contains(where: { $0.kind == .inputLUT }) {
                sections.append(ColorSection(id: (sections.map(\.id).max() ?? 0) + 1, params: .defaults(for: .inputLUT)))
            }
            self.init(source: source, useEmbeddedLUT: embedded, sections: sections)
        } else {
            self.init(source: source, useEmbeddedLUT: embedded, sections: try Self.migratedSections(d))
        }
    }

    /// v10 -> v11: the single correction + conversion LUT + creative LUT become blocks in the old order (Basic
    /// Correction, Input LUT, Creative). A bypassed legacy slot becomes a disabled block. The maths changed (see
    /// SSRender), so the look is close, not bit-identical.
    static func migratedSections(_ d: Decoder) throws -> [ColorSection] {
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
        var out = [ColorSection(id: 1, enabled: !bypassBasic, params: .basic(b)),
                   ColorSection(id: 2, enabled: !bypassConv, params: .inputLUT(conv))]
        if let look = try c.decodeIfPresent(LUTRef.self, forKey: .creativeLUT), look != .automatic {
            var cl = CreativeLook()
            cl.look = look
            cl.intensity = Float(min(max(try c.decodeIfPresent(Double.self, forKey: .creativeIntensity) ?? 1, 0), 1)) * 100
            let bypass = try c.decodeIfPresent(Bool.self, forKey: .bypassCreativeLUT) ?? false
            out.append(ColorSection(id: 3, enabled: !bypass, params: .creative(cl)))
        }
        return out
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(useEmbeddedLUT, forKey: .useEmbeddedLUT)
        try c.encode(sections, forKey: .sections)
    }
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
