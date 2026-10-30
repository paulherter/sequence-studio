import Foundation

/// Film and tape looks: `EffectStackPreset`s of the `.looks` bin. Applying one adds an instance of each effect, in order,
/// to the clip (one undo step); the instances are ordinary effects afterwards.
public enum FilmPresets {
    public static let idPrefix = "preset."
    static func fx(_ kind: String, _ values: [String: Double] = [:], colors: [String: EffectColor] = [:]) -> ClipEffect {
        EffectStackPreset.effect(kind, values, colors: colors)
    }
    /// Film halation: the red-orange glow around bright parts.
    static let halationColor = EffectColor(red: 1, green: 0.45, blue: 0.2)

    // Gaussian Blur comes first: the look pass always runs after every other effect, so the order only matters for blur
    // against crop / key, and a softened picture is what the tape and TV looks start from.
    public static let all: [EffectStackPreset] = [
        EffectStackPreset(id: idPrefix + "filmLook", name: "Film Look", bin: .looks, effects: [
            // Halation: a red-orange Glow of the bright parts (Glow is also the Bloom; one glow keeps the preset cheap).
            fx(ClipEffect.glowKind, [ClipEffect.glowThresholdKey: 60, ClipEffect.glowRadiusKey: 56, ClipEffect.glowIntensityKey: 0.6,
                                     ClipEffect.glowColorsKey: 1], colors: [ClipEffect.glowColorKey: halationColor]),
            fx(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 28, ClipEffect.grainSizeKey: 1.4]),
            fx(ClipEffect.gateWeaveKind, [ClipEffect.amountKey: 2, ClipEffect.rotationKey: 0.1]),
        ]),
        EffectStackPreset(id: idPrefix + "vhs", name: "VHS", bin: .looks, effects: [
            fx(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 0.8]),
            fx(ClipEffect.chromaBleedKind, [ClipEffect.bleedKey: 8, ClipEffect.shiftKey: 3]),
            fx(ClipEffect.scanlinesKind, [ClipEffect.intensityKey: 18, ClipEffect.spacingKey: 3]),
            fx(ClipEffect.trackingNoiseKind, [ClipEffect.amountKey: 35, ClipEffect.bandHeightKey: 10]),
            fx(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 20, ClipEffect.grainSizeKey: 2,
                                      ClipEffect.grainSoftnessKey: 20, ClipEffect.grainResponseKey: 30]),
        ]),
        EffectStackPreset(id: idPrefix + "badTV", name: "Bad TV", bin: .looks, effects: [
            fx(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 1.2]),
            fx(ClipEffect.chromaBleedKind, [ClipEffect.bleedKey: 4, ClipEffect.shiftKey: 1]),
            fx(ClipEffect.scanlinesKind, [ClipEffect.intensityKey: 45, ClipEffect.spacingKey: 4, ClipEffect.thicknessKey: 55]),
            fx(ClipEffect.trackingNoiseKind, [ClipEffect.amountKey: 60, ClipEffect.bandHeightKey: 18, ClipEffect.speedKey: 0.7]),
            fx(ClipEffect.glowKind, [ClipEffect.glowThresholdKey: 50, ClipEffect.glowRadiusKey: 24, ClipEffect.glowIntensityKey: 0.45]),
            fx(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 45, ClipEffect.grainSizeKey: 2.2,
                                      ClipEffect.grainSoftnessKey: 15, ClipEffect.grainResponseKey: 20]),
        ]),
    ]

    public static func preset(id: String) -> EffectStackPreset? { all.first { $0.id == id } }
    public static func isPresetID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }
}
