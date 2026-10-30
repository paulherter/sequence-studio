import Foundation

// W8.3 StyleKitTokens: project-level brand tokens (fonts, colors, the caption pill, the caption style, motion defaults).
// Values that may follow the brand are `StyleValue`s: a literal or the name of a token. Resolution happens where the value
// is used (captions resolve through the caption library every frame, text clips are re-resolved when the kit changes), so
// changing a token changes every caption and text that refers to it. SQText owns the text side (StyleKit+Text.swift).

/// A literal value or a reference to a token of the project's `StyleKit`. JSON: `{"literal": v}` or `{"token": "name"}`.
public enum StyleValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case literal(Value)
    case token(String)

    /// The literal, or the token's value from `lookup`; nil for a token the kit does not define.
    public func resolve(_ lookup: (String) -> Value?) -> Value? {
        switch self {
        case .literal(let v): v
        case .token(let name): lookup(name)
        }
    }

    public var tokenName: String? { if case .token(let n) = self { n } else { nil } }

    private enum CodingKeys: String, CodingKey { case literal, token }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try c.decodeIfPresent(String.self, forKey: .token) { self = .token(name); return }
        guard c.contains(.literal) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "StyleValue needs literal or token"))
        }
        self = .literal(try c.decode(Value.self, forKey: .literal))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let v): try c.encode(v, forKey: .literal)
        case .token(let n): try c.encode(n, forKey: .token)
        }
    }
}

/// The caption pill (rounded box behind the words). Padding in em (fraction of the font size), so it scales with the text.
public struct StylePill: Codable, Hashable, Sendable {
    /// Upper bound for the padding (a hostile kit must not ask the renderer for a gigantic box).
    public static let maxEm = 10.0
    public static let maxCornerRadius = 10_000.0

    public var color: StyleValue<EffectColor>
    public var horizontalEm: Double
    public var verticalEm: Double
    /// Corner radius in points; nil = fully rounded ends.
    public var cornerRadius: Double?

    public init(color: StyleValue<EffectColor>, horizontalEm: Double = 0.40, verticalEm: Double = 0.16, cornerRadius: Double? = nil) {
        func em(_ v: Double) -> Double { v.isFinite ? min(Self.maxEm, max(0, v)) : 0 }
        self.color = color; self.horizontalEm = em(horizontalEm); self.verticalEm = em(verticalEm)
        self.cornerRadius = cornerRadius.map { $0.isFinite ? min(Self.maxCornerRadius, max(0, $0)) : 0 }
    }

    private enum CodingKeys: String, CodingKey { case color, horizontalEm, verticalEm, cornerRadius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decode(StyleValue<EffectColor>.self, forKey: .color),
                  horizontalEm: try c.decodeIfPresent(Double.self, forKey: .horizontalEm) ?? 0.40,
                  verticalEm: try c.decodeIfPresent(Double.self, forKey: .verticalEm) ?? 0.16,
                  cornerRadius: try c.decodeIfPresent(Double.self, forKey: .cornerRadius))
    }
}

/// The project's caption style: a built-in caption style it starts from plus the fields that follow the brand. Captions with
/// `styleRef == StyleKit.captionStyleRef` are drawn in it.
public struct CaptionStyleSpec: Codable, Hashable, Sendable {
    /// Caption style id (`CaptionPresetLibrary`) the kit style starts from, e.g. "pill" or "default".
    public var baseStyle: String
    /// Caption animation id; nil = the caption pop.
    public var animation: String?
    public var font: StyleValue<String>?
    public var size: Double?
    public var textColor: StyleValue<EffectColor>?
    public var strokeColor: StyleValue<EffectColor>?
    /// Draw the kit's pill behind the words.
    public var usesPill: Bool
    public var allCaps: Bool?
    /// FB-Y: the box the base look brings (pill, bold box) is switched off; without the kit pill no box is drawn. Nil = false.
    public var hidesBackground: Bool?
    /// Everything else the Text panel offers (weight, italic, alignment, spacing, outline width, shadow). Nil = the base look's.
    public var tweaks: CaptionStyleTweaks?

