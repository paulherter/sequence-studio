import Foundation
import Testing
@testable import SQCore

// FB-T2: Premiere-parity style effects (Vignette, Film Grain, RGB Split, Radial Blur, Flips, Invert, Posterize, Tint,
// Black & White, Brightness & Contrast, Twirl, Wave Warp, Spherize, Strobe Light, Alpha Adjust) each evaluate into one
// `ImageFilter`, like the W3.1 batch.

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

private func filter(_ e: ClipEffect, at t: Time = Time(1, 1)) -> ImageFilter? {
    clip([e]).effects(at: t).segments.first?.filter
}

@Suite struct EffectsStyleCatalogTests {
    @Test func everyStyleEffectIsOfferedWithItsPremiereNames() {
        #expect(StyleEffects.specs.count >= 16)
        for spec in StyleEffects.specs {
            #expect(EffectCatalog.spec(for: spec.kind) != nil, "\(spec.kind)")
            #expect(EffectCatalog.all.contains { $0.kind == spec.kind } != HiddenCatalog.effectKinds.contains(spec.kind), "\(spec.kind) offered")
            #expect(ClipEffect.make(kind: spec.kind) != nil)
        }
        #expect(EffectCatalog.title(for: ClipEffect.radialBlurKind) == "Radial Blur")
        #expect(EffectCatalog.param(ClipEffect.radialBlurKind, ClipEffect.radialAmountKey)?.defaultValue == 10)
        #expect(EffectCatalog.param(ClipEffect.waveWarpKind, ClipEffect.waveHeightKey)?.defaultValue == 10)
        #expect(EffectCatalog.param(ClipEffect.waveWarpKind, ClipEffect.waveWidthKey)?.defaultValue == 40)
        #expect(EffectCatalog.param(ClipEffect.waveWarpKind, ClipEffect.waveDirectionKey)?.defaultValue == 90)
        #expect(EffectCatalog.param(ClipEffect.strobeKind, ClipEffect.strobeDurationKey)?.defaultValue == 0.05)
        #expect(EffectCatalog.param(ClipEffect.strobeKind, ClipEffect.strobePeriodKey)?.defaultValue == 0.1)
        #expect(EffectCatalog.param(ClipEffect.posterizeKind, ClipEffect.posterizeLevelKey)?.defaultValue == 7)
        #expect(EffectCatalog.param(ClipEffect.twirlKind, ClipEffect.twirlRadiusKey)?.defaultValue == 50)
        #expect(EffectCatalog.param(ClipEffect.alphaAdjustKind, ClipEffect.alphaOpacityKey)?.defaultValue == 100)
        if case .color(let c)? = EffectCatalog.param(ClipEffect.tintKind, ClipEffect.tintWhiteKey)?.kind { #expect(c == .white) }
        else { Issue.record("Map White To is a color") }
        if case .point? = EffectCatalog.param(ClipEffect.twirlKind, ClipEffect.twirlCenterKey)?.kind {} else { Issue.record("Twirl Center") }
    }

    @Test func everyParameterIsAnimatable() {
        // Presets are start values, never locks: every scalar default sits inside its range and has a key in new instances.
        for spec in StyleEffects.specs {
            let e = ClipEffect.make(kind: spec.kind)!
            for p in spec.params where p.kind.isScalar {
                #expect(p.range.contains(p.defaultValue), "\(spec.kind).\(p.key)")
                #expect(e.parameters[p.key] != nil, "\(spec.kind).\(p.key)")
            }
        }
    }
}

@Suite struct EffectsStyleEvaluationTests {
    @Test func identityDefaultsDrawThePictureAsIs() {
        // Premiere's own defaults that change nothing: Brightness & Contrast 0/0, Twirl 0 deg, Spherize radius 0.
        for k in [ClipEffect.brightnessContrastKind, ClipEffect.twirlKind, ClipEffect.spherizeKind] {
            #expect(clip([effect(k)]).effects(at: s(1)) == .none, "\(k)")
        }
        #expect(clip([effect(ClipEffect.radialBlurKind, [ClipEffect.radialAmountKey: 0])]).effects(at: s(1)) == .none)
        #expect(clip([effect(ClipEffect.vignetteKind, [ClipEffect.vignetteAmountKey: 0])]).effects(at: s(1)) == .none)
        #expect(clip([effect(ClipEffect.grainKind, [ClipEffect.grainAmountKey: 0])]).effects(at: s(1)) == .none)
        #expect(clip([effect(ClipEffect.invertKind, [ClipEffect.invertBlendKey: 100])]).effects(at: s(1)) == .none)
        #expect(clip([effect(ClipEffect.tintKind, [ClipEffect.tintAmountKey: 0])]).effects(at: s(1)) == .none)
    }

