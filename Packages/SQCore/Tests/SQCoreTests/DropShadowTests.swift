import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip() -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(5)), start: s(0))
}

private func shadow(_ values: [String: Double] = [:]) -> ClipEffect {
    var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
    for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
    return e
}

@Suite struct DropShadowTests {
    @Test func spreadSitsBetweenDistanceAndSoftnessAndFlowsToTheShadow() {
        let keys = EffectCatalog.spec(for: ClipEffect.dropShadowKind)!.params.map(\.key)
        let i = keys.firstIndex(of: ClipEffect.shadowDistanceKey)!
        #expect(keys[i + 1] == ClipEffect.shadowSpreadKey && keys[i + 2] == ClipEffect.shadowSoftnessKey)
        var c = clip()
        c.effects = [shadow()]
        #expect(c.effects(at: s(1)).segments.first!.shadow!.spread == 0)    // default; an old project without the key reads 0
        c.effects = [shadow([ClipEffect.shadowSpreadKey: 40])]
        #expect(abs(c.effects(at: s(1)).segments.first!.shadow!.spread - 0.4) < 1e-9)
    }
    @Test func catalogHasPremiereDefaults() {
        #expect(EffectCatalog.spec(for: ClipEffect.dropShadowKind)?.title == "Drop Shadow")
        let e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        #expect(e.parameters[ClipEffect.shadowOpacityKey]?.value(atLocal: .zero) == 50)
        #expect(e.parameters[ClipEffect.shadowDirectionKey]?.value(atLocal: .zero) == 135)
        #expect(e.parameters[ClipEffect.shadowDistanceKey]?.value(atLocal: .zero) == 5)
        #expect(e.parameters[ClipEffect.shadowSoftnessKey]?.value(atLocal: .zero) == 5)
        #expect(e.parameters[ClipEffect.shadowOnlyKey]?.value(atLocal: .zero) == 0)
        #expect(e.parameters.count == 6 && e.colors.count == 1)
    }

    @Test func directionZeroIsUpAndClockwise() {
        var c = clip()
        c.effects = [shadow([ClipEffect.shadowDirectionKey: 0, ClipEffect.shadowDistanceKey: 10])]
        var sh = c.effects(at: s(1)).segments.first!.shadow!
        #expect(abs(sh.dx) < 1e-9 && abs(sh.dy + 10) < 1e-9)       // up = negative y
        c.effects = [shadow([ClipEffect.shadowDirectionKey: 135, ClipEffect.shadowDistanceKey: 10])]
        sh = c.effects(at: s(1)).segments.first!.shadow!
        #expect(sh.dx > 0 && sh.dy > 0)                              // lower right
        #expect(abs(sh.dx - 10 * 0.5.squareRoot()) < 1e-9)
    }

    @Test func softnessIsPremiereUnitsAndColourOpacityConvert() {
        var c = clip()
        var e = shadow([ClipEffect.shadowSoftnessKey: 20, ClipEffect.shadowOpacityKey: 80])
        e.colors[ClipEffect.shadowColorKey] = AnimatedProperty(EffectColor(red: 1, green: 0, blue: 0.2))
        c.effects = [e]
        let sh = c.effects(at: s(1)).segments.first!.shadow!
        // Premiere units: sigma = 0.2 x Softness (measured against Premiere's render).
        #expect(ClipEffect.shadowSigmaPerSoftness == 0.2)
        #expect(abs(sh.sigma - 4) < 1e-12)
        #expect(abs(sh.opacity - 0.8) < 1e-12)
        #expect(sh.color == SIMD3(1, 0, 0.2))
        #expect(!sh.shadowOnly)
    }

    @Test func zeroOpacityIsIdentityUnlessShadowOnly() {
        var c = clip()
        c.effects = [shadow([ClipEffect.shadowOpacityKey: 0])]
        #expect(c.effects(at: s(1)) == .none)
        c.effects = [shadow([ClipEffect.shadowOpacityKey: 0, ClipEffect.shadowOnlyKey: 1])]
        #expect(c.effects(at: s(1)).segments.first?.shadow?.shadowOnly == true)
    }

    @Test func disabledIsIgnoredAndShadowCutsTheList() {
        var c = clip()
        var e = shadow()
        e.enabled = false
        c.effects = [e]
        #expect(c.effects(at: s(1)) == .none)
        c.effects = [ClipEffect.make(kind: ClipEffect.cropKind)!, shadow(), ClipEffect.make(kind: ClipEffect.roundedCornersKind)!]
        let segs = c.effects(at: s(1)).segments
        #expect(segs.count == 2)
        #expect(segs[0].shadow != nil && segs[1].shadow == nil)
        #expect(segs[1].masks.cornerRadius == 24)
    }

    @Test func blurAfterShadowIsNotMergedIntoShadowSegment() {
        var c = clip()
        var blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        blur.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(8)
        c.effects = [shadow(), blur]
        let segs = c.effects(at: s(1)).segments
        #expect(segs.count == 3)
        #expect(segs[0].shadow != nil && segs[0].blurAfter == 0)
        #expect(segs[1].blurAfter == ClipEffect.gaussianSigma(blurriness: 8) && segs[1].shadow == nil)
    }

    @Test func parametersKeyframeAndRoundTrip() throws {
        var c = clip()
        var e = shadow()
        e.parameters[ClipEffect.shadowDistanceKey] = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(2), value: 20.0)]))
        c.effects = [e]
        let mid = c.effects(at: s(1)).segments.first!.shadow!
        #expect(abs(mid.distance - 10) < 1e-9)
        let data = try JSONEncoder().encode(c.effects)
        #expect(try JSONDecoder().decode([ClipEffect].self, from: data) == c.effects)
    }
}

@Suite struct ColorEffectGroupsTests {
    @Test func groupsFollowTheColorPageSwitches() {
        #expect(ColorEffectGroups.toggleKeys == [ClipEffect.colorBasicOnKey, ClipEffect.colorCreativeOnKey, ClipEffect.colorCurvesOnKey,
                                                 ClipEffect.colorWheelsOnKey, ClipEffect.colorVignetteOnKey])
        #expect(ColorEffectGroups.groupKey(of: ClipEffect.colorTemperatureKey) == ClipEffect.colorBasicOnKey)
        #expect(ColorEffectGroups.groupKey(of: ClipEffect.colorFadedFilmKey) == ClipEffect.colorCreativeOnKey)
        #expect(ColorEffectGroups.groupKey(of: ClipEffect.colorWheelSaturationKey) == ClipEffect.colorWheelsOnKey)
        #expect(ColorEffectGroups.groupKey(of: ClipEffect.colorCurvesOnKey) == ClipEffect.colorCurvesOnKey)
        #expect(ColorEffectGroups.groupKey(of: "nonsense") == nil)
    }
}
