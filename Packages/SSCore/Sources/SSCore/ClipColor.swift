import Foundation

/// Basic correction parameters (source-linear domain). Neutral: all 0, saturation 100. Parameters only: the math
/// (`PreparedCorrection`) lives in SSRender.
public struct ColorCorrection: Sendable, Equatable, Hashable, Codable {
    public var temperature: Float = 0   // -100…100
    public var tint: Float = 0          // -100…100
    public var exposure: Float = 0      // -4…4 EV
    public var contrast: Float = 0      // -100…100
    public var highlights: Float = 0    // -100…100
    public var shadows: Float = 0       // -100…100
    public var saturation: Float = 100  // 0…200

    public init() {}

    public static let neutral = ColorCorrection()
    public var isNeutral: Bool { self == .neutral }

    private enum CodingKeys: String, CodingKey { case temperature, tint, exposure, contrast, highlights, shadows, saturation }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ def: Float) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? def }
        temperature = try f(.temperature, 0); tint = try f(.tint, 0); exposure = try f(.exposure, 0)
        contrast = try f(.contrast, 0); highlights = try f(.highlights, 0); shadows = try f(.shadows, 0)
        saturation = try f(.saturation, 100)
    }
}

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

/// Static (keyframe-free) per-clip colour settings. Processing order: correction -> conversion LUT -> creative LUT.
public struct ClipColor: Sendable, Hashable, Codable {
    /// nil = from media (`MediaInfo.colorSpace`).
    public var source: SourceColorOverride?
    public var correction: ColorCorrection
    /// nil = no LUT (built-in automatic conversion); `.automatic` = embedded camera LUT when enabled and present.
    public var conversionLUT: LUTRef?
    /// Per-clip toggle for the embedded camera LUT (used by `.automatic`).
    public var useEmbeddedLUT: Bool
    public var creativeLUT: LUTRef?
    /// 0…1.
    public var creativeIntensity: Double
    public var bypassCorrection: Bool
    public var bypassConversionLUT: Bool
    public var bypassCreativeLUT: Bool

    public init(source: SourceColorOverride? = nil, correction: ColorCorrection = .neutral,
                conversionLUT: LUTRef? = .automatic, useEmbeddedLUT: Bool = true,
                creativeLUT: LUTRef? = nil, creativeIntensity: Double = 1,
                bypassCorrection: Bool = false, bypassConversionLUT: Bool = false, bypassCreativeLUT: Bool = false) {
        self.source = source; self.correction = correction
        self.conversionLUT = conversionLUT; self.useEmbeddedLUT = useEmbeddedLUT
        self.creativeLUT = creativeLUT; self.creativeIntensity = creativeIntensity
        self.bypassCorrection = bypassCorrection; self.bypassConversionLUT = bypassConversionLUT
        self.bypassCreativeLUT = bypassCreativeLUT
    }

    public static let `default` = ClipColor()
    public var isDefault: Bool { self == .default }

    private enum CodingKeys: String, CodingKey {
        case source, correction, conversionLUT, useEmbeddedLUT, creativeLUT, creativeIntensity
        case bypassCorrection, bypassConversionLUT, bypassCreativeLUT
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(source: try c.decodeIfPresent(ColorSpaceID.self, forKey: .source),
                  correction: try c.decodeIfPresent(ColorCorrection.self, forKey: .correction) ?? .neutral,
                  // Absent key = default (.automatic); an explicit "none" is stored as JSON null.
                  conversionLUT: c.contains(.conversionLUT)
                      ? try c.decodeIfPresent(LUTRef.self, forKey: .conversionLUT) : .automatic,
                  useEmbeddedLUT: try c.decodeIfPresent(Bool.self, forKey: .useEmbeddedLUT) ?? true,
                  creativeLUT: try c.decodeIfPresent(LUTRef.self, forKey: .creativeLUT),
                  creativeIntensity: try c.decodeIfPresent(Double.self, forKey: .creativeIntensity) ?? 1,
                  bypassCorrection: try c.decodeIfPresent(Bool.self, forKey: .bypassCorrection) ?? false,
                  bypassConversionLUT: try c.decodeIfPresent(Bool.self, forKey: .bypassConversionLUT) ?? false,
                  bypassCreativeLUT: try c.decodeIfPresent(Bool.self, forKey: .bypassCreativeLUT) ?? false)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(correction, forKey: .correction)
        if let l = conversionLUT { try c.encode(l, forKey: .conversionLUT) } else { try c.encodeNil(forKey: .conversionLUT) }
        try c.encode(useEmbeddedLUT, forKey: .useEmbeddedLUT)
        try c.encodeIfPresent(creativeLUT, forKey: .creativeLUT)
        try c.encode(creativeIntensity, forKey: .creativeIntensity)
        try c.encode(bypassCorrection, forKey: .bypassCorrection)
        try c.encode(bypassConversionLUT, forKey: .bypassConversionLUT)
        try c.encode(bypassCreativeLUT, forKey: .bypassCreativeLUT)
    }
}
