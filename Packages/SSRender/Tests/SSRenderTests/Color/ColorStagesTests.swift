import Testing
import simd
import SSCore
@testable import SSRender

/// Lumetri-like block maths (ColorStages.swift). `post`: the block runs on the display signal (after the Input LUT);
/// `pre`: on source-linear light before it. For a Rec.709 source both positions see the same picture.
@Suite struct ColorStagesTests {
    static let luma = Gamut.rec709.lumaRow
    static func y(_ v: SIMD3<Float>) -> Float { simd_dot(luma, v) }
    static func grey(_ v: Float) -> SIMD3<Float> { SIMD3(repeating: v) }

    static func basic(_ f: (inout BasicCorrection) -> Void) -> PreparedBasic {
        var b = BasicCorrection(); f(&b)
        return PreparedBasic(b, gamut: .rec709)
    }
    static func post(_ b: PreparedBasic, _ t: SIMD3<Float>) -> SIMD3<Float> { b.apply(t, pre: false) }
    static func chroma(_ v: SIMD3<Float>) -> Float { max(v.x, v.y, v.z) - min(v.x, v.y, v.z) }

    // MARK: Basic Correction

    @Test func neutralBasicIsIdentityInBothPositions() {
        let b = Self.basic { _ in }
        for t in [SIMD3<Float>(0.2, 0.5, 0.9), [-0.1, 0.3, 1.4], [0, 0, 0]] {
            #expect(simd_length(b.apply(t, pre: false) - t) == 0)
            #expect(simd_length(b.apply(t, pre: true) - t) == 0)
        }
    }

    @Test func positionsAgreeForRec709Source() {
        // pre: linear in (decoded), maths on OETF(linear); post: the encoded signal itself. Same picture, same result.
        let b = Self.basic {
            $0.temperature = 30; $0.tint = -20; $0.exposure = 0.5; $0.contrast = 40; $0.highlights = -40; $0.shadows = 50
            $0.whites = 20; $0.blacks = -10; $0.saturation = 130; $0.vibrance = 40
        }
        for enc in [SIMD3<Float>(0.2, 0.5, 0.9), [0.05, 0.04, 0.03], [0.7, 0.6, 0.2]] {
            let viaPost = Self.post(b, enc)
            let viaPre = TransferFunctions.bt709OETF(b.apply(TransferFunctions.bt709InverseOETF(enc), pre: true))
            #expect(simd_length(viaPre - viaPost) < 2e-5, "\(enc)")
        }
    }

    @Test func exposureIsAGainInLinearLight() {
        let b = Self.basic { $0.exposure = 1 }
        let t = Self.grey(0.4)
        #expect(abs(TransferFunctions.bt709InverseOETF(Self.post(b, t).x) - 2 * TransferFunctions.bt709InverseOETF(0.4)) < 1e-5)
        let d = Self.basic { $0.exposure = -2 }
        #expect(abs(TransferFunctions.bt709InverseOETF(Self.post(d, t).x) - TransferFunctions.bt709InverseOETF(0.4) / 4) < 1e-5)
    }

    @Test func temperatureAndTintDirections() {
        let warm = Self.post(Self.basic { $0.temperature = 50 }, Self.grey(0.5))
        #expect(warm.x > warm.z, "positive temperature = warmer")
        let cool = Self.post(Self.basic { $0.temperature = -50 }, Self.grey(0.5))
        #expect(cool.z > cool.x)
        let magenta = Self.post(Self.basic { $0.tint = 50 }, Self.grey(0.5))
        #expect(magenta.y < magenta.x && magenta.y < magenta.z, "positive tint = magenta")
        let green = Self.post(Self.basic { $0.tint = -50 }, Self.grey(0.5))
        #expect(green.y > green.x && green.y > green.z)
    }

    @Test func contrastPivotsAroundMidAndIsMonotone() {
        let up = Self.basic { $0.contrast = 60 }
        #expect(abs(Self.post(up, Self.grey(0.45)).x - 0.45) < 1e-6)
        #expect(Self.post(up, Self.grey(0.7)).x > 0.7 && Self.post(up, Self.grey(0.2)).x < 0.2)
        let down = Self.basic { $0.contrast = -60 }
        #expect(Self.post(down, Self.grey(0.7)).x < 0.7 && Self.post(down, Self.grey(0.2)).x > 0.2)
    }

