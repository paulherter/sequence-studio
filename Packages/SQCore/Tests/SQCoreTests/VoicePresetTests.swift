import Foundation
import Testing
@testable import SQCore

@Suite struct VoicePresetTests {
    private func audioClip() -> Clip {
        Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
    }

    @Test func chainStartsWithTheLowCutAndEndsWithTheMinusThreeLimiter() throws {
        let p = try #require(AudioPresets.preset(id: AudioPresets.voiceID))
        #expect(p.bin == .voice && p.trackKind == .audio)
        #expect(p.effects.first?.kind == ClipEffect.audioLowCutKind)
        #expect(p.effects.first?.parameters[ClipEffect.lowCutFreqKey]?.value == 80)
        #expect(p.effects.last?.kind == ClipEffect.audioLimiterKind)
        #expect(p.effects.last?.parameters[ClipEffect.limiterCeilingKey]?.value == -3)
    }

    @Test func applyingAddsTheChainInOrderToAnAudioClip() {
        var c = audioClip()
        c.applyPreset(AudioPresets.voice.preset)
        #expect(c.effects.map(\.kind) == AudioPresets.voice.effects.map(\.kind))
        let steps = c.audioFXSteps(atLocal: .zero)
        #expect(steps.first?.stage == .lowCut(frequencyHz: 80, order: 2))
        if case .limiter(_, let ceiling)? = steps.last?.stage { #expect(ceiling == -3) } else { Issue.record("no limiter last") }
    }

    @Test func rodeNTGIndoorIsNoiseReductionThenMultiband() throws {
        let p = try #require(AudioPresets.preset(id: AudioPresets.rodeNTGIndoorID))
        #expect(p.effects.map(\.kind) == [ClipEffect.audioNoiseReductionKind, ClipEffect.audioMultibandKind])
        let mb = p.effects[1]
        #expect(mb.parameters[ClipEffect.mbThresholdKey(3)]?.value == -17)
        #expect(mb.parameters[ClipEffect.mbCrossoverKey(2)]?.value == 1147)
        #expect(mb.parameters[ClipEffect.mbGainKey(1)]?.value == 4)
        var c = audioClip()
        c.applyPreset(p.preset)
        #expect(c.effects.count == 2)
    }

    @Test func idsAreAudioIdsWithoutAnEffectSpec() {
        #expect(AudioPresets.all.allSatisfy { FilmPresets.preset(id: $0.id) == nil && ClipEffect.isAudioKind($0.id) && EffectCatalog.spec(for: $0.id) == nil })
    }
}
