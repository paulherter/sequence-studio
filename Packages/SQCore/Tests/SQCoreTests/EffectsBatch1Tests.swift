import Foundation
import Testing
@testable import SQCore

// W3.1: Sharpen, Directional Blur, Mirror, Noise, Glow, Mosaic evaluate into one `ImageFilter` each, which ends its segment.

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ effects: [ClipEffect]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(5)), start: s(0))
    c.effects = effects
    return c
}

private func effect(_ kind: String, _ values: [String: Double] = [:]) -> ClipEffect {
    var e = ClipEffect.make(kind: kind)!
    for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
    return e
}

/// The one filter of a single-effect clip at t = 1 s.
private func filter(_ e: ClipEffect, at t: Time = Time(1, 1)) -> ImageFilter? {
    let fx = clip([e]).effects(at: t)
    #expect(fx.segments.count == 2 || fx.segments.isEmpty)
    return fx.segments.first?.filter
}

@Suite struct EffectsBatch1CatalogTests {
    @Test func everyNewEffectIsInTheCatalogWithItsParamKinds() {
        let kinds = [ClipEffect.sharpenKind, ClipEffect.directionalBlurKind, ClipEffect.mirrorKind,
                     ClipEffect.noiseKind, ClipEffect.glowKind, ClipEffect.mosaicKind]
        for k in kinds { #expect(EffectCatalog.spec(for: k) != nil, "\(k)") }
        #expect(EffectCatalog.title(for: ClipEffect.mosaicKind) == "Mosaic")
        if case .point(let p)? = EffectCatalog.param(ClipEffect.mirrorKind, ClipEffect.mirrorCenterKey)?.kind { #expect(p == .zero) }
        else { Issue.record("Reflection Center is a point") }
        if case .color(let c)? = EffectCatalog.param(ClipEffect.glowKind, ClipEffect.glowColorKey)?.kind { #expect(c == .white) }
        else { Issue.record("Glow Color is a color") }
        if case .choice(let t)? = EffectCatalog.param(ClipEffect.glowKind, ClipEffect.glowColorsKey)?.kind { #expect(t.count == 2) }
        else { Issue.record("Glow Colors is a choice") }
        #expect(EffectCatalog.param(ClipEffect.mosaicKind, ClipEffect.mosaicSharpKey)?.kind == .checkbox)
        #expect(EffectCatalog.param(ClipEffect.noiseKind, ClipEffect.noiseColorKey)?.kind == .checkbox)
    }

    @Test func newInstancesCarryTheirTypedDefaults() {
        let m = ClipEffect.make(kind: ClipEffect.mirrorKind)!
        #expect(m.points[ClipEffect.mirrorCenterKey]?.value(atLocal: .zero) == .zero)
        let g = ClipEffect.make(kind: ClipEffect.glowKind)!
        #expect(g.colors[ClipEffect.glowColorKey]?.value(atLocal: .zero) == .white)
    }
}

@Suite struct EffectsBatch1EvaluationTests {
    @Test func defaultsThatDoNothingAreIdentity() {
        // Premiere's defaults: Sharpen 0, Directional Blur length 0, Noise 0 % draw the picture as it is.
        for k in [ClipEffect.sharpenKind, ClipEffect.directionalBlurKind, ClipEffect.noiseKind] {
            #expect(clip([effect(k)]).effects(at: s(1)) == .none, "\(k)")
        }
        #expect(clip([effect(ClipEffect.glowKind, [ClipEffect.glowIntensityKey: 0])]).effects(at: s(1)) == .none)
    }

    @Test func sharpenAmountIsAFraction() {
        #expect(filter(effect(ClipEffect.sharpenKind, [ClipEffect.sharpenAmountKey: 150])) == .sharpen(amount: 1.5))
    }

    @Test func directionalBlurZeroDegreesIsVertical() {
        guard case .directionalBlur(let dx, let dy)? = filter(effect(ClipEffect.directionalBlurKind,
                                                                     [ClipEffect.blurLengthKey: 20])) else {
            Issue.record("no directional blur"); return
        }
        #expect(abs(dx) < 1e-9 && abs(abs(dy) - 20) < 1e-9)
        guard case .directionalBlur(let hx, let hy)? = filter(effect(ClipEffect.directionalBlurKind,
                                                                     [ClipEffect.blurLengthKey: 20, ClipEffect.blurDirectionKey: 90])) else {
            Issue.record("no directional blur"); return
        }
        #expect(abs(abs(hx) - 20) < 1e-9 && abs(hy) < 1e-9)
        #expect(ImageFilter.directionalBlur(dx: 0, dy: 20).margin == 10)
    }

    @Test func mirrorTakesPointAndAngle() {
        var e = effect(ClipEffect.mirrorKind, [ClipEffect.mirrorAngleKey: 90])
        e.points[ClipEffect.mirrorCenterKey] = AnimatedProperty(Vec2(12, -4))
        #expect(filter(e) == .mirror(center: Vec2(12, -4), angle: 90))
        // Default: through the frame center, left side onto the right.
        #expect(filter(effect(ClipEffect.mirrorKind)) == .mirror(center: .zero, angle: 0))
    }

    @Test func noiseSeedChangesFromFrameToFrameAndIsStableWithinOne() {
        let e = effect(ClipEffect.noiseKind, [ClipEffect.noiseAmountKey: 40])
        guard case .noise(let a, let color, let clipped, let seed1)? = filter(e, at: Time(1, 25)),
              case .noise(_, _, _, let seed2)? = filter(e, at: Time(2, 25)),
              case .noise(_, _, _, let seed1b)? = filter(e, at: Time(2, 50)) else { Issue.record("no noise"); return }
        #expect(a == 0.4 && color && clipped)
        #expect(seed1 != seed2)
        #expect(seed1 == seed1b)                       // 1/25 == 2/50: the same instant
    }

    @Test func glowCustomColourOnlyWhenChosen() {
        var e = effect(ClipEffect.glowKind, [ClipEffect.glowThresholdKey: 50, ClipEffect.glowRadiusKey: 20,
                                            ClipEffect.glowIntensityKey: 2])
        e.colors[ClipEffect.glowColorKey] = AnimatedProperty(EffectColor(red: 1, green: 0, blue: 0))
        #expect(filter(e) == .glow(threshold: 0.5, sigma: 10, intensity: 2, color: nil))
        e.parameters[ClipEffect.glowColorsKey] = AnimatedProperty(1)
        #expect(filter(e) == .glow(threshold: 0.5, sigma: 10, intensity: 2, color: SIMD3(1, 0, 0)))
        #expect(ImageFilter.glow(threshold: 0.5, sigma: 10, intensity: 2, color: nil).margin == 30)
    }

    @Test func mosaicBlocksAreWholeAndAtLeastOne() {
        #expect(filter(effect(ClipEffect.mosaicKind)) == .mosaic(columns: 10, rows: 10, sharp: false))
        #expect(filter(effect(ClipEffect.mosaicKind, [ClipEffect.mosaicColumnsKey: 3.6, ClipEffect.mosaicRowsKey: 0,
                                                      ClipEffect.mosaicSharpKey: 1])) == .mosaic(columns: 4, rows: 1, sharp: true))
    }

