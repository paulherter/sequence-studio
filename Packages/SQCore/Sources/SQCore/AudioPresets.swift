import Foundation

/// One-click audio stacks: `EffectStackPreset`s of the `.voice` bin. Applying one adds an instance of each audio effect, in
/// order, to the audio clip (one undo step). The instances are ordinary effects afterwards.
public enum AudioPresets {
    /// Starts with `audio.` like every audio effect id, so the Effects panel, drops and Quick Apply send it to audio clips.
    public static let voiceID = "audio.preset.voice"

    /// Dialogue chain: 80 Hz Low Cut first (rumble and plosive thump out before anything reacts to it), then noise reduction,
    /// de-esser and compressor, and a -3 dB limiter last so a hot sentence never goes past -3 dBFS.
    public static let voice = EffectStackPreset(id: voiceID, name: "Voice", bin: .voice, effects: [
        EffectStackPreset.effect(ClipEffect.audioLowCutKind, [ClipEffect.lowCutFreqKey: 80]),
        EffectStackPreset.effect(ClipEffect.audioNoiseReductionKind, [ClipEffect.noiseAmountReductionKey: 60]),
        EffectStackPreset.effect(ClipEffect.audioDeEsserKind, [ClipEffect.deEssReductionKey: 8]),
        EffectStackPreset.effect(ClipEffect.audioCompressorKind, [ClipEffect.compThresholdKey: -22, ClipEffect.compRatioKey: 3, ClipEffect.compMakeupKey: 3]),
        EffectStackPreset.effect(ClipEffect.audioLimiterKind, [ClipEffect.limiterCeilingKey: -3]),
    ])

    public static let rodeNTGIndoorID = "audio.preset.rodeNTGIndoor"

    /// Shotgun mic recorded indoors (the maintainer's Rode NTG chain): noise reduction, then a four-band Multiband that tames the room
    /// (thresholds -15/-11/-17/-15 dB, ratios 3/2/2/3, attack 1 ms, release 100 ms, bands +4/-2/-4/-2 dB, crossovers
    /// 137 / 1147 / 6910 Hz). Same values the Premiere preset import maps.
    public static let rodeNTGIndoor: EffectStackPreset = {
        var mb: [String: Double] = [ClipEffect.mbOutputGainKey: 0]
        let thr = [-15.0, -11, -17, -15], ratio = [3.0, 2, 2, 3], gain = [4.0, -2, -4, -2]
        for i in 1...4 {
            mb[ClipEffect.mbThresholdKey(i)] = thr[i - 1]
            mb[ClipEffect.mbRatioKey(i)] = ratio[i - 1]
            mb[ClipEffect.mbAttackKey(i)] = 1
            mb[ClipEffect.mbReleaseKey(i)] = 100
            mb[ClipEffect.mbGainKey(i)] = gain[i - 1]
        }
        mb[ClipEffect.mbCrossoverKey(1)] = 137
        mb[ClipEffect.mbCrossoverKey(2)] = 1147
        mb[ClipEffect.mbCrossoverKey(3)] = 6910
        return EffectStackPreset(id: rodeNTGIndoorID, name: "Rode NTG Indoor", bin: .voice, effects: [
            EffectStackPreset.effect(ClipEffect.audioNoiseReductionKind, [ClipEffect.noiseAmountReductionKey: 60]),
            EffectStackPreset.effect(ClipEffect.audioMultibandKind, mb),
        ])
    }()

    public static let all: [EffectStackPreset] = [voice, rodeNTGIndoor]
    public static func preset(id: String) -> EffectStackPreset? { all.first { $0.id == id } }
    public static func isPresetID(_ id: String) -> Bool { all.contains { $0.id == id } }
}
