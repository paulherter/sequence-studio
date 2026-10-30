import Foundation
import Testing
@testable import SQCore

/// AUDIT G13: a freshly applied Blur / Sharpen / Spherize shows a visible value, Stereo Width starts neutral. Only new
/// instances change; the catalog default (Reset, stored files, internal effects) stays.
@Suite struct AppliedStartValuesTests {
    private func video() -> Clip {
        Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    @Test func appliedEffectsStartVisible() {
        var c = video()
        let b = c.addEffect(kind: ClipEffect.gaussianBlurKind)!, s = c.addEffect(kind: ClipEffect.sharpenKind)!
        let sp = c.addEffect(kind: ClipEffect.spherizeKind)!
        func p(_ id: ClipEffect.ID, _ k: String) -> Double? { c.effects.first { $0.id == id }?.parameters[k]?.value }
        #expect(p(b, ClipEffect.blurrinessKey) == 20)
        #expect(p(s, ClipEffect.sharpenAmountKey) == 50)
        #expect(p(sp, ClipEffect.spherizeRadiusKey) == 400)
    }

    @Test func stereoWidthStartsAtOneHundredPercent() {
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let id = a.addEffect(kind: ClipEffect.audioStereoWidthKind)!
        #expect(a.effects.first { $0.id == id }?.parameters[ClipEffect.stereoWidthKey]?.value == 100)
    }

    @Test func catalogDefaultsAndInternalEffectsStayTheSame() {
        #expect(ClipEffect.defaultParameters(for: ClipEffect.gaussianBlurKind)[ClipEffect.blurrinessKey]?.value == 0)
        #expect(ClipEffect.defaultParameters(for: ClipEffect.sharpenKind)[ClipEffect.sharpenAmountKey]?.value == 0)
        #expect(ClipEffect.defaultParameters(for: ClipEffect.audioStereoWidthKind)[ClipEffect.stereoWidthKey]?.value == 150)
        #expect(ClipEffect.make(kind: ClipEffect.gaussianBlurKind)?.parameters[ClipEffect.blurrinessKey]?.value == 0)
    }

    @Test func userDefaultOfTheKindWins() {
        var d = EffectDefaults()
        var e = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        e.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(7)
        let stored = d.setDefault(from: e, keepKeyframes: true, at: .zero)
        #expect(stored)
        var c = video()
        let id = c.addEffect(kind: ClipEffect.gaussianBlurKind, defaults: d)!
        #expect(c.effects.first { $0.id == id }?.parameters[ClipEffect.blurrinessKey]?.value == 7)
    }
}
