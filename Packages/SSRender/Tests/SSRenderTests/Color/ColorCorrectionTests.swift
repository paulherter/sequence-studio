import Testing
import simd
@testable import SSRender

@Suite struct ColorCorrectionTests {
    let gamuts: [Gamut] = [.rec709, .bt2020, .sGamut3Cine]
    let samples: [SIMD3<Float>] = [[0.18, 0.18, 0.18], [0.5, 0.2, 0.1], [2, 1, 0.5], [0, 0, 0], [0.01, 0.3, 0.9], [12, 8, 20]]

    @Test func neutralIsIdentity() {
        for g in gamuts { for s in samples {
            #expect(simd_length(ColorCorrection().apply(s, gamut: g) - s) < 1e-6)
        } }
        #expect(ColorCorrection().isNeutral)
    }

    @Test func whiteBalanceIsContinuousAtZero() {
        for g in gamuts { for s in samples {
            var t = ColorCorrection(); t.temperature = 0.001
            var n = ColorCorrection(); n.tint = 0.001
            #expect(simd_length(t.apply(s, gamut: g) - s) < 1e-4 * max(1, simd_length(s)))
            #expect(simd_length(n.apply(s, gamut: g) - s) < 1e-4 * max(1, simd_length(s)))
        } }
    }

    @Test func exposurePlusOneDoubles() {
        var c = ColorCorrection(); c.exposure = 1
        let o = c.apply([0.2, 0.3, 0.4], gamut: .rec709)
        #expect(simd_length(o - SIMD3(0.4, 0.6, 0.8)) < 1e-6)
    }

    @Test func saturationZeroIsLuma() {
        var c = ColorCorrection(); c.saturation = 0
        for g in gamuts {
            let s = SIMD3<Float>(0.5, 0.2, 0.1)
            let o = c.apply(s, gamut: g)
            let y = simd_dot(g.lumaRow, s)
            #expect(simd_length(o - SIMD3(repeating: y)) < 1e-6)
        }
    }

    @Test func saturation200Doubles() {
        var c = ColorCorrection(); c.saturation = 200
        let s = SIMD3<Float>(0.5, 0.2, 0.1)
        let y = simd_dot(Gamut.rec709.lumaRow, s)
        #expect(simd_length(c.apply(s, gamut: .rec709) - (SIMD3(repeating: y) + (s - y) * 2)) < 1e-6)
    }

    @Test func contrastKeepsGreyFixedAndSpreads() {
        var c = ColorCorrection(); c.contrast = 60
        for g in gamuts {
            #expect(simd_length(c.apply([0.18, 0.18, 0.18], gamut: g) - SIMD3(repeating: 0.18)) < 1e-6)
        }
        #expect(c.apply([0.36, 0.36, 0.36], gamut: .rec709).x > 0.36)
        #expect(c.apply([0.09, 0.09, 0.09], gamut: .rec709).x < 0.09)
        // hue preserved
        let o = c.apply([0.4, 0.2, 0.1], gamut: .rec709)
        #expect(abs(o.x / o.y - 2) < 1e-5 && abs(o.y / o.z - 2) < 1e-5)
    }

    @Test func highlightsAndShadowsAreSeparated() {
        var h = ColorCorrection(); h.highlights = 100
        var s = ColorCorrection(); s.shadows = 100
        let shadowPx = SIMD3<Float>(repeating: 0.05), grey = SIMD3<Float>(repeating: 0.18), hiPx = SIMD3<Float>(repeating: 1.5)
        #expect(simd_length(h.apply(shadowPx, gamut: .rec709) - shadowPx) < 1e-6)
        #expect(simd_length(h.apply(grey, gamut: .rec709) - grey) < 1e-6)
        #expect(h.apply(hiPx, gamut: .rec709).x > 1.5)
        #expect(simd_length(s.apply(hiPx, gamut: .rec709) - hiPx) < 1e-6)
        #expect(simd_length(s.apply(grey, gamut: .rec709) - grey) < 1e-6)
        #expect(s.apply(shadowPx, gamut: .rec709).x > 0.05)
        // tiny luminance untouched
        let tiny = SIMD3<Float>(repeating: 1e-6)
        #expect(simd_length(s.apply(tiny, gamut: .rec709) - tiny) == 0)
    }

    @Test func temperatureDirection() {
        let grey = SIMD3<Float>(repeating: 0.5)
        for g in gamuts {
            var w = ColorCorrection(); w.temperature = 50
            var k = ColorCorrection(); k.temperature = -50
            let ow = w.apply(grey, gamut: g), ok = k.apply(grey, gamut: g)
            #expect(ow.x / ow.z > 1 && ok.x / ok.z < 1)
            #expect(ow.x / ow.z > ok.x / ok.z)
        }
    }

    @Test func tintDirection() {
        let grey = SIMD3<Float>(repeating: 0.5)
        for g in gamuts {
            var m = ColorCorrection(); m.tint = 50
            var gr = ColorCorrection(); gr.tint = -50
            let om = m.apply(grey, gamut: g), og = gr.apply(grey, gamut: g)
            #expect(om.x / om.y > 1 && om.z / om.y > 1, "magenta for +tint")
            #expect(og.x / og.y < 1 && og.z / og.y < 1, "green for -tint")
        }
    }

    @Test func rangeClamped() {
        var c = ColorCorrection(); c.exposure = 40
        let o = c.apply([0.1, 0.1, 0.1], gamut: .rec709)
        #expect(abs(o.x - 0.1 * 16) < 1e-5)
    }
}

@Suite struct ToneMappingTests {
    let tm = ToneMapping()

    @Test func identityBelowKnee() {
        let v = SIMD3<Float>(0.8, 0.3, 0.1)
        #expect(tm.apply(v) == v)
        #expect(tm.apply(SIMD3(-0.2, 0.5, 0.1)) == SIMD3(-0.2, 0.5, 0.1))
    }

    @Test func continuityAndC1AtKnee() {
        let k = tm.knee, e: Float = 1e-3
        let below = tm.mapMax(k - e), above = tm.mapMax(k + e), at = tm.mapMax(k)
        #expect(abs(at - k) < 1e-7)
        let dBelow = (at - below) / e, dAbove = (above - at) / e
        #expect(abs(dBelow - 1) < 1e-3)
        #expect(abs(dAbove - 1) < 6e-3)
    }

    @Test func monotonicAndBelowOne() {
        var prev: Float = 0
        var m: Float = 0
        while m <= 3 {
            let o = tm.mapMax(m)
            #expect(o >= prev)
            #expect(o < 1)
            prev = o
            m += 0.01
        }
        #expect(tm.mapMax(38) <= 1)
    }

    @Test func kneeAboveOneIsClamped() {
        let t = ToneMapping(knee: 5)
        #expect(t.knee == 0.99)
        for m: Float in [0.5, 1, 2, 10, 38] {
            let o = t.apply(SIMD3(repeating: m))
            #expect(o.x.isFinite && o.x <= 1)
        }
        #expect(ToneMapping(knee: -1).knee == 0)
    }

    @Test func hueAndRatioPreserved() {
        let o = tm.apply(SIMD3(1.5, 0.75, 0.375))
        #expect(abs(o.x / o.y - 2) < 1e-5 && abs(o.y / o.z - 2) < 1e-5)
        #expect(max(o.x, o.y, o.z) < 1)
    }
}