    @Test func highlightsAffectBrightAreasAndShadowsAffectDarkAreas() {
        let hiDown = Self.basic { $0.highlights = -100 }
        #expect(Self.post(hiDown, Self.grey(0.9)).x < 0.75, "pulls highlights down")
        #expect(abs(Self.post(hiDown, Self.grey(0.1)).x - 0.1) < 1e-4, "leaves darks alone")
        let shUp = Self.basic { $0.shadows = 100 }
        #expect(Self.post(shUp, Self.grey(0.15)).x > 0.3, "lifts shadows")
        #expect(Self.post(shUp, Self.grey(0.95)).x == 0.95, "leaves highlights alone")
        #expect(Self.post(shUp, Self.grey(0)).x == 0, "true black stays black")
        let shDown = Self.basic { $0.shadows = -100 }
        #expect(Self.post(shDown, Self.grey(0.15)).x < 0.1)
    }

    @Test func whitesAndBlacksMoveTheEndpoints() {
        let whites = Self.basic { $0.whites = 100 }
        #expect(abs(Self.post(whites, Self.grey(0)).x) < 1e-6, "blacks untouched by whites")
        #expect(Self.post(whites, Self.grey(0.8)).x >= 0.99, "white point pulled down so 0.8 reaches white")
        let whitesDown = Self.basic { $0.whites = -100 }
        #expect(Self.post(whitesDown, Self.grey(1)).x < 0.85)
        let blacks = Self.basic { $0.blacks = 100 }
        #expect(Self.post(blacks, Self.grey(0)).x > 0.05, "positive blacks lift black")
        #expect(abs(Self.post(blacks, Self.grey(1)).x - 1) < 1e-6)
        let blacksDown = Self.basic { $0.blacks = -100 }
        #expect(Self.post(blacksDown, Self.grey(0.05)).x <= 0.0001, "negative blacks crush")
    }

    @Test func saturationAndVibrance() {
        let c = SIMD3<Float>(0.7, 0.45, 0.3)
        let desat = Self.post(Self.basic { $0.saturation = 0 }, c)
        #expect(Self.chroma(desat) < 1e-6 && abs(desat.x - Self.y(c)) < 1e-6, "0 = luma grey")
        #expect(abs(Self.chroma(Self.post(Self.basic { $0.saturation = 200 }, c)) - 2 * Self.chroma(c)) < 1e-5)
        // Luma preserved by saturation.
        #expect(abs(Self.y(Self.post(Self.basic { $0.saturation = 170 }, c)) - Self.y(c)) < 1e-6)
        // Vibrance: a muted colour gains proportionally more than an already saturated one; skin-like hues gain less.
        let v = Self.basic { $0.vibrance = 100 }
        let muted = SIMD3<Float>(0.45, 0.5, 0.55)      // bluish, low saturation
        let vivid = SIMD3<Float>(0.1, 0.3, 0.9)        // saturated blue
        let gainMuted = Self.chroma(Self.post(v, muted)) / Self.chroma(muted)
        let gainVivid = Self.chroma(Self.post(v, vivid)) / Self.chroma(vivid)
        #expect(gainMuted > gainVivid + 0.3)
        let skin = SIMD3<Float>(0.75, 0.55, 0.45)
        let gainSkin = Self.chroma(Self.post(v, skin)) / Self.chroma(skin)
        let bluish = SIMD3<Float>(0.45, 0.55, 0.75)    // same saturation, non-skin hue
        let gainBlue = Self.chroma(Self.post(v, bluish)) / Self.chroma(bluish)
        #expect(gainSkin < gainBlue)
        let neg = Self.basic { $0.vibrance = -100 }
        #expect(Self.chroma(Self.post(neg, vivid)) < 0.3 * Self.chroma(vivid), "negative vibrance mutes saturated colours hardest")
    }

    @Test func toneControlsKeepGreyRampsMonotone() {
        // Extreme settings must never fold the tone curve.
        var rng = LCG(s: 11)
        for _ in 0..<200 {
            let vals = (0..<5).map { _ in rng.next() * 200 - 100 }
            let b = Self.basic { $0.contrast = vals[0]; $0.highlights = vals[1]; $0.shadows = vals[2]; $0.whites = vals[3]; $0.blacks = vals[4] }
            var last = -Float.infinity
            for i in 0...200 {
                let v = Self.post(b, Self.grey(Float(i) / 200)).x
                #expect(v >= last - 1e-5, "non-monotone at \(i): \(vals)")
                last = v
            }
        }
    }

