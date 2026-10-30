import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64, _ d: Int64 = 1) -> Time { Time(n, d) }

private func clip(_ kinds: [(String, [String: Double])]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
    for (k, v) in kinds {
        let id = c.addEffect(kind: k)!
        for (key, val) in v { c.setParameter(id, key, to: val) }
    }
    return c
}

@Suite struct FilmLookTests {
    @Test func everyLookEffectIsInTheCatalogWithDefaultsInRange() {
        for k in [ClipEffect.grainKind, ClipEffect.gateWeaveKind,
                  ClipEffect.scanlinesKind, ClipEffect.chromaBleedKind, ClipEffect.trackingNoiseKind, ClipEffect.agedFilmKind] {
            let spec = EffectCatalog.spec(for: k)
            #expect(spec != nil, "\(k)")
            for p in spec?.params ?? [] { #expect(p.range.contains(p.defaultValue), "\(k).\(p.key)") }
            #expect(!(spec?.params.isEmpty ?? true))
        }
    }

    @Test func defaultsEvaluateToAVisibleLook() {
        let e = clip([(ClipEffect.grainKind, [:]),
                      (ClipEffect.scanlinesKind, [:]), (ClipEffect.chromaBleedKind, [:]), (ClipEffect.trackingNoiseKind, [:]),
                      (ClipEffect.gateWeaveKind, [:])]).effects(at: s(1))
        #expect(e.segments.isEmpty && !e.isIdentity && e.look.needsPass && !e.isEmpty)
        #expect(abs((e.look.grain?.amount ?? 0) - 0.3) < 1e-9)
        #expect(abs((e.look.grain?.softness ?? 0) - 0.4) < 1e-9 && abs((e.look.grain?.lumaWeight ?? 0) - 0.6) < 1e-9)
        #expect(e.look.grain?.color == 0 && (e.look.grain?.seed ?? 0) == FilmLook.seed(atLocal: s(1)))
        #expect(e.look.weave != nil)
    }

    @Test func zeroAmountsAreIdentity() {
        let c = clip([(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 0]), (ClipEffect.scanlinesKind, [ClipEffect.intensityKey: 0]),
                      (ClipEffect.chromaBleedKind, [ClipEffect.bleedKey: 0, ClipEffect.shiftKey: 0]),
                      (ClipEffect.trackingNoiseKind, [ClipEffect.amountKey: 0]),
                      (ClipEffect.gateWeaveKind, [ClipEffect.amountKey: 0, ClipEffect.rotationKey: 0])])
        #expect(c.effects(at: s(1)) == ClipEffects.none)
    }

    @Test func aDisabledLookEffectRendersAsAbsent() {
        var c = clip([(ClipEffect.grainKind, [:])])
        c.effects[0].enabled = false
        #expect(c.effects(at: s(1)) == ClipEffects.none)
    }

    @Test func animatedGrainChangesAt24PerSecondAndStaticGrainDoesNot() {
        let anim = clip([(ClipEffect.grainKind, [:])])
        let seeds = (0..<48).map { anim.effects(at: s($0, 48)).look.grain!.seed }
        #expect(Set(seeds).count == 24)                                  // one second: 24 steps
        #expect(anim.effects(at: s(1, 100)).look.grain!.seed == anim.effects(at: s(2, 100)).look.grain!.seed)   // same 1/24 s step
        #expect(anim.effects(at: s(0)).look.grain!.seed != anim.effects(at: s(1, 24)).look.grain!.seed)
        let still = clip([(ClipEffect.grainKind, [ClipEffect.grainAnimateKey: 0])])
        #expect(still.effects(at: s(0)).look.grain!.seed == still.effects(at: s(5)).look.grain!.seed)
    }

    @Test func grainSeedIsClipLocal() {
        var c = clip([(ClipEffect.grainKind, [:])])
        c.start = s(100)
        #expect(c.effects(at: s(100)).look.grain!.seed == 0)
    }

