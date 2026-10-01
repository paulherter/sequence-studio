import Foundation

/// An effect explicitly applied to a clip (v9). Absent from `Clip.effects` = not applied: Effect Controls shows no
/// section for it and the renderer ignores it. Parameters are animatable, clip-local like `ClipAnimation`.
public struct ClipEffect: Sendable, Hashable, Codable, Identifiable {
    public static let roundedCornersKind = "roundedCorners"
    public static let radiusKey = "radius"
    public static let cropKind = "crop"
    public static let cropLeftKey = "left", cropTopKey = "top", cropRightKey = "right", cropBottomKey = "bottom"
    public static let gaussianBlurKind = "gaussianBlur"
    public static let blurrinessKey = "blurriness"
    public static let ultraKeyKind = "ultraKey"
    public static let keyHueKey = "keyHue", toleranceKey = "tolerance", softenKey = "soften", spillKey = "spill"

    public var id: UUID
    public var kind: String
    /// fx toggle: a disabled effect stays applied (and keeps its values) but renders as if absent.
    public var enabled: Bool
    public var parameters: [String: AnimatedProperty<Double>]

    public init(id: UUID = UUID(), kind: String, enabled: Bool = true,
                parameters: [String: AnimatedProperty<Double>] = [:]) {
        self.id = id; self.kind = kind; self.enabled = enabled; self.parameters = parameters
    }

    /// Radius in sequence pixels of the clip's own frame; 0 = square.
    public static func roundedCorners(radius: Double = 24) -> ClipEffect {
        ClipEffect(kind: roundedCornersKind, parameters: [radiusKey: AnimatedProperty(radius)])
    }

    /// Parameter values an effect starts with (what "Reset" restores).
    public static func defaultParameters(for kind: String) -> [String: AnimatedProperty<Double>] {
        var out: [String: AnimatedProperty<Double>] = [:]
        for p in EffectCatalog.spec(for: kind)?.params ?? [] { out[p.key] = AnimatedProperty(p.defaultValue) }
        return out
    }

    /// A new instance of `kind` with its default values; nil for an unknown kind.
    public static func make(kind: String) -> ClipEffect? {
        EffectCatalog.spec(for: kind) == nil ? nil : ClipEffect(kind: kind, parameters: defaultParameters(for: kind))
    }

    func remapped(_ f: (Time) -> Time) -> ClipEffect {
        var e = self
        e.parameters = parameters.mapValues { $0.remapped(f) }
        return e
    }

    func shifted(by delta: Time) -> ClipEffect {
        var e = self
        e.parameters = parameters.mapValues { $0.shifted(by: delta) }
        return e
    }
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
