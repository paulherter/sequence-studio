import Testing
import simd
@testable import SSRender

struct SystemRandomNumberGeneratorFixed {
    var s: UInt64
    mutating func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float((s >> 40) & 0xFFFFFF) / Float(0x1000000) + 0.001
    }
}

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

    @Test func saturationHundredIsIdentity() {
        let c = ColorCorrection()
        for g in gamuts { for s in samples { #expect(c.apply(s, gamut: g) == s) } }
    }

    @Test func saturation200IsLogRatioDoubled() {
        var c = ColorCorrection(); c.saturation = 200
        let s = SIMD3<Float>(0.5, 0.2, 0.1)
        let y = simd_dot(Gamut.rec709.lumaRow, s)
        let o = c.apply(s, gamut: .rec709)
        for i in 0..<3 { #expect(abs(log2(o[i] / y) - 2 * log2(s[i] / y)) < 1e-4) }
    }

    @Test func saturationNeverNegativeAndHomogeneous() {
        var rng = SystemRandomNumberGeneratorFixed(s: 11)
        for sat: Float in [0, 50, 150, 200] {
            var c = ColorCorrection(); c.saturation = sat
            for g in gamuts { for _ in 0..<200 {
                let s = SIMD3<Float>(rng.next(), rng.next(), rng.next()) * 4
                let o = c.apply(s, gamut: g)
                #expect(o.x >= 0 && o.y >= 0 && o.z >= 0 && o.x.isFinite && o.y.isFinite && o.z.isFinite)
                let k: Float = 3.7
                let o2 = c.apply(s * k, gamut: g)
                #expect(simd_length(o2 - o * k) <= 1e-4 * max(1, simd_length(o * k)))
            } }
        }
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
        // below the floor the gain is constant (linear extension), shadows lift it
        let tiny = SIMD3<Float>(repeating: 1e-6)
        let lifted = s.apply(tiny, gamut: .rec709)
        #expect(lifted.x >= tiny.x && lifted.x.isFinite)
    }

    @Test func toneCurveIsMonotonicThroughBlackAndFloor() {
        var ys: [Float] = [-0.01, -1e-4, -1e-7, 0]
        let n = 3000
        for i in 0...n { ys.append(powf(10, -8 + 9.6 * Float(i) / Float(n))) }  // 1e-8 … 40
        let floor = PreparedCorrection.minLuma
        ys.append(contentsOf: [floor * 0.999, floor, floor * 1.001]); ys.sort()
        let luma = Gamut.rec709.lumaRow
        let vals: [Float] = [-100, 0, 100]
        var worstJump: Float = 0
        for c in vals { for h in vals { for s in vals {
            var cc = ColorCorrection(); cc.contrast = c; cc.highlights = h; cc.shadows = s
            let p = cc.prepared(for: .rec709)
            var prev: Float = -Float.infinity
            for y in ys {
                let o = simd_dot(luma, p.apply(SIMD3(repeating: y)))
                #expect(o >= prev - 2e-7 * max(abs(o), abs(prev)) - 1e-30, "c=\(c) h=\(h) s=\(s) y=\(y): \(o) < \(prev)")
                prev = o
            }
            let lo = simd_dot(luma, p.apply(SIMD3(repeating: floor * 0.9999))), hi = simd_dot(luma, p.apply(SIMD3(repeating: floor * 1.0001)))
            worstJump = max(worstJump, abs(hi - lo) / max(hi, lo, 1e-30))
        } } }
        #expect(worstJump < 6e-4)  // local slope of the curve is <= ~1.5
        print("tone monotonic sweep: \(ys.count) samples x 27 combos OK, worst relative output change across a 2e-4 input step at the floor \(worstJump)")
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