    @Test func parametersAreClampedToTheirRange() {
        let c = clip([(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 900, ClipEffect.grainSizeKey: 99])])
        let g = c.effects(at: s(1)).look.grain!
        #expect(g.amount == 1 && g.size == 20)
    }

    @Test func oldFilmGrainParametersStillWork() {
        // A project saved before the unification: only the old keys are stored; the new ones take their defaults.
        var c = clip([])
        let id = c.addEffect(kind: "filmGrain")!
        c.effects[0].parameters = [ClipEffect.grainAmountKey: AnimatedProperty(40), ClipEffect.grainSizeKey: AnimatedProperty(3),
                                   ClipEffect.grainColorKey: AnimatedProperty(50), ClipEffect.grainResponseKey: AnimatedProperty(20)]
        _ = id
        let g = c.effects(at: s(1)).look.grain!
        #expect(abs(g.amount - 0.4) < 1e-9 && g.size == 3 && abs(g.color - 0.5) < 1e-9 && abs(g.lumaWeight - 0.2) < 1e-9)
        #expect(abs(g.softness - 0.4) < 1e-9 && g.seed == FilmLook.seed(atLocal: s(1)))     // new parameters: defaults
        // The retired Analog Grain / Halation / Bloom kinds never shipped and are gone.
        for k in ["filmLookGrain", "halation", "bloom"] { #expect(EffectCatalog.spec(for: k) == nil) }
    }

    @Test func laterInstanceOfTheSameKindWins() {
        let c = clip([(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 10]), (ClipEffect.grainKind, [ClipEffect.grainAmountKey: 60])])
        #expect(abs(c.effects(at: s(1)).look.grain!.amount - 0.6) < 1e-9)
    }

    @Test func lookDoesNotCutTheSegmentList() {
        let c = clip([(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 4]), (ClipEffect.grainKind, [:]),
                      (ClipEffect.cropKind, [ClipEffect.cropLeftKey: 10])])
        let e = c.effects(at: s(1))
        let plain = clip([(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 4]), (ClipEffect.cropKind, [ClipEffect.cropLeftKey: 10])])
        #expect(e.segments == plain.effects(at: s(1)).segments)
        #expect(e.look.grain != nil)
    }

    @Test func trackingBandRollsWithTime() {
        let c = clip([(ClipEffect.trackingNoiseKind, [ClipEffect.speedKey: 0.5])])
        let a = c.effects(at: s(0)).look.tracking!.phase, b = c.effects(at: s(1)).look.tracking!.phase
        #expect(a == 0 && abs(b - 0.5) < 1e-9)
        #expect(abs(c.effects(at: s(2)).look.tracking!.phase) < 1e-9)   // wraps
    }

    @Test func agedFilmIsSeededByFrameTimeAndDeterministic() {
        let c = clip([(ClipEffect.agedFilmKind, [:])])
        let a = c.effects(at: s(7, 24)).look.aged!
        #expect(a == c.effects(at: s(7, 24)).look.aged!)
        #expect(a.seed == FilmLook.seed(atLocal: s(7, 24)) && abs(a.dust - 0.4) < 1e-9)
        #expect(abs(a.scratches - 0.3) < 1e-9 && abs(a.flicker - 0.25) < 1e-9)
        #expect(c.effects(at: s(1, 100)).look.aged!.seed == c.effects(at: s(2, 100)).look.aged!.seed)   // same 1/24 s step
        let seeds = Set((0..<48).map { c.effects(at: s($0, 48)).look.aged!.seed })
        #expect(seeds.count == 24)
        #expect(c.effects(at: s(1)).look.needsPass && c.effects(at: s(1)).segments.isEmpty)
    }

    @Test func agedFilmWithAllZeroIsIdentityAndEachPartAloneRuns() {
        let zero = [ClipEffect.dustKey: 0.0, ClipEffect.scratchesKey: 0, ClipEffect.flickerKey: 0]
        #expect(clip([(ClipEffect.agedFilmKind, zero)]).effects(at: s(1)) == ClipEffects.none)
        for k in [ClipEffect.dustKey, ClipEffect.scratchesKey, ClipEffect.flickerKey] {
            var v = zero; v[k] = 50
            #expect(clip([(ClipEffect.agedFilmKind, v)]).effects(at: s(1)).look.aged != nil, "\(k)")
        }
    }

    @Test func agedFilmFileIsWrittenAsV86() {
        let e = ClipEffect(kind: ClipEffect.agedFilmKind)
        #expect(e.needsV86 && !ClipEffect(kind: ClipEffect.scanlinesKind).needsV86)
    }

    @Test func gateWeaveStaysInsideItsAmountAndIsDeterministic() {
        let c = clip([(ClipEffect.gateWeaveKind, [ClipEffect.amountKey: 6, ClipEffect.rotationKey: 0.5])])
        var xs = Set<Double>()
        for i in 0..<240 {
            let w = c.effects(at: s(Int64(i), 24)).look.weave!
            #expect(abs(w.offsetX) <= 6 && abs(w.offsetY) <= 6 && abs(w.rotation) <= 0.5)
            xs.insert(w.offsetX)
        }
        #expect(xs.count > 100)                                          // it really moves
        #expect(c.effects(at: s(7, 24)).look.weave == c.effects(at: s(7, 24)).look.weave)
    }

    @Test func gateWeaveOverscanCoversTheWorstCase() {
        let w = GateWeave(offsetX: 0, offsetY: 0, rotation: 0, maxOffset: 5, maxRotation: 0)
        #expect(abs(w.overscan(width: 1920, height: 1080, scale: 1) - (1 + 10.0 / 1080)) < 1e-9)
        #expect(GateWeave(offsetX: 0, offsetY: 0, rotation: 0, maxOffset: 0, maxRotation: 0).overscan(width: 100, height: 100, scale: 1) == 1)
        #expect(GateWeave(offsetX: 0, offsetY: 0, rotation: 0, maxOffset: 0, maxRotation: 1).overscan(width: 1920, height: 1080, scale: 1) > 1)
    }

    // MARK: Presets

    @Test func presetsUseOnlyKnownEffectsAndValuesInRange() {
        #expect(FilmPresets.all.map(\.name) == ["Film Look", "VHS", "Bad TV"])
        for p in FilmPresets.all {
            #expect(p.bin == .looks && FilmPresets.isPresetID(p.id) && FilmPresets.preset(id: p.id) == p)
            for item in p.effects {
                #expect(EffectCatalog.spec(for: item.kind) != nil, "\(p.id) \(item.kind)")
                for k in item.colors.keys { #expect(EffectCatalog.spec(for: item.kind)?.params.contains { $0.key == k } == true) }
                for (k, v) in item.parameters where EffectCatalog.param(item.kind, k) != nil {
                    #expect(EffectCatalog.param(item.kind, k)?.range.contains(v.value) == true, "\(p.id) \(item.kind).\(k)")
                }
            }
        }
    }

    @Test func applyingAPresetAddsItsEffectsInOrderWithItsValues() {
        var c = clip([])
        let vhs = FilmPresets.preset(id: "preset.vhs")!
        c.applyPreset(vhs.preset)
        #expect(c.effects.map(\.kind) == vhs.effects.map(\.kind))
        #expect(c.effects.first?.kind == ClipEffect.gaussianBlurKind)
        let bleed = c.effects.first { $0.kind == ClipEffect.chromaBleedKind }!
        #expect(bleed.parameters[ClipEffect.bleedKey]?.value == 8)
        // Untouched parameters keep the effect default.
        #expect(bleed.parameters[ClipEffect.shiftKey]?.value == 3)
        let e = c.effects(at: s(1))
        #expect(e.look.chromaBleed != nil && e.look.scanlines != nil && e.look.tracking != nil && e.look.grain != nil && abs(e.blur - ClipEffect.gaussianSigma(blurriness: 0.8)) < 1e-9)
    }

    @Test func filmLookPresetUsesGlowForHalation() {
        var c = clip([])
        c.applyPreset(FilmPresets.preset(id: "preset.filmLook")!.preset)
        #expect(c.effects.map(\.kind) == [ClipEffect.glowKind, ClipEffect.grainKind, ClipEffect.gateWeaveKind])
        #expect(c.effects[0].colors[ClipEffect.glowColorKey]?.value == FilmPresets.halationColor)
        #expect(c.effects[0].parameters[ClipEffect.glowColorsKey]?.value == 1)
    }

    @Test func presetTitleResolvesThroughTheCatalog() {
        #expect(EffectCatalog.title(for: "preset.badTV") == "Bad TV")
        #expect(EffectCatalog.title(for: ClipEffect.grainKind) == "Film Grain")
    }

    @Test func projectFileKeepsLookEffects() throws {
        var c = clip([])
        c.applyPreset(FilmPresets.preset(id: "preset.filmLook")!.preset)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        #expect(back.effects == c.effects)
    }
}