    public init(baseStyle: String, animation: String? = nil, font: StyleValue<String>? = nil, size: Double? = nil,
                textColor: StyleValue<EffectColor>? = nil, strokeColor: StyleValue<EffectColor>? = nil,
                usesPill: Bool = false, allCaps: Bool? = nil, hidesBackground: Bool? = nil, tweaks: CaptionStyleTweaks? = nil) {
        self.baseStyle = baseStyle; self.animation = animation; self.font = font
        self.size = size.map { $0.isFinite ? min(Self.maxSize, max(1, $0)) : Self.maxSize }
        self.textColor = textColor; self.strokeColor = strokeColor; self.usesPill = usesPill; self.allCaps = allCaps
        self.hidesBackground = hidesBackground; self.tweaks = tweaks?.isEmpty == true ? nil : tweaks
    }

    /// Largest caption font size a kit may ask for (points).
    public static let maxSize = 1000.0

    private enum CodingKeys: String, CodingKey {
        case baseStyle, animation, font, size, textColor, strokeColor, usesPill, allCaps, hidesBackground, tweaks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(baseStyle: try c.decode(String.self, forKey: .baseStyle),
                  animation: try c.decodeIfPresent(String.self, forKey: .animation),
                  font: try c.decodeIfPresent(StyleValue<String>.self, forKey: .font),
                  size: try c.decodeIfPresent(Double.self, forKey: .size),
                  textColor: try c.decodeIfPresent(StyleValue<EffectColor>.self, forKey: .textColor),
                  strokeColor: try c.decodeIfPresent(StyleValue<EffectColor>.self, forKey: .strokeColor),
                  usesPill: try c.decodeIfPresent(Bool.self, forKey: .usesPill) ?? false,
                  allCaps: try c.decodeIfPresent(Bool.self, forKey: .allCaps),
                  hidesBackground: try c.decodeIfPresent(Bool.self, forKey: .hidesBackground),
                  tweaks: try c.decodeIfPresent(CaptionStyleTweaks.self, forKey: .tweaks))
    }
}

/// The text settings of the kit caption style beyond font, size, colors and pill (the ones the Text panel also has).
/// Primitives only: SQCore knows no text types; SQText reads the raw values (`FontWeight`, `TextAlignment`, `StrokePosition`).
public struct CaptionStyleTweaks: Codable, Hashable, Sendable {
    public struct Shadow: Codable, Hashable, Sendable {
        public var color: EffectColor
        public var offsetX: Double, offsetY: Double, blur: Double
        /// Light angle remembered while the distance is 0.
        public var restingAngle: Double?
        public init(color: EffectColor, offsetX: Double, offsetY: Double, blur: Double, restingAngle: Double? = nil) {
            self.color = color; self.offsetX = offsetX; self.offsetY = offsetY; self.blur = blur; self.restingAngle = restingAngle
        }
    }

    /// `FontWeight.rawValue`.
    public var weight: Int?
    public var italic: Bool?
    /// `TextAlignment.rawValue`.
    public var alignment: String?
    public var tracking: Double?
    public var lineSpacing: Double?
    public var strokeWidth: Double?
    /// `StrokePosition.rawValue`.
    public var strokePosition: String?
    public var shadow: Shadow?
    /// The base look's shadow is switched off (Shadow unchecked). Nil = false.
    public var hidesShadow: Bool?

    public init(weight: Int? = nil, italic: Bool? = nil, alignment: String? = nil, tracking: Double? = nil, lineSpacing: Double? = nil,
                strokeWidth: Double? = nil, strokePosition: String? = nil, shadow: Shadow? = nil, hidesShadow: Bool? = nil) {
        self.weight = weight; self.italic = italic; self.alignment = alignment; self.tracking = tracking; self.lineSpacing = lineSpacing
        self.strokeWidth = strokeWidth; self.strokePosition = strokePosition; self.shadow = shadow; self.hidesShadow = hidesShadow
    }

