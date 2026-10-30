import Foundation
import Testing
@testable import SQCore

// C4: Trails, a temporal effect on the frame-history seam: earlier source frames laid over the shown one, fading out.

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ values: [String: Double] = [:], extra: [String] = []) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
    for k in extra { c.effects.append(ClipEffect.make(kind: k)!) }
    var e = ClipEffect.make(kind: ClipEffect.trailsKind)!
    for (key, v) in values { e.parameters[key] = AnimatedProperty(v) }
    c.effects.append(e)
    return c
}

@Suite struct TrailsEffectTests {
    @Test func catalogOffersTrailsWithItsRanges() throws {
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.trailsKind))
        #expect(spec.title == "Trails")
        #expect(EffectCatalog.param(ClipEffect.trailsKind, ClipEffect.trailCountKey)?.range == 2...8)
        #expect(EffectCatalog.param(ClipEffect.trailsKind, ClipEffect.trailSpacingKey)?.range == 1...3)
        #expect(EffectCatalog.param(ClipEffect.trailsKind, ClipEffect.trailDecayKey)?.range == 0...100)
        #expect(TemporalFilter.Trails.Blend.allCases.count == 3)
        #expect(ClipEffect.trailsKind == "trails")   // stored string
    }

    @Test func defaultsEvaluateIntoATemporalFilter() throws {
        let fx = clip().effects(at: s(1))
        let t = try #require(fx.temporal?.trails)
        #expect(t == .init(count: 4, spacing: 2, decay: 0.4, blend: .screen))
        #expect(fx.temporal?.reachBack == 8 && fx.temporal?.reachAhead == 0)
        // Not part of the effect chain: a plain clip otherwise stays plain.
        #expect(fx.segments.isEmpty && fx.isIdentity)
    }

    @Test func parametersAreClamped() throws {
        let hi = try #require(clip([ClipEffect.trailCountKey: 40, ClipEffect.trailSpacingKey: 9.6, ClipEffect.trailDecayKey: -20,
                                    ClipEffect.trailBlendKey: 7]).effects(at: s(1)).temporal?.trails)
        #expect(hi == .init(count: 8, spacing: 3, decay: 0, blend: .lighten))
        let lo = try #require(clip([ClipEffect.trailCountKey: 0.2, ClipEffect.trailSpacingKey: -3, ClipEffect.trailDecayKey: 30,
                                    ClipEffect.trailBlendKey: -1]).effects(at: s(1)).temporal?.trails)
        #expect(lo == .init(count: 2, spacing: 1, decay: 0.3, blend: .add))
        // The direct initializer clamps too.
        #expect(TemporalFilter.Trails(count: 99, spacing: 0, decay: 2, blend: .add) == .init(count: 8, spacing: 1, decay: 1, blend: .add))
        #expect(TemporalFilter.Trails.maxReach == 24)
    }

    @Test func weightsFallOffByDecay() {
        let t = TemporalFilter.Trails(count: 3, spacing: 2, decay: 0.5, blend: .add)
        #expect(t.weights == [0.5, 0.25, 0.125])
        #expect(t.offsets == [2, 4, 6])
        #expect(TemporalFilter.Trails(count: 3, spacing: 1, decay: 0, blend: .add).weights == [1, 1, 1])
    }

    @Test func fullDecayOrDisabledIsNoFilter() {
        #expect(clip([ClipEffect.trailDecayKey: 100]).effects(at: s(1)).temporal == nil)
        var c = clip()
        c.effects[0].enabled = false
        #expect(c.effects(at: s(1)).temporal == nil)
    }

    @Test func combinesWithDenoiseAndWindowsOnlyLookBack() throws {
        let c = clip([ClipEffect.trailCountKey: 3, ClipEffect.trailSpacingKey: 3], extra: [ClipEffect.videoDenoiseKind])
        let t = try #require(c.effects(at: s(1)).temporal)
        #expect(t.denoise != nil && t.trails != nil)
        #expect(t.radius == 2 && t.reachBack == 9 && t.reachAhead == 2)
        // Fast mode keeps the trails as they are (the look must not change while playing).
        #expect(t.degraded(.fast).trails == t.trails && t.degraded(.fast).reachBack == 9)
        let n = TemporalWindow.neighbours(center: 20, before: t.reachBack, after: t.reachAhead, lower: 15, upper: 21)
        #expect(n.before == [19, 18, 17, 16, 15] && n.after == [21])
        #expect(TemporalWindow.span(center: 20, before: 9, after: 0, lower: 0, upper: 99) == 11...20)
    }

    /// A reversed clip shows higher source frames first: the frames the viewer has already seen lie ahead in source order,
    /// so the echoes come from there (they trail behind the motion as it is seen).
    @Test func reversedClipTrailsFromAhead() throws {
        var c = clip()
        c.reversed = true
        let t = try #require(c.effects(at: s(1)).temporal)
        #expect(t.trails?.backward == true)
        #expect(t.reachBack == 0 && t.reachAhead == 8)
        let fwd = try #require(clip().effects(at: s(1)).temporal)
        #expect(fwd.trails?.backward == false && fwd.reachBack == 8 && fwd.reachAhead == 0)
    }

    /// Speed keys: the direction of the segment shown at that moment.
    @Test func reversedSpeedSegmentTrailsFromAhead() throws {
        var c = clip()
        c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: s(2), from: .normal),
                                            SpeedSegment(duration: s(2), from: .normal, reversed: true)], origin: s(2)))
        #expect(c.effects(at: Time(1, 2)).temporal?.trails?.backward == false)
        #expect(c.effects(at: Time(5, 2)).temporal?.trails?.backward == true)
    }

    /// With Denoise as well, the backward trail widens only the ahead side.
    @Test func backwardTrailsKeepDenoiseRadius() throws {
        var c = clip(extra: [ClipEffect.videoDenoiseKind])
        c.reversed = true
        let t = try #require(c.effects(at: s(1)).temporal)
        #expect(t.reachAhead == max(t.radius, 8) && t.reachBack == t.radius)
    }
}
