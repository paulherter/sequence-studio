import Foundation
import Testing
@testable import SQCore

// Consolidation round 1 (DECISIONS 2026-10-07): hidden = not listed, still resolved, applied and rendered.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ effects: [ClipEffect], kind: TrackKind = .video) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(5)), start: s(0))
    c.effects = effects
    return c
}

@Suite struct HiddenCatalogTests {
    @Test func hiddenEffectsAreNotOfferedButStillResolve() throws {
        let video = EffectCatalog.offeredVideo(hiding: true), audio = EffectCatalog.offeredAudio(hiding: true)
        for k in HiddenCatalog.effectKinds {
            #expect(!video.contains { $0.kind == k } && !audio.contains { $0.kind == k }, "\(k) offered")
            let spec = try #require(EffectCatalog.spec(for: k), "\(k) must still resolve")
            #expect(!EffectCatalog.title(for: k).isEmpty && ClipEffect.make(kind: k) != nil)
            #expect(spec.params.allSatisfy { EffectCatalog.param(k, $0.key) != nil })
        }
        // The canonical ones stay offered.
        for k in [ClipEffect.colorKind, ClipEffect.grainKind] { #expect(video.contains { $0.kind == k }) }
        for k in [ClipEffect.audioParametricEQKind, ClipEffect.audioLowCutKind, ClipEffect.audioHighCutKind] {
            #expect(audio.contains { $0.kind == k })
        }
    }

    @Test func aStoredHiddenEffectStillRenders() throws {
        func fx(_ kind: String, _ v: [String: Double] = [:]) -> ClipEffect {
            var e = ClipEffect.make(kind: kind)!
            for (k, x) in v { e.parameters[k] = AnimatedProperty(x) }
            return e
        }
        let stack = [fx(ClipEffect.vignetteKind), fx(ClipEffect.brightnessContrastKind, [ClipEffect.brightnessKey: 20]),
                     fx(ClipEffect.blackAndWhiteKind), fx(ClipEffect.noiseKind, [ClipEffect.noiseAmountKey: 50])]
        let c = clip(stack)
        // One project round trip: the stack comes back and evaluates to the same filters.
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.effects == stack)
        let before = c.effects(at: s(1)), after = back.effects(at: s(1))
        #expect(before == after && before != .none)
        for e in stack { #expect(clip([e]).effects(at: s(1)) != .none, "\(e.kind)") }
        // Audio: Gain and the 3-band EQ stay known to a clip that holds them.
        let audio = clip([fx(ClipEffect.audioGainKind), fx(ClipEffect.audioEQKind)], kind: .audio)
        #expect(audio.effects.count == 2 && audio.effects.allSatisfy { EffectCatalog.spec(for: $0.kind) != nil })
    }
}
