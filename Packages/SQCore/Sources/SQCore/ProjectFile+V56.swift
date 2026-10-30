import Foundation

// v56: one gate for everything added to the file after the v55 gates, none of which had one. A build that predates any of
// them would list an unknown effect kind as inert (or ignore the option) and drop it on the next save; at v56 it refuses
// the file with `ProjectFileError.newerVersion` ("made with a newer version") instead.

extension ClipEffect {
    /// Effect kinds introduced after the v51 gradient gate, none gated before v56.
    static let v56Kinds: Set<String> = [
        dynamicZoomKind, dateStampKind, posterizeTimeKind, videoDenoiseKind, deflickerKind, motionBlurKind,
        lumaKeyKind, gateWeaveKind, scanlinesKind, chromaBleedKind, trackingNoiseKind,
        audioDeReverbKind, audioDeHumKind, audioLowCutKind, audioDialogueLevelerKind, audioEnhanceSpeechKind,
    ]

    /// This effect needs a v56 build: a v56 kind, or an option a v55 build does not know set away from its default
    /// (the De-Esser's Frequency / Range / Reaction / Listen, the Crop's soft edge). Defaults sound and look as before.
    var needsV56: Bool {
        if Self.v56Kinds.contains(kind) { return true }
        func changed(_ key: String, from def: Double) -> Bool {
            guard let p = parameters[key] else { return false }
            return p.isAnimated || p.value != def
        }
        switch kind {
        case Self.audioDeEsserKind:
            return changed(Self.deEssFrequencyKey, from: 7_000) || changed(Self.deEssRangeKey, from: 1)
                || changed(Self.deEssSpeedKey, from: 1) || changed(Self.deEssListenKey, from: 0)
        case Self.cropKind:
            return changed(Self.cropSoftnessKey, from: 0)
        default:
            return false
        }
    }
}

extension Project {
    /// Any clip (or graphics layer) holds a v56 effect, or the project's live ducking has non-classic timing: the file must be v56.
    public var containsV56Content: Bool {
        if let t = liveDucking?.timing, t != .classic { return true }
        return allClips().contains { c in
            c.effects.contains(where: \.needsV56)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV56) } ?? false)
        }
    }
}