    @Test func filtersKeepListOrderAroundMasksAndBlurs() {
        // [Crop, Mosaic, Blur]: crop in the first pass, mosaic ends it, the blur works on the mosaic.
        let fx = clip([effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 10]), effect(ClipEffect.mosaicKind),
                       effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 4])]).effects(at: s(1))
        #expect(fx.segments.count == 3)
        #expect(fx.segments[0].masks.crop.left == 0.1 && fx.segments[0].filter != nil && fx.segments[0].blurAfter == 0)
        #expect(fx.segments[1].filter == nil && fx.segments[1].blurAfter == ClipEffect.gaussianSigma(blurriness: 4))
        #expect(!fx.isIdentity)
        // Two blurs around a filter are not merged across it.
        let fx2 = clip([effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 3]), effect(ClipEffect.mirrorKind),
                        effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 4])]).effects(at: s(1))
        #expect(fx2.segments.map(\.blurAfter) == [3, 0, 4, 0].map { ClipEffect.gaussianSigma(blurriness: $0) })
        #expect(fx2.segments[1].filter == .mirror(center: .zero, angle: 0))
    }

    @Test func disabledFilterIsAbsent() {
        var e = effect(ClipEffect.mosaicKind); e.enabled = false
        #expect(clip([e]).effects(at: s(1)) == .none)
    }

    @Test func projectRoundTripKeepsTheNewEffects() throws {
        var m = effect(ClipEffect.mirrorKind)
        m.points[ClipEffect.mirrorCenterKey] = AnimatedProperty(Vec2(3, 4))
        let c = clip([m, effect(ClipEffect.glowKind), effect(ClipEffect.mosaicKind, [ClipEffect.mosaicSharpKey: 1])])
        let data = try JSONEncoder().encode(c.effects)
        let back = try JSONDecoder().decode([ClipEffect].self, from: data)
        #expect(back == c.effects)
    }
}