    public var isEmpty: Bool { self == CaptionStyleTweaks() }
}

/// FB-Y: where every caption of the project sits. The caption box keeps the safe margins (`SQText.CaptionLayout`); the
/// vertical choice moves the box (and aligns the text in it), the horizontal one aligns the text in the box, the offset
/// moves the box freely by a fraction of the canvas (x right, y down).
public struct CaptionPosition: Codable, Hashable, Sendable {
    public enum Vertical: String, Codable, Sendable, CaseIterable { case top, middle, bottom }
    public enum Horizontal: String, Codable, Sendable, CaseIterable { case left, center, right }

    /// Largest free offset either way (half the canvas).
    public static let maxOffset = 0.5

    public var vertical: Vertical
    public var horizontal: Horizontal
    /// Fraction of the canvas width (positive: right).
    public var offsetX: Double
    /// Fraction of the canvas height (positive: down).
    public var offsetY: Double

    public init(vertical: Vertical = .bottom, horizontal: Horizontal = .center, offsetX: Double = 0, offsetY: Double = 0) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(Self.maxOffset, max(-Self.maxOffset, v)) : 0 }
        self.vertical = vertical; self.horizontal = horizontal; self.offsetX = clamp(offsetX); self.offsetY = clamp(offsetY)
    }

    /// Bottom center, no offset: where captions sat before FB-Y.
    public static let `default` = CaptionPosition()

    private enum CodingKeys: String, CodingKey { case vertical, horizontal, offsetX, offsetY }

    /// Tolerant: an alignment this build does not know (a newer file) falls back to the default instead of failing the kit.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(vertical: (try? c.decodeIfPresent(String.self, forKey: .vertical)).flatMap { $0.flatMap(Vertical.init) } ?? .bottom,
                  horizontal: (try? c.decodeIfPresent(String.self, forKey: .horizontal)).flatMap { $0.flatMap(Horizontal.init) } ?? .center,
                  offsetX: (try? c.decodeIfPresent(Double.self, forKey: .offsetX)).flatMap { $0 } ?? 0,
                  offsetY: (try? c.decodeIfPresent(Double.self, forKey: .offsetY)).flatMap { $0 } ?? 0)
    }
}

/// Duration and curve every new motion effect (Move, Zoom, Pop, Fade, Shake) starts with.
public struct MotionDefaults: Codable, Hashable, Sendable {
    public var duration: Time
    /// `MotionCurve` raw value.
    public var curve: Int

    public init(duration: Time, curve: Int) { self.duration = duration; self.curve = curve }

    /// Writes the defaults into a motion effect with Mode/Duration/Curve (loop animators have none and stay as they are).
    public func apply(to e: inout ClipEffect) {
        guard e.isMotionPreset, e.parameters[ClipEffect.motionDurationKey] != nil else { return }
        e.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(max(0.01, Double(duration.value) / Double(duration.timescale)))
        if MotionCurve(rawValue: curve) != nil { e.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(curve)) }
    }
}

/// A caption look carried by a kit. The payload is owned by SQText (`CaptionLook.payload()`); SQCore keeps it opaque.
public struct StyleKitLook: Codable, Hashable, Sendable {
    public var name: String
    public var payload: Data
    public var payloadVersion: Int

    public init(name: String, payload: Data, payloadVersion: Int) {
        self.name = name; self.payload = payload; self.payloadVersion = payloadVersion
    }
}

/// What `StyleKit.merging` did. Token names are prefixed with their kind ("font:brand", "color:accent").
public struct StyleKitMergeReport: Hashable, Sendable {
    public var addedTokens: [String] = []
    /// Tokens the importer already had with a different value: the importer's value stays.
    public var keptTokens: [String] = []
    /// Ids of the looks added (renamed ids for looks whose id was taken by a different look).
    public var addedLooks: [String] = []
    public var isEmpty: Bool { addedTokens.isEmpty && addedLooks.isEmpty }
}