    @Test func toneControlsAreHueNeutralOnGrey() {
        let b = Self.basic { $0.contrast = 30; $0.highlights = -30; $0.shadows = 40; $0.whites = 10; $0.blacks = -10; $0.vibrance = 20 }
        for v in stride(from: Float(0), through: 1, by: 0.1) {
            let o = Self.post(b, Self.grey(v))
            #expect(Self.chroma(o) < 1e-6)
        }
    }

    @Test func sourceGamutIsUsedBeforeTheConversion() {
        // Before the conversion the white balance matrix works in the source gamut (S-Gamut3.Cine here).
        var bc = BasicCorrection(); bc.temperature = 40
        let sg = PreparedBasic(bc, gamut: .sGamut3Cine), r709 = PreparedBasic(bc, gamut: .rec709)
        let grey = SIMD3<Float>(repeating: 0.18)
        #expect(simd_length(sg.apply(grey, pre: true) - r709.apply(grey, pre: true)) > 1e-4)
        // Warm = more red than blue.
        #expect(sg.apply(grey, pre: true).x > sg.apply(grey, pre: true).z)
    }

    // MARK: Creative

    @Test func creativeFadedFilmLiftsBlacksAndCompresses() {
        var k = CreativeLook(); k.fadedFilm = 100
        let p = PreparedCreative(k, gamut: .rec709)
        #expect(p.apply(Self.grey(0), pre: false).x > 0.1)
        #expect(p.apply(Self.grey(1), pre: false).x < 1)
        #expect(p.apply(Self.grey(1), pre: false).x > p.apply(Self.grey(0), pre: false).x)
        #expect(PreparedCreative(CreativeLook(), gamut: .rec709).apply(Self.grey(0.3), pre: false) == Self.grey(0.3))
    }

    @Test func creativeTintsColourShadowsAndHighlightsSeparately() {
        var k = CreativeLook()
        k.shadowTint = WheelValue(hue: 240, amount: 1)     // blue
        k.highlightTint = WheelValue(hue: 30, amount: 1)   // orange
        let p = PreparedCreative(k, gamut: .rec709)
        let dark = p.apply(Self.grey(0.1), pre: false), bright = p.apply(Self.grey(0.9), pre: false)
        #expect(dark.z > dark.x, "blue in shadows")
        #expect(bright.x > bright.z, "orange in highlights")
        // The balance slider moves the split: a higher balance tints more of the range with the shadow colour.
        k.tintBalance = 100
        let q = PreparedCreative(k, gamut: .rec709)
        #expect(q.apply(Self.grey(0.5), pre: false).z > p.apply(Self.grey(0.5), pre: false).z)
    }

    // MARK: Wheels

    @Test func wheelsWeightByLuminance() {
        var w = ColorWheels()
        w.shadows = WheelValue(hue: 0, amount: 1)       // red lift
        w.highlights = WheelValue(hue: 120, amount: 1)  // green gain
        let p = PreparedWheels(w, gamut: .rec709)
        let dark = p.apply(Self.grey(0.05), pre: false), mid = p.apply(Self.grey(0.5), pre: false)
        let bright = p.apply(Self.grey(0.95), pre: false)
        #expect(dark.x > dark.y && dark.x > dark.z)
        #expect(simd_length(mid - Self.grey(0.5)) < 0.05, "midtones barely touched by shadow/highlight wheels")
        #expect(bright.y > bright.x && bright.y > bright.z)
    }

    @Test func wheelLuminanceSlidersBrightenAndDarkenTheirRange() {
        var w = ColorWheels()
        w.shadowsLuma = 100
        #expect(PreparedWheels(w, gamut: .rec709).apply(Self.grey(0.05), pre: false).x > 0.15)
        w = ColorWheels(); w.midtonesLuma = 100
        let m = PreparedWheels(w, gamut: .rec709)
        #expect(m.apply(Self.grey(0.5), pre: false).x > 0.58)
        #expect(m.apply(Self.grey(0), pre: false).x == 0)
        w = ColorWheels(); w.highlightsLuma = -100
        #expect(PreparedWheels(w, gamut: .rec709).apply(Self.grey(0.95), pre: false).x < 0.85)
    }

