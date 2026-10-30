import Foundation
import Testing
@testable import SQCore

// Enhance Speech: one audio effect (Amount + Preset) that drives the existing repair stages as one recipe.

@Suite struct EnhanceSpeechEffectTests {
    private func audioClip() -> Clip {
        Clip(name: "A", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
             mediaDuration: Time(2, 1))
    }

    @Test func specHasAmountAndPreset() throws {
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.audioEnhanceSpeechKind))
        #expect(spec.title == "Enhance Speech")
        #expect(spec.params.map(\.key) == [ClipEffect.enhanceAmountKey, ClipEffect.enhancePresetKey])
        let amount = spec.params[0]
        #expect(amount.range == 0...100 && amount.defaultValue == 70)
        #expect(EffectCatalog.audio.contains { $0.kind == ClipEffect.audioEnhanceSpeechKind })
        #expect(ClipEffect.isAudioKind(ClipEffect.audioEnhanceSpeechKind))
    }

    @Test func stageDefaultsAndClamping() throws {
        var a = audioClip()
        let added = a.addEffect(kind: ClipEffect.audioEnhanceSpeechKind)
        let id = try #require(added)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .enhanceSpeech(AudioEnhanceSpeechValues(amount: 0.7, preset: 0)))
        a.setParameter(id, ClipEffect.enhanceAmountKey, to: 400)
        a.setParameter(id, ClipEffect.enhancePresetKey, to: 2)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .enhanceSpeech(AudioEnhanceSpeechValues(amount: 1, preset: 2)))
    }

    @Test func recipeScalesWithAmountAndZeroIsNeutral() {
        for p in AudioEnhanceSpeechValues.presetTitles.indices {
            let zero = AudioEnhanceSpeechValues(amount: 0, preset: p).recipe
            #expect(zero.denoise == 0 && zero.dereverb == 0 && zero.leveling == 0)
            #expect(zero.mudDB == 0 && zero.presenceDB == 0 && zero.airDB == 0)
            #expect(zero.lowCutHz <= AudioEnhanceSpeechValues.neutralLowCutHz)
            let half = AudioEnhanceSpeechValues(amount: 0.5, preset: p).recipe
            let full = AudioEnhanceSpeechValues(amount: 1, preset: p).recipe
            #expect(full.denoise > half.denoise && half.denoise > 0 && full.denoise <= 1)
            #expect(full.dereverb >= half.dereverb && full.dereverb <= 1)
            #expect(full.presenceDB > half.presenceDB && full.mudDB < half.mudDB)
            #expect(full.lowCutHz > half.lowCutHz && full.lowCutHz <= 120)
        }
        // Presets differ where their names say: Noisy leans on the denoiser, Echoey Room on De-Reverb.
        let balanced = AudioEnhanceSpeechValues(amount: 1, preset: 0).recipe
        let noisy = AudioEnhanceSpeechValues(amount: 1, preset: 1).recipe
        let echo = AudioEnhanceSpeechValues(amount: 1, preset: 2).recipe
        #expect(noisy.denoise >= balanced.denoise && echo.dereverb > balanced.dereverb)
        // Out-of-range preset index falls back to Balanced.
        #expect(AudioEnhanceSpeechValues(amount: 1, preset: 99).recipe == balanced)
    }

    @Test func latencyIsDenoiserPlusDeReverb() {
        #expect(AudioEnhanceSpeechValues.latencySamples == 480 + AudioDeReverbValues.latencySamples)
    }
}