public struct StyleKit: Codable, Hashable, Sendable {
    /// Caption style ref of the kit caption style (resolved by SQText `CaptionPresetLibrary.applying`).
    public static let captionStyleRef = "kit-caption"
    /// Caption animation ref of the kit caption style.
    public static let captionAnimationRef = "kit-caption"

    public var fonts: [String: String] = [:]
    public var colors: [String: EffectColor] = [:]
    public var pill: StylePill?
    public var caption: CaptionStyleSpec?
    public var motion: MotionDefaults?
    public var looks: [String: StyleKitLook] = [:]
    /// FB-Y: where the project's captions sit; nil = bottom center (`CaptionPosition.default`).
    public var captionPosition: CaptionPosition?

    public init(fonts: [String: String] = [:], colors: [String: EffectColor] = [:], pill: StylePill? = nil,
                caption: CaptionStyleSpec? = nil, motion: MotionDefaults? = nil, looks: [String: StyleKitLook] = [:],
                captionPosition: CaptionPosition? = nil) {
        self.fonts = fonts; self.colors = colors; self.pill = pill; self.caption = caption; self.motion = motion; self.looks = looks
        self.captionPosition = captionPosition
    }

    public func font(_ name: String) -> String? { fonts[name] }
    public func color(_ name: String) -> EffectColor? { colors[name] }

    private enum CodingKeys: String, CodingKey { case fonts, colors, pill, caption, motion, looks, captionPosition }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fonts = try c.decodeIfPresent([String: String].self, forKey: .fonts) ?? [:]
        colors = try c.decodeIfPresent([String: EffectColor].self, forKey: .colors) ?? [:]
        pill = try c.decodeIfPresent(StylePill.self, forKey: .pill)
        caption = try c.decodeIfPresent(CaptionStyleSpec.self, forKey: .caption)
        motion = try c.decodeIfPresent(MotionDefaults.self, forKey: .motion)
        looks = try c.decodeIfPresent([String: StyleKitLook].self, forKey: .looks) ?? [:]
        captionPosition = try c.decodeIfPresent(CaptionPosition.self, forKey: .captionPosition)
    }

    /// Imports `other` into this kit without touching the importer's brand: tokens, pill, caption style and motion defaults
    /// are only added where this kit has none; looks are added, a look whose id is taken by a different look gets a new id
    /// ("pop-2", name "Pop 2"). An imported look that refers to a token the importer already defines draws in the importer's
    /// value (that is the point: the look follows the importer's brand).
    public func merging(_ other: StyleKit) -> (kit: StyleKit, report: StyleKitMergeReport) {
        var k = self, r = StyleKitMergeReport()
        for (name, v) in other.fonts.sorted(by: { $0.key < $1.key }) {
            if let mine = k.fonts[name] { if mine != v { r.keptTokens.append("font:\(name)") } } else {
                k.fonts[name] = v; r.addedTokens.append("font:\(name)")
            }
        }
        for (name, v) in other.colors.sorted(by: { $0.key < $1.key }) {
            if let mine = k.colors[name] { if mine != v { r.keptTokens.append("color:\(name)") } } else {
                k.colors[name] = v; r.addedTokens.append("color:\(name)")
            }
        }
        if k.pill == nil, let p = other.pill { k.pill = p; r.addedTokens.append("pill") }
        if k.caption == nil, let c = other.caption { k.caption = c; r.addedTokens.append("caption") }
        if k.motion == nil, let m = other.motion { k.motion = m; r.addedTokens.append("motion") }
        if k.captionPosition == nil, let p = other.captionPosition { k.captionPosition = p; r.addedTokens.append("captionPosition") }
        for (id, look) in other.looks.sorted(by: { $0.key < $1.key }) {
            guard let mine = k.looks[id] else { k.looks[id] = look; r.addedLooks.append(id); continue }
            guard mine != look, !k.looks.values.contains(look) else { continue }
            var n = 2
            while k.looks["\(id)-\(n)"] != nil { n += 1 }
            var renamed = look
            renamed.name = "\(look.name) \(n)"
            k.looks["\(id)-\(n)"] = renamed
            r.addedLooks.append("\(id)-\(n)")
        }
        return (k, r)
    }
}

