import Foundation

/// One-click starting points for the chroma key: apply, then tune Tolerance and Shrink / Grow with Output set to Alpha.
/// Values follow Premiere's documented Ultra Key defaults and usage ranges where our controls have the same meaning
/// (Black level 10, Shrink under 25, Soften under 20 in Premiere's units); Keep Highlights / Keep Shadows are our own
/// controls, so their values are a tuned starting point (the design notes).
public enum KeyingPresets {
    static func screen(hue: Double) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.ultraKeyKind)!
        let v: [String: Double] = [
            ClipEffect.keyHueKey: hue,
            ClipEffect.toleranceKey: 45,
            ClipEffect.softenKey: 20,
            ClipEffect.keyHighlightKey: 10,
            ClipEffect.keyShadowKey: 20,
            ClipEffect.pedestalKey: 10,
            ClipEffect.chokeKey: 15,
            ClipEffect.keyContrastKey: 20,
            ClipEffect.keyMidpointKey: 50,
            ClipEffect.spillKey: 60,
            ClipEffect.spillRangeKey: 60,
        ]
        for (k, x) in v { e.parameters[k] = AnimatedProperty(x) }
        return e
    }

    public static let builtIns: [EffectStackPreset] = [
        EffectStackPreset(id: "greenScreen", name: "Green Screen", bin: .keying, effects: [screen(hue: 125)]),
        EffectStackPreset(id: "blueScreen", name: "Blue Screen", bin: .keying, effects: [screen(hue: 225)]),
    ]
}
