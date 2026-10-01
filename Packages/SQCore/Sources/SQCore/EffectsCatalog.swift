import Foundation

/// One animatable parameter of an applied effect (what Effect Controls shows as a row).
public struct EffectParamSpec: Sendable, Hashable {
    public var key: String
    public var title: String
    public var unit: String
    public var defaultValue: Double
    public var range: ClosedRange<Double>
    public var step: Double
    public var decimals: Int
}

/// An effect the Effects panel can apply. Kinds are the strings stored in `ClipEffect.kind`.
public struct EffectSpec: Sendable, Hashable {
    public var kind: String
    public var title: String
    public var params: [EffectParamSpec]
}

public enum EffectCatalog {
    public static let all: [EffectSpec] = [
        EffectSpec(kind: ClipEffect.roundedCornersKind, title: "Rounded Corners", params: [
            EffectParamSpec(key: ClipEffect.radiusKey, title: "Radius", unit: "px", defaultValue: 24,
                            range: 0...10_000, step: 1, decimals: 0),
        ]),
        EffectSpec(kind: ClipEffect.cropKind, title: "Crop", params: [
            EffectParamSpec(key: ClipEffect.cropLeftKey, title: "Left", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1),
            EffectParamSpec(key: ClipEffect.cropTopKey, title: "Top", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1),
            EffectParamSpec(key: ClipEffect.cropRightKey, title: "Right", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1),
            EffectParamSpec(key: ClipEffect.cropBottomKey, title: "Bottom", unit: "%", defaultValue: 0, range: 0...100, step: 0.5, decimals: 1),
        ]),
        EffectSpec(kind: ClipEffect.gaussianBlurKind, title: "Gaussian Blur", params: [
            EffectParamSpec(key: ClipEffect.blurrinessKey, title: "Blurriness", unit: "", defaultValue: 0,
                            range: 0...1_000, step: 0.5, decimals: 1),
        ]),
        // A compact chroma key: pick the hue to remove (green 120, blue 220), how far around it, how soft, and how much of the
        // coloured spill on the edges to desaturate. Premiere's Ultra Key has more controls; these four do the everyday job.
        EffectSpec(kind: ClipEffect.ultraKeyKind, title: "Ultra Key", params: [
            EffectParamSpec(key: ClipEffect.keyHueKey, title: "Key Hue", unit: "\u{00B0}", defaultValue: 120, range: 0...360, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.toleranceKey, title: "Tolerance", unit: "%", defaultValue: 40, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.softenKey, title: "Soften", unit: "%", defaultValue: 20, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.spillKey, title: "Spill Suppression", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
        ]),
    ]

    public static func spec(for kind: String) -> EffectSpec? { all.first { $0.kind == kind } }
    public static func title(for kind: String) -> String { spec(for: kind)?.title ?? kind }
    public static func param(_ kind: String, _ key: String) -> EffectParamSpec? {
        spec(for: kind)?.params.first { $0.key == key }
    }
}
