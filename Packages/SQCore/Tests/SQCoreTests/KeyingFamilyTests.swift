import Foundation
import Testing
@testable import SQCore

private func clip(_ kind: String, _ values: [String: Double] = [:]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    let id = c.addEffect(kind: kind)!
    for (k, v) in values { c.setParameter(id, k, to: v) }
    return c
}

@Suite struct KeyingFamilyTests {
    @Test func newUltraKeyControlsAreNeutralByDefault() {
        let k = clip(ClipEffect.ultraKeyKind).effects(at: Time(1, 1)).keys[0]
        #expect(k.mode == .chroma && k.output == .composite)
        #expect(k.contrast == 0 && k.midpoint == 0.5 && k.keepHighlights == 0 && k.keepShadows == 0)
        #expect(k.saturation == 1 && k.hueShift == 0 && k.luma == 1 && !k.correctsColor)
        #expect(k.refine.isToneIdentity && k.choke == 0)
    }

    @Test func ultraKeyEvaluatesEveryParam() {
        let c = clip(ClipEffect.ultraKeyKind, [
            ClipEffect.keyHueKey: 200, ClipEffect.toleranceKey: 30, ClipEffect.chokeKey: -40, ClipEffect.keyContrastKey: 50,
            ClipEffect.keyMidpointKey: 30, ClipEffect.keyHighlightKey: 10, ClipEffect.keyShadowKey: 20, ClipEffect.spillRangeKey: 80,
            ClipEffect.keySaturationKey: 150, ClipEffect.keyHueShiftKey: -20, ClipEffect.keyLumaKey: 120, ClipEffect.keyOutputKey: 2,
        ])
        let k = c.effects(at: Time(1, 1)).keys[0]
        #expect(k.hue == 200 && k.halfWidth == 27 && k.choke == -0.4 && k.contrast == 0.5 && k.midpoint == 0.3)
        #expect(k.keepHighlights == 0.1 && k.keepShadows == 0.2 && k.spillRange == 0.8)
        #expect(k.saturation == 1.5 && k.hueShift == -20 && k.luma == 1.2 && k.correctsColor)
        #expect(k.output == .source)
    }

    @Test func oldProjectsKeepTheirMatteOutputIndex() {
        // v-before: Output 1 was "Matte"; it is "Alpha" now at the same index.
        #expect(clip(ClipEffect.ultraKeyKind, [ClipEffect.keyOutputKey: 1]).effects(at: Time(1, 1)).keys[0].matteOutput)
    }

    @Test func lumaKeyEvaluates() {
        let k = clip(ClipEffect.lumaKeyKind, [ClipEffect.lumaThresholdKey: 30, ClipEffect.lumaSoftnessKey: 5,
                                              ClipEffect.lumaKeyOutKey: 1, ClipEffect.chokeKey: 10]).effects(at: Time(1, 1)).keys[0]
        #expect(k.mode == .luma && k.lumaKeysBrights && abs(k.lumaThreshold - 0.3) < 1e-9 && abs(k.lumaSoftness - 0.05) < 1e-9)
        #expect(abs(k.choke - 0.1) < 1e-9)
    }

    @Test func lumaAndUltraShareThePerLayerKeyBudget() {
        var c = clip(ClipEffect.ultraKeyKind)
        _ = c.addEffect(kind: ClipEffect.lumaKeyKind)
        _ = c.addEffect(kind: ClipEffect.lumaKeyKind)
        let fx = c.effects(at: Time(1, 1))
        #expect(fx.keys.count == 3)
        #expect(fx.segments.map(\.keys.count) == [ChromaKey.maxPerLayer, 1])
    }

    @Test func greenAndBlueScreenPresets() throws {
        let g = try #require(EffectStackPresets.preset(id: "greenScreen")), b = try #require(EffectStackPresets.preset(id: "blueScreen"))
        #expect(g.name == "Green Screen" && b.name == "Blue Screen")
        #expect(g.effects.count == 1 && g.effects[0].kind == ClipEffect.ultraKeyKind)
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        c.effects = g.effects
        let kg = c.effects(at: Time(1, 1)).keys[0]
        #expect(kg.hue == 125 && kg.choke > 0 && kg.pedestal == 0.1 && kg.keepHighlights == 0.1 && kg.spill > 0.5)
        c.effects = b.effects
        #expect(c.effects(at: Time(1, 1)).keys[0].hue == 225)
        // Every parameter of the presets is a real parameter of the effect, inside its range.
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.ultraKeyKind))
        for e in g.effects + b.effects {
            for (key, p) in e.parameters {
                let s = try #require(spec.params.first { $0.key == key }, "unknown key \(key)")
                #expect(s.range.contains(p.value))
            }
        }
    }

    @Test func presetsApplyThroughTheEffectPresetPath() throws {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let p = try #require(EffectStackPresets.preset(id: "greenScreen")).preset
        #expect(!p.effects.isEmpty && p.trackKind == .video)
        c.effects = p.effects
        #expect(c.effects.count == 1)
    }
}