    @Test func wheelsKeepGreyRampLumaMonotone() {
        var rng = LCG(s: 5)
        for _ in 0..<200 {
            var w = ColorWheels()
            w.shadowsLuma = rng.next() * 200 - 100; w.midtonesLuma = rng.next() * 200 - 100
            w.highlightsLuma = rng.next() * 200 - 100
            w.shadows = WheelValue(hue: rng.next() * 360, amount: rng.next())
            w.midtones = WheelValue(hue: rng.next() * 360, amount: rng.next())
            w.highlights = WheelValue(hue: rng.next() * 360, amount: rng.next())
            let p = PreparedWheels(w, gamut: .rec709)
            var last = -Float.infinity
            for i in 0...200 {
                let v = Self.y(p.apply(Self.grey(Float(i) / 200), pre: false))
                #expect(v >= last - 2e-3, "luma non-monotone at \(i): \(w)")
                last = v
            }
        }
    }

    @Test func wheelOffsetIsZeroMeanAndPointsAtTheHue() {
        for h in stride(from: Float(0), to: 360, by: 37) {
            let o = ToneMath.wheelOffset(WheelValue(hue: h, amount: 1))
            #expect(abs(o.x + o.y + o.z) < 1e-6)
        }
        let red = ToneMath.wheelOffset(WheelValue(hue: 0, amount: 1))
        #expect(red.x > 0.6 && red.y < 0 && red.z < 0)
        #expect(ToneMath.wheelOffset(WheelValue(hue: 77, amount: 0)) == .zero)
    }

    // MARK: Vignette

    @Test func vignetteDarkensEdgesNotCentre() {
        var v = Vignette(); v.amount = -3
        let p = PreparedVignette(v)
        let c = Self.grey(0.6)
        let centre = p.apply(c, uv: [0.5, 0.5], aspect: 16.0 / 9, pre: false)
        let corner = p.apply(c, uv: [0.0, 0.0], aspect: 16.0 / 9, pre: false)
        #expect(simd_length(centre - c) < 1e-6)
        #expect(corner.x < 0.35)
        v.amount = 2
        #expect(PreparedVignette(v).apply(c, uv: [0, 0], aspect: 16.0 / 9, pre: false).x > 0.8)
        // Linear-light equivalence of the two positions for a Rec.709 source.
        v.amount = -2
        let q = PreparedVignette(v)
        let post = q.apply(c, uv: [0.1, 0.2], aspect: 1.5, pre: false)
        let pre = TransferFunctions.bt709OETF(q.apply(TransferFunctions.bt709InverseOETF(c), uv: [0.1, 0.2], aspect: 1.5, pre: true))
        #expect(simd_length(post - pre) < 0.03, "gamma-gain approximation of the linear gain stays close")
    }

    @Test func vignetteMidpointAndRoundness() {
        func sample(_ f: (inout Vignette) -> Void) -> Float {
            var v = Vignette(); v.amount = -3; f(&v)
            return PreparedVignette(v).apply(Self.grey(0.6), uv: [0.05, 0.5], aspect: 16.0 / 9, pre: false).x
        }
        // A larger midpoint pulls the vignette towards the centre (darker at the same spot).
        #expect(sample { $0.midpoint = 90 } < sample { $0.midpoint = 10 })
        // Roundness +100: the side is further from the centre in a wide frame than in the frame-shaped ellipse.
        #expect(sample { $0.roundness = 100 } < sample { $0.roundness = 0 })
    }

    // MARK: Curves