    @Test func visibleDefaultsForEffectsPremiereHasNoStandaloneFor() {
        // Vignette, Film Grain and RGB Split show something as soon as they are dropped on a clip.
        #expect(filter(effect(ClipEffect.vignetteKind)) != nil)
        #expect(clip([effect(ClipEffect.grainKind)]).effects(at: s(1)).look.grain != nil)     // grain runs in the film look pass
        #expect(filter(effect(ClipEffect.rgbSplitKind)) != nil)
    }

    @Test func flipsAndBlackAndWhite() {
        #expect(filter(effect(ClipEffect.horizontalFlipKind)) == .flip(horizontal: true, vertical: false))
        #expect(filter(effect(ClipEffect.verticalFlipKind)) == .flip(horizontal: false, vertical: true))
        #expect(filter(effect(ClipEffect.blackAndWhiteKind)) == .tint(black: .zero, white: SIMD3(1, 1, 1), amount: 1))
    }

    @Test func radialBlurMapsTypeAndCenter() {
        var e = effect(ClipEffect.radialBlurKind, [ClipEffect.radialAmountKey: 20, ClipEffect.radialTypeKey: 1, ClipEffect.radialQualityKey: 1])
        e.points[ClipEffect.radialCenterKey] = AnimatedProperty(Vec2(10, -5))
        #expect(filter(e) == .radialBlur(center: Vec2(10, -5), amount: 20, zoom: true, high: true))
    }

    @Test func rgbSplitIsADirectionAndALength() {
        let e = effect(ClipEffect.rgbSplitKind, [ClipEffect.rgbSplitAmountKey: 10, ClipEffect.rgbSplitAngleKey: 90])
        guard case .rgbSplit(let dx, let dy, let radial, let mix)? = filter(e) else { Issue.record("no split"); return }
        let off: Double = abs(dx - 10) + abs(dy)
        #expect(off < 1e-9)
        #expect(!radial)
        #expect(mix == 0)
        #expect(ImageFilter.rgbSplit(dx: 10, dy: 0, radial: false, mix: 0).margin == 10)
    }

    @Test func waveWarpPhaseAdvancesWithWaveSpeed() {
        // Wave Speed 1 = one cycle per second: at 0.25 s the phase is a quarter cycle on from Phase.
        let e = effect(ClipEffect.waveWarpKind, [ClipEffect.waveSpeedKey: 1, ClipEffect.wavePhaseKey: 0])
        guard case .waveWarp(_, let h, let w, let dir, let phase, _)? = filter(e, at: Time(1, 4)) else { Issue.record("no wave"); return }
        #expect(h == 10)
        #expect(w == 40)
        #expect(dir == 90)
        #expect(abs(phase - 0.25) < 1e-9)
        guard case .waveWarp(_, _, _, _, let p2, _)? = filter(e, at: Time(5, 4)) else { return }
        #expect(abs(p2 - 0.25) < 1e-9)                         // wrapped into 0..<1
        // Phase 90 deg is a quarter cycle with the waves standing still.
        let still = effect(ClipEffect.waveWarpKind, [ClipEffect.waveSpeedKey: 0, ClipEffect.wavePhaseKey: 90])
        guard case .waveWarp(_, _, _, _, let p3, _)? = filter(still, at: s(3)) else { return }
        #expect(abs(p3 - 0.25) < 1e-9)
    }

    @Test func strobeIsOnForItsDurationEveryPeriod() {
        let e = effect(ClipEffect.strobeKind)                  // 0.05 s every 0.1 s
        #expect(filter(e, at: Time(1, 100)) != nil)            // 0.01 s: on
        #expect(filter(e, at: Time(7, 100)) == nil)            // 0.07 s: off
        #expect(filter(e, at: Time(102, 100)) != nil)          // 1.02 s: on again
        // Random Strobe Probability: some periods flash, some do not, always the same ones.
        let r = effect(ClipEffect.strobeKind, [ClipEffect.strobeRandomKey: 50])
        func flashes() -> [Bool] {
            (0..<200).map { (i: Int) -> Bool in filter(r, at: Time(Int64(i * 10 + 1), 100)) != nil }
        }
        let on = flashes(), again = flashes()
        let count = on.filter { $0 }.count
        #expect(count > 60)
        #expect(count < 140)
        #expect(on == again)
    }

    @Test func alphaAdjustDefaultIsIdentityAndItsFlagsMap() {
        #expect(clip([effect(ClipEffect.alphaAdjustKind)]).effects(at: s(1)) == .none)
        let e = effect(ClipEffect.alphaAdjustKind, [ClipEffect.alphaOpacityKey: 40, ClipEffect.alphaInvertKey: 1])
        #expect(filter(e) == .alphaAdjust(opacity: 0.4, ignore: false, invert: true, maskOnly: false))
    }

