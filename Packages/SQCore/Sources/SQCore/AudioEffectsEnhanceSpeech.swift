import Foundation

// Enhance Speech: one-click dialogue clean-up (Premiere "Enhance Speech", Resolve "Voice Isolation" behavior) built on the
// existing repair stages, not a second noise reduction: Low Cut -> Noise Reduction (RNNoise) -> De-Reverb -> dialogue EQ
// (mud cut, presence, air) -> Dialogue Leveler, all driven by one Amount and a Preset. Stored strings: never rename.

extension ClipEffect {
    public static let audioEnhanceSpeechKind = "audio.enhanceSpeech"
    public static let enhanceAmountKey = "amount", enhancePresetKey = "preset"
}

extension EffectCatalog {
    /// Amount default 70 % (Premiere's Enhance Speech mix also defaults below 100 %; the exact value is ours, unsourced).
    static let enhanceSpeechSpec = EffectSpec(kind: ClipEffect.audioEnhanceSpeechKind, title: "Enhance Speech", params: [
        EffectParamSpec(key: ClipEffect.enhanceAmountKey, title: "Amount", unit: "%", defaultValue: 70, range: 0...100, step: 1, decimals: 0),
        .choice(ClipEffect.enhancePresetKey, "Preset", AudioEnhanceSpeechValues.presetTitles, default: 0),
    ])
}

/// Enhance Speech at one instant: amount 0...1, preset index (`presetTitles`).
public struct AudioEnhanceSpeechValues: Sendable, Hashable {
    /// Stored as the choice index: never reorder.
    public static let presetTitles = ["Balanced", "Noisy Location", "Echoey Room", "Light Touch"]
    /// Low Cut corner at Amount 0 (below speech and nearly every playback system: practically transparent).
    public static let neutralLowCutHz = 20.0
    /// RNNoise frame (480) + De-Reverb window: the stage delays the sound by exactly this, also while off or at 0 %.
    public static let latencySamples = 480 + AudioDeReverbValues.latencySamples
    /// Dialogue Leveler preset the recipe rides with ("Optimize moderate levels").
    public static let levelerPreset = 3

    public var amount: Double
    public var preset: Int
    public init(amount: Double, preset: Int) { self.amount = amount; self.preset = preset }

    /// What each stage gets. Denoise / dereverb / leveling 0...1, EQ gains in dB, decay in seconds.
    public struct Recipe: Sendable, Hashable {
        public var lowCutHz: Double
        public var denoise: Double
        public var dereverb: Double
        public var decaySeconds: Double
        /// Peak at `mudHz` (cut), peak at `presenceHz` (boost), wide peak at `airHz` (boost).
        public var mudDB: Double, presenceDB: Double, airDB: Double
        /// 0 = leveler off, 1 = its full gain ride.
        public var leveling: Double
        public static let mudHz = 300.0, presenceHz = 3_500.0, airHz = 10_000.0
        public static let mudQ = 1.0, presenceQ = 0.9, airQ = 0.7
    }

    /// The preset at full amount. Numbers are ours (tuned on synthetic voice + noise, by ear later): unsourced.
    static func full(_ preset: Int) -> Recipe {
        switch preset {
        case 1: Recipe(lowCutHz: 110, denoise: 1, dereverb: 0.3, decaySeconds: 0.5, mudDB: -2, presenceDB: 3.5, airDB: 1, leveling: 1)
        case 2: Recipe(lowCutHz: 90, denoise: 0.7, dereverb: 0.9, decaySeconds: 1, mudDB: -3.5, presenceDB: 3, airDB: 1.5, leveling: 1)
        case 3: Recipe(lowCutHz: 75, denoise: 0.5, dereverb: 0.2, decaySeconds: 0.6, mudDB: -1, presenceDB: 1.5, airDB: 1, leveling: 0.6)
        default: Recipe(lowCutHz: 90, denoise: 0.85, dereverb: 0.45, decaySeconds: 0.6, mudDB: -2.5, presenceDB: 3, airDB: 2, leveling: 1)
        }
    }

    /// The recipe scaled by `amount` (0 = every stage neutral).
    public var recipe: Recipe {
        let a = min(1, max(0, amount)), f = Self.full(preset)
        return Recipe(lowCutHz: Self.neutralLowCutHz + (f.lowCutHz - Self.neutralLowCutHz) * a,
                      denoise: f.denoise * a, dereverb: f.dereverb * a, decaySeconds: f.decaySeconds,
                      mudDB: f.mudDB * a, presenceDB: f.presenceDB * a, airDB: f.airDB * a, leveling: f.leveling * a)
    }
}