    @Test func curvesThroughPointsAreMonotoneAndExact() {
        let pts = [CurvePoint(0, 0), CurvePoint(0.25, 0.4), CurvePoint(0.6, 0.65), CurvePoint(1, 1)]
        for p in pts { #expect(abs(CurveMath.evaluate(pts, p.x) - p.y) < 1e-5) }
        var last: Float = -1
        for i in 0...400 {
            let v = CurveMath.evaluate(pts, Float(i) / 400)
            #expect(v >= last - 1e-6); last = v
        }
        // Flat segments stay flat (no overshoot).
        let flat = [CurvePoint(0, 0.2), CurvePoint(0.5, 0.2), CurvePoint(1, 0.9)]
        #expect(CurveMath.evaluate(flat, 0.25) == 0.2)
        #expect(CurveMath.evaluate(flat, 2) == 0.9, "outside the points: flat")
        // Steep S-curve must not overshoot 0…1.
        let s = [CurvePoint(0, 0), CurvePoint(0.45, 0.05), CurvePoint(0.55, 0.95), CurvePoint(1, 1)]
        for i in 0...200 { let v = CurveMath.evaluate(s, Float(i) / 200); #expect(v >= 0 && v <= 1) }
        // Fewer than two points: the diagonal.
        #expect(abs(CurveMath.evaluate([], 0.3) - 0.3) < 1e-6)
    }

    @Test func identityCurvesDoNothingAndMasterComposesWithChannels() {
        let id = CurveTable(RGBCurves())
        for v in [SIMD3<Float>(0.2, 0.5, 0.9), [-0.1, 0.3, 1.4]] { #expect(simd_length(id.apply(v, pre: false) - v) < 1e-5) }
        var c = RGBCurves()
        c.master = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        c.red = [CurvePoint(0, 0), CurvePoint(1, 0.5)]
        let t = CurveTable(c)
        let o = t.apply(SIMD3(repeating: 0.5), pre: false)
        #expect(abs(o.y - 0.7) < 2e-3 && abs(o.z - 0.7) < 2e-3, "master only for g/b")
        #expect(abs(o.x - 0.35) < 2e-3, "red curve of the master output")
        // Values beyond 1 pass through with their offset (HDR highlights are not clipped).
        let hi = t.apply(SIMD3(repeating: 1.5), pre: false)
        #expect(abs(hi.y - 1.5) < 1e-5)
    }

    // MARK: Hue Saturation Curves

    static func hue(_ f: (inout HueCurves) -> Void) -> PreparedHueCurves {
        var h = HueCurves(); f(&h)
        return PreparedHueCurves(h, gamut: .rec709)
    }
    /// A bump of height `to` (0…1) centred on x in a flat 0.5 curve.
    static func bump(_ x: Float, _ to: Float, wrap: Bool = true) -> [CurvePoint] {
        [CurvePoint(0, 0.5), CurvePoint(max(x - 0.08, 0.01), 0.5), CurvePoint(x, to), CurvePoint(min(x + 0.08, 0.99), 0.5), CurvePoint(1, 0.5)]
    }
    static func hueOf(_ v: SIMD3<Float>) -> Float {
        let mx = max(v.x, v.y, v.z), d = mx - min(v.x, v.y, v.z)
        var h: Float = mx == v.x ? (v.y - v.z) / d : mx == v.y ? (v.z - v.x) / d + 2 : (v.x - v.y) / d + 4
        h /= 6
        return h - floorf(h)
    }

    @Test func flatHueCurvesAreIdentity() {
        let p = Self.hue { _ in }
        for t in [SIMD3<Float>(0.2, 0.5, 0.9), [0.9, 0.1, 0.05], [0.4, 0.4, 0.4], [-0.1, 0.3, 1.4], [0, 0, 0]] {
            #expect(simd_length(p.apply(t, pre: false) - t) < 1e-5, "\(t)")
        }
    }

    @Test func hueVsSatChangesOnlyTheChosenHue() {
        // Boost saturation around red (hue 0 wraps: put the bump on both sides).
        let p = Self.hue { $0.hueVsSat = [CurvePoint(0, 1), CurvePoint(0.08, 0.5), CurvePoint(0.92, 0.5), CurvePoint(1, 1)] }
        let red = SIMD3<Float>(0.8, 0.3, 0.3), blue = SIMD3<Float>(0.3, 0.3, 0.8)
        let r = p.apply(red, pre: false), b = p.apply(blue, pre: false)
        #expect(Self.chroma(r) > Self.chroma(red) * 1.6, "red gets (almost) double saturation")
        #expect(simd_length(b - blue) < 1e-3, "blue is untouched")
        #expect(abs(Self.y(r) - Self.y(red)) < 5e-3, "luma stays")
        // Lowering to 0 removes the colour.
        let down = Self.hue { $0.hueVsSat = [CurvePoint(0, 0), CurvePoint(0.08, 0.5), CurvePoint(0.92, 0.5), CurvePoint(1, 0)] }
        #expect(Self.chroma(down.apply(red, pre: false)) < 0.05)
        // Greys are untouched by hue-keyed curves.
        let grey = SIMD3<Float>(repeating: 0.4)
        #expect(simd_length(p.apply(grey, pre: false) - grey) < 1e-5)
    }

    @Test func hueVsHueRotatesTheHueTowardsTheCurve() {
        let p = Self.hue { $0.hueVsHue = [CurvePoint(0, 0.5), CurvePoint(0.2, 0.5), CurvePoint(1.0 / 3, 1), CurvePoint(0.47, 0.5), CurvePoint(1, 0.5)] }
        let green = SIMD3<Float>(0.2, 0.7, 0.2)
        let o = p.apply(green, pre: false)
        let shift = Self.hueOf(o) - Self.hueOf(green)
        #expect(shift > 0.08 && shift < 0.18, "pushed towards blue by up to 60 degrees: \(shift)")
        #expect(abs(Self.chroma(o) - Self.chroma(green)) < 0.02, "rotation keeps the chroma")
        let red = SIMD3<Float>(0.8, 0.3, 0.3)
        #expect(simd_length(p.apply(red, pre: false) - red) < 1e-3)
    }

    @Test func hueVsLumaAndLumaVsSatAndSatVsSat() {
        let yellow = SIMD3<Float>(0.7, 0.7, 0.2)
        let hl = Self.hue { $0.hueVsLuma = Self.bump(1.0 / 6, 1) }
        #expect(Self.y(hl.apply(yellow, pre: false)) > Self.y(yellow) * 1.5, "up to one stop brighter")
        // Luma vs Sat: desaturate the highlights only.
        let ls = Self.hue { $0.lumaVsSat = [CurvePoint(0, 0.5), CurvePoint(0.5, 0.5), CurvePoint(0.9, 0)] }
        let dark = SIMD3<Float>(0.15, 0.1, 0.3), bright = SIMD3<Float>(0.95, 0.8, 0.7)
        #expect(simd_length(ls.apply(dark, pre: false) - dark) < 1e-3)
        #expect(Self.chroma(ls.apply(bright, pre: false)) < Self.chroma(bright) * 0.5)
        // Sat vs Sat: pull down everything above 70 % saturation (broadcast-safe), keep the muted colours.
        let ss = Self.hue { $0.satVsSat = [CurvePoint(0, 0.5), CurvePoint(0.6, 0.5), CurvePoint(1, 0.15)] }
        let vivid = SIMD3<Float>(0.9, 0.1, 0.1), muted = SIMD3<Float>(0.6, 0.5, 0.45)
        #expect(Self.chroma(ss.apply(vivid, pre: false)) < Self.chroma(vivid) * 0.6)
        #expect(simd_length(ss.apply(muted, pre: false) - muted) < 1e-3)
    }

    @Test func hueCurvesAgreeBetweenPreAndPostForRec709() {
        let p = PreparedHueCurves({
            var h = HueCurves()
            h.hueVsSat = Self.bump(0.6, 0.9); h.hueVsHue = Self.bump(0.1, 0.3); h.lumaVsSat = [CurvePoint(0, 0.4), CurvePoint(1, 0.7)]
            return h }(), gamut: .rec709)
        for enc in [SIMD3<Float>(0.2, 0.5, 0.9), [0.05, 0.04, 0.03], [0.7, 0.6, 0.2]] {
            let viaPost = p.apply(enc, pre: false)
            let viaPre = TransferFunctions.bt709OETF(p.apply(TransferFunctions.bt709InverseOETF(enc), pre: true))
            #expect(simd_length(viaPre - viaPost) < 2e-5)
        }
    }

    @Test func hueCurvesWrapAroundRedSmoothly() {
        // A flat-0.5 curve with only the end points raised: the wrap seam at hue 0 must not show a jump.
        let p = Self.hue { $0.hueVsSat = [CurvePoint(0, 0.8), CurvePoint(0.5, 0.5), CurvePoint(1, 0.8)] }
        let a = p.apply(SIMD3(0.8, 0.30, 0.31), pre: false), b = p.apply(SIMD3(0.8, 0.31, 0.30), pre: false)
        #expect(simd_length(a - b) < 0.035, "the inputs themselves differ by 0.014")
    }
}