/// `.sqstyle`: a style kit on its own (JSON `{formatVersion, kit}`), for moving a brand between projects.
public enum StyleKitFile {
    public static let fileExtension = "sqstyle"
    /// The newest version this build reads. 2 = a Look payload newer than the caption look (`StyleKit.captionLookPayloadVersion`)
    /// is inside: a build that only knows version 1 would drop such a Look silently, so it has to refuse the file.
    public static let formatVersion = 2

    /// The lowest version that holds `kit`: files without a newer Look payload stay version 1, readable by every build.
    public static func writtenVersion(for kit: StyleKit) -> Int {
        kit.looks.values.contains { $0.payloadVersion > StyleKit.captionLookPayloadVersion } ? 2 : 1
    }

    /// A kit is a few KB; anything larger is not read (hostile or wrong file).
    public static let maxFileSize = 5 * 1024 * 1024

    public enum FileError: Error, Equatable, Sendable {
        case corrupt
        case tooLarge
        case newerVersion(found: Int, supported: Int)
    }

    private struct Envelope: Codable { var formatVersion: Int; var kit: StyleKit }

    public static func encode(_ kit: StyleKit) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(Envelope(formatVersion: writtenVersion(for: kit), kit: kit))
    }

    public static func decode(_ data: Data) throws -> StyleKit {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = obj["formatVersion"] as? Int else { throw FileError.corrupt }
        if version > formatVersion { throw FileError.newerVersion(found: version, supported: formatVersion) }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { throw FileError.corrupt }
        return env.kit
    }

    public static func write(_ kit: StyleKit, to url: URL) throws {
        try encode(kit).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> StyleKit {
        if let size = FileWalk.Values.read(url, keys: [.fileSizeKey])?.fileSize, size > maxFileSize { throw FileError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw FileError.corrupt }
        guard data.count <= maxFileSize else { throw FileError.tooLarge }
        return try decode(data)
    }
}

extension Clip {
    /// `addEffect(kind:defaults:)` (the user default, FB-W), then the kit's motion defaults on a new motion effect.
    @discardableResult
    public mutating func addEffect(kind: String, motionDefaults: MotionDefaults?, defaults: EffectDefaults? = nil) -> ClipEffect.ID? {
        guard let id = addEffect(kind: kind, defaults: defaults) else { return nil }
        if let m = motionDefaults, let i = effects.firstIndex(where: { $0.id == id }) { m.apply(to: &effects[i]) }
        return id
    }
}

extension Project {
    /// Value rewrite of generator payloads in every sequence (timing and track locks untouched: the brand follows
    /// everywhere). `f` returns the new ref, or nil to keep the clip. Returns how many clips changed.
    @discardableResult
    public mutating func rewriteGenerators(_ f: (GeneratorRef) -> GeneratorRef?) -> Int {
        var changed = 0
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                timelines[ti].tracks[tr].mapClipsKeepingTiming { c in
                    var out = c, touched = false
                    if let g = c.generator, let new = f(g), new != g { out.generator = new; touched = true }
                    // Variant generator overrides (a text clip's own box per format) follow the kit too.
                    var overrides = c.variantOverrides
                    for (vid, o) in overrides {
                        guard let g = o.generator, let new = f(g), new != g else { continue }
                        overrides[vid]?.generator = new
                        touched = true
                    }
                    if overrides != c.variantOverrides { out.variantOverrides = overrides }
                    // Text layers of a graphics clip follow the kit too.
                    if var doc = c.graphics {
                        var docTouched = false
                        for i in doc.layers.indices {
                            guard case .text(let g) = doc.layers[i].content, let new = f(g), new != g else { continue }
                            doc.layers[i].content = .text(ref: new)
                            docTouched = true
                        }
                        if docTouched { out.graphics = doc; touched = true }
                    }
                    if touched { changed += 1 }
                    return out
                }
            }
        }
        return changed
    }
}