    @Test func twirlRadiusIsAShareOfTheLongerSide() {
        // The radius in px needs the clip's frame; the filter keeps the share and the renderer scales it.
        let e = effect(ClipEffect.twirlKind, [ClipEffect.twirlAngleKey: 180])
        #expect(filter(e) == .twirl(center: .zero, angle: 180, radius: 0.5))
    }

    @Test func keyedParametersAnimate() {
        var e = effect(ClipEffect.posterizeKind)
        e.parameters[ClipEffect.posterizeLevelKey] = AnimatedProperty(2.0, track: KeyframeTrack(keys: [Keyframe(time: s(0), value: 2.0), Keyframe(time: s(2), value: 10.0)]))
        #expect(filter(e, at: s(1)) == .posterize(levels: 6))
    }

    @Test func lensDistortionMapsPremiereParameters() {
        #expect(clip([effect(ClipEffect.lensDistortionKind)]).effects(at: s(1)) == .none)        // Curvature 0
        let e = effect(ClipEffect.lensDistortionKind, [ClipEffect.lensCurvatureKey: -40, ClipEffect.lensVDecenterKey: 10])
        #expect(filter(e) == .lensDistortion(curvature: -0.4, decenter: Vec2(0, 0.1), fillAlpha: true, fill: SIMD3(1, 1, 1), exactModel: true))
        // A Lens Distortion saved before F7.15 has no model key: it keeps its old look. Turning Auto Scale on moves it to
        // the exact model (Auto Scale is defined on it), turning it off again gives the old look back.
        #expect(e.parameters[ClipEffect.lensModelKey]?.value == 1)
        #expect(EffectCatalog.param(ClipEffect.lensDistortionKind, ClipEffect.lensModelKey) == nil)     // no Effect Controls row
        var saved = e
        saved.parameters[ClipEffect.lensModelKey] = nil
        #expect(filter(saved) == .lensDistortion(curvature: -0.4, decenter: Vec2(0, 0.1), fillAlpha: true, fill: SIMD3(1, 1, 1)))
        saved.parameters[ClipEffect.lensAutoScaleKey] = AnimatedProperty(1.0)
        #expect(filter(saved) == .lensDistortion(curvature: -0.4, decenter: Vec2(0, 0.1), fillAlpha: true, fill: SIMD3(1, 1, 1),
                                                 autoScale: true, exactModel: true))
        // Auto Scale is off unless set (a Lens Distortion saved before F7.15 has no such key) and does nothing at Curvature 0.
        var auto = e
        auto.parameters[ClipEffect.lensAutoScaleKey] = AnimatedProperty(1.0)
        #expect(filter(auto) == .lensDistortion(curvature: -0.4, decenter: Vec2(0, 0.1), fillAlpha: true, fill: SIMD3(1, 1, 1), autoScale: true, exactModel: true))
        #expect(clip([effect(ClipEffect.lensDistortionKind, [ClipEffect.lensAutoScaleKey: 1])]).effects(at: s(1)) == .none)
    }

    @Test func lightLeakDriftsOverTime() {
        let e = effect(ClipEffect.lightLeakKind)
        guard case .lightLeak(_, _, let i, let c0, _, _)? = filter(e, at: s(0)),
              case .lightLeak(_, _, _, let c1, _, _)? = filter(e, at: s(1)) else { Issue.record("no leak"); return }
        #expect(i > 0)
        #expect(c0 != c1)                                      // Speed > 0: the leak moves
        let still = effect(ClipEffect.lightLeakKind, [ClipEffect.leakSpeedKey: 0])
        #expect(filter(still, at: s(0)) == filter(still, at: s(3)))
        #expect(clip([effect(ClipEffect.lightLeakKind, [ClipEffect.leakIntensityKey: 0])]).effects(at: s(1)) == .none)
    }

    @Test func gradientDefaultsAndMapping() {
        let spec = EffectCatalog.spec(for: ClipEffect.gradientKind)
        #expect(spec?.title == "Gradient")
        #expect(EffectCatalog.param(ClipEffect.gradientKind, ClipEffect.gradientTypeKey)?.defaultValue == 0)
        #expect(EffectCatalog.param(ClipEffect.gradientKind, ClipEffect.gradientBlendKey)?.defaultValue == 100)
        let e = effect(ClipEffect.gradientKind)
        #expect(filter(e) == .gradient(color1: .zero, color2: SIMD3(1, 1, 1), start: Vec2(0, -400), end: Vec2(0, 400), radial: false, blend: 1))
        let r = effect(ClipEffect.gradientKind, [ClipEffect.gradientTypeKey: 1, ClipEffect.gradientBlendKey: 40])
        guard case .gradient(_, _, _, _, let radial, let blend)? = filter(r) else { Issue.record("no gradient"); return }
        #expect(radial && abs(blend - 0.4) < 1e-9)
        #expect(clip([effect(ClipEffect.gradientKind, [ClipEffect.gradientBlendKey: 0])]).effects(at: s(1)) == .none)
    }

    @Test func gradientPointsAndColoursKeyframe() {
        var e = effect(ClipEffect.gradientKind)
        e.points[ClipEffect.gradientEndKey] = AnimatedProperty(Vec2(0, 400), track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(0, 400)), Keyframe(time: s(2), value: Vec2(200, 400))]))
        guard case .gradient(_, _, _, let end, _, _)? = filter(e, at: s(1)) else { Issue.record("no gradient"); return }
        #expect(abs(end.x - 100) < 1e-6)
    }

    // Halftone, Tile, Kaleidoscope (creator effects the audit found missing).
    @Test func halftoneTileKaleidoscopeAreOfferedAndMapped() {
        for k in [ClipEffect.halftoneKind, ClipEffect.tileKind, ClipEffect.kaleidoscopeKind] {
            #expect(EffectCatalog.all.contains { $0.kind == k }, "\(k)")
            #expect(ClipEffect.make(kind: k) != nil)
            #expect(ClipEffect.maskInputKinds.contains(k))
        }
        #expect(filter(effect(ClipEffect.halftoneKind)) == .halftone(size: 12, angle: 45, softness: 0.2, color: false, blend: 1))
        #expect(clip([effect(ClipEffect.halftoneKind, [ClipEffect.halftoneBlendKey: 0])]).effects(at: s(1)) == .none)
        #expect(filter(effect(ClipEffect.tileKind)) == .tile(columns: 2, rows: 2, offset: .zero, mirror: false))
        #expect(clip([effect(ClipEffect.tileKind, [ClipEffect.tileColumnsKey: 1, ClipEffect.tileRowsKey: 1])]).effects(at: s(1)) == .none)
        #expect(filter(effect(ClipEffect.kaleidoscopeKind)) == .kaleidoscope(center: .zero, segments: 6, angle: 0, zoom: 1))
        let k = effect(ClipEffect.kaleidoscopeKind, [ClipEffect.kaleidoSegmentsKey: 3.6, ClipEffect.kaleidoZoomKey: 200])
        #expect(filter(k) == .kaleidoscope(center: .zero, segments: 4, angle: 0, zoom: 2))
    }

    // Edge Feather, Glitch Displace.
    @Test func edgeFeatherAndGlitchDisplaceAreOfferedAndMapped() {
        for k in [ClipEffect.edgeFeatherKind, ClipEffect.glitchKind] {
            #expect(EffectCatalog.all.contains { $0.kind == k }, "\(k)")
            #expect(ClipEffect.make(kind: k) != nil)
            #expect(ClipEffect.maskInputKinds.contains(k))
        }
        #expect(filter(effect(ClipEffect.edgeFeatherKind)) == .edgeFeather(amount: 40))
        #expect(clip([effect(ClipEffect.edgeFeatherKind, [ClipEffect.edgeFeatherAmountKey: 0])]).effects(at: s(1)) == .none)
        #expect(filter(effect(ClipEffect.glitchKind)) == .glitch(amount: 30, block: 24, split: 6, density: 0.4, seed: 9))   // Seed 1 + 8 steps/s * 1 s
        #expect(clip([effect(ClipEffect.glitchKind, [ClipEffect.glitchAmountKey: 0, ClipEffect.glitchSplitKey: 0])]).effects(at: s(1)) == .none)
        // Rate 4 steps per second: the pattern changes every 0.25 s and holds in between.
        let a = effect(ClipEffect.glitchKind, [ClipEffect.glitchRateKey: 4])
        #expect(filter(a, at: Time(1, 10)) == filter(a, at: Time(2, 10)))
        #expect(filter(a, at: Time(1, 10)) != filter(a, at: Time(3, 10)))
        // Rate 0 freezes it.
        let f = effect(ClipEffect.glitchKind, [ClipEffect.glitchRateKey: 0])
        #expect(filter(f, at: Time(1, 10)) == filter(f, at: s(5)))
    }

    @Test func newEffectParametersAnimate() {
        var e = effect(ClipEffect.tileKind)
        e.parameters[ClipEffect.tileColumnsKey] = AnimatedProperty(2.0, track: KeyframeTrack(keys: [Keyframe(time: s(0), value: 2.0), Keyframe(time: s(2), value: 6.0)]))
        guard case .tile(let c, _, _, _)? = filter(e, at: s(1)) else { Issue.record("no tile"); return }
        #expect(abs(c - 4) < 1e-9)
    }
}
