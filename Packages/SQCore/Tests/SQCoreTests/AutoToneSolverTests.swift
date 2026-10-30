import Testing
@testable import SQCore

/// Auto Tone maths: synthetic luma histograms (display-encoded, as the Program monitor shows the clip) give expected
/// Basic Correction values; the result is absolute (the shown frame is un-toned through the current values first), so
/// pressing twice changes nothing and the starting values do not matter.
@Suite struct AutoToneSolverTests {
    typealias S = AutoToneSolver
    static func ramp(_ lo: Float, _ hi: Float, n: Int = 1000) -> [Float] { (0..<n).map { lo + (hi - lo) * Float($0) / Float(n - 1) } }
    static func shown(_ raw: [Float], _ b: BasicCorrection) -> [Float] { raw.map { S.tone($0, b) } }
    static func pct(_ v: [Float], _ p: Float) -> Float { let s = v.sorted(); return s[Int(Float(s.count - 1) * p)] }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func toneAndUntoneRoundTrip(_ m: BasicToneModel) {
        var b = BasicCorrection(model: m)
        b.exposure = 1.3; b.contrast = 25; b.shadows = 30; b.highlights = -40; b.whites = 20; b.blacks = -35
        for y in stride(from: Float(0), through: 1.2, by: 0.05) {
            #expect(abs(S.untone(S.tone(y, b), b) - y) < 1e-4)
        }
        #expect(S.tone(0.37, BasicCorrection(model: m)) == 0.37, "neutral is the identity")
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func darkPictureIsBrightenedWithoutClipping(_ m: BasicToneModel) throws {
        let raw = Self.ramp(0.02, 0.4)
        let b = try #require(S.solveTone(luma: raw, current: BasicCorrection(model: m)))
        #expect(b.exposure > 0.3)
        let out = Self.shown(raw, b)
        #expect(abs(Self.pct(out, 0.995) - S.whiteTarget) < 0.01, "bright end lands just under white")
        #expect(Self.pct(out, 0.5) >= S.midBand.lowerBound - 0.01)
        #expect(out.max()! <= 1.0)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func brightPictureIsDarkened(_ m: BasicToneModel) throws {
        let raw = Self.ramp(0.5, 0.98)
        let b = try #require(S.solveTone(luma: raw, current: BasicCorrection(model: m)))
        #expect(b.exposure < 0)
        #expect(Self.pct(Self.shown(raw, b), 0.5) <= S.midBand.upperBound + 0.01)
        #expect(b.whites >= 0 && b.blacks <= 0)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func lowContrastPictureGetsStretchedAndSomeContrast(_ m: BasicToneModel) throws {
        let raw = Self.ramp(0.3, 0.6)
        let b = try #require(S.solveTone(luma: raw, current: BasicCorrection(model: m)))
        #expect(b.contrast > 0 && b.contrast <= S.maxContrast)
        #expect(b.blacks < 0 && b.whites > 0)
        let out = Self.shown(raw, b)
        let spread = Self.pct(out, 0.995) - Self.pct(out, 0.005)
        // The Lumetri-matched Contrast and Blacks are gentler than the legacy linear ones (ends fixed, hinged black).
        #expect(spread > (m == .legacy ? 0.55 : 0.5), "range was 0.3, now \(spread)")
        #expect(Self.pct(out, 0.005) >= S.blackTarget - 0.005 && Self.pct(out, 0.995) <= S.whiteTarget + 0.005)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func pressingTwiceChangesNothing(_ m: BasicToneModel) throws {
        for raw in [Self.ramp(0.02, 0.4), Self.ramp(0.5, 0.98), Self.ramp(0.3, 0.6), Self.ramp(0.1, 0.55), Self.ramp(0.15, 0.97)] {
            let first = try #require(S.solveTone(luma: raw, current: BasicCorrection(model: m)))
            #expect(S.solveTone(luma: Self.shown(raw, first), current: first) == nil)
        }
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func resultDoesNotDependOnTheStartingValues(_ m: BasicToneModel) throws {
        let raw = Self.ramp(0.08, 0.5)
        let fromNeutral = try #require(S.solveTone(luma: raw, current: BasicCorrection(model: m)))
        var start = BasicCorrection(model: m); start.exposure = -1.2; start.contrast = -30; start.whites = 40; start.blacks = 25
        start.temperature = 12; start.saturation = 130
        let fromGraded = try #require(S.solveTone(luma: Self.shown(raw, start), current: start))
        #expect(abs(fromGraded.exposure - fromNeutral.exposure) <= 0.011)
        #expect(abs(fromGraded.contrast - fromNeutral.contrast) <= 0.11)
        #expect(abs(fromGraded.whites - fromNeutral.whites) <= 0.11)
        #expect(abs(fromGraded.blacks - fromNeutral.blacks) <= 0.11)
        #expect(fromGraded.temperature == 12 && fromGraded.saturation == 130, "color controls stay")
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func shadowsAndHighlightsAreKept(_ m: BasicToneModel) throws {
        var start = BasicCorrection(model: m); start.shadows = 40; start.highlights = -30
        let raw = Self.ramp(0.05, 0.45)
        let b = try #require(S.solveTone(luma: Self.shown(raw, start), current: start))
        #expect(b.shadows == 40 && b.highlights == -30)
        #expect(Self.pct(Self.shown(raw, b), 0.995) <= S.whiteTarget + 0.005)
        #expect(S.solveTone(luma: Self.shown(raw, b), current: b) == nil)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func fullRangeFlatAndEmptyPicturesAreLeftAlone(_ m: BasicToneModel) {
        #expect(S.solveTone(luma: Self.ramp(0, 1), current: BasicCorrection(model: m)) == nil)
        #expect(S.solveTone(luma: Self.ramp(0.4, 0.42), current: BasicCorrection(model: m)) == nil, "flat frame: nothing to stretch")
        #expect(S.solveTone(luma: [], current: BasicCorrection(model: m)) == nil)
        #expect(S.solveTone(luma: [.nan, .infinity], current: BasicCorrection(model: m)) == nil)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func slidersStayInRangeAndNothingClips(_ m: BasicToneModel) {
        let cases: [[Float]] = [Self.ramp(0.001, 0.07), Self.ramp(0.0, 0.3), Self.ramp(0.7, 1.0), Self.ramp(0.45, 0.55),
                                Self.ramp(0.2, 1.4), { var l = Self.ramp(0.25, 0.6); l[0] = 0; l[1] = 1; return l }()]
        for raw in cases {
            guard let b = S.solveTone(luma: raw, current: BasicCorrection(model: m)) else { continue }
            #expect(abs(b.exposure) <= 5 && (0...S.maxContrast).contains(b.contrast))
            #expect((0...100).contains(b.whites) && (-100...0).contains(b.blacks))
            let out = Self.shown(raw, b)
            let hiIn = Self.pct(raw, 0.995), hiOut = Self.pct(out, 0.995)
            #expect(hiOut <= max(S.whiteTarget, hiIn) + 0.005, "never pushes the bright end into clipping")
            #expect(Self.pct(out, 0.005) >= min(S.blackTarget, Self.pct(raw, 0.005)) - 0.005, "never crushes past the black target")
        }
        var hot = BasicCorrection(model: m); hot.exposure = 4.9
        let c = S.solveTone(luma: Self.shown(Self.ramp(0.0005, 0.01), hot), current: hot)
        #expect((c?.exposure ?? 0) <= 5)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func whiteBalanceGainIsTakenIntoTheToneSolve(_ m: BasicToneModel) throws {
        // A new white balance that brightens grays by 30 % (linear, before Exposure) must be solved as if already there:
        // the bright end then still lands at the white target, and the result equals solving the brightened picture.
        let raw = Self.ramp(0.05, 0.6)
        let gain: Float = 1.3
        let b = try #require(S.solveTone(luma: raw, current: BasicCorrection(model: m), linearGain: gain))
        let brightened = raw.map { S.oetf(S.inverseOETF($0) * gain) }
        let ref = try #require(S.solveTone(luma: brightened, current: BasicCorrection(model: m)))
        #expect(b == ref)
        #expect(Self.pct(Self.shown(brightened, b), 0.995) <= S.whiteTarget + 0.005)
    }

    // MARK: When Auto Tone can measure

    @Test func blockedForNonRec709SourcesInputLUTsSwitchedOffBasicAndLaterStages() {
        var e = ColorEffect(id: 1, inputLUT: .automatic)
        #expect(S.blockReason(effect: e, source: .rec709) == nil, "automatic Input LUT on Rec.709 does nothing")
        for s in ColorSpaceID.allCases where s != .rec709 { #expect(S.blockReason(effect: e, source: s) != nil, "\(s)") }
        var lut = e; lut.inputLUT = .file("/x.cube")
        #expect(S.blockReason(effect: lut, source: .rec709) != nil)
        var off = e; off.setEnabled(.basicCorrection, false)
        #expect(S.blockReason(effect: off, source: .rec709) != nil)
        var later = e; later.creative.fadedFilm = 20
        #expect(S.blockReason(effect: later, source: .rec709) != nil)
        later.setEnabled(.creative, false)
        #expect(S.blockReason(effect: later, source: .rec709) == nil, "a switched-off section is not in the picture")
        var curves = e; curves.curves.master = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        #expect(S.blockReason(effect: curves, source: .rec709) != nil)
        var hue = e; hue.hueCurves.hueVsSat = [CurvePoint(0, 0.7), CurvePoint(1, 0.5)]
        #expect(S.blockReason(effect: hue, source: .rec709) != nil)
        var wheels = e; wheels.wheels.midtonesLuma = 10
        #expect(S.blockReason(effect: wheels, source: .rec709) != nil)
        var vig = e; vig.vignette.amount = -1
        #expect(S.blockReason(effect: vig, source: .rec709) != nil)
        e.basic.saturation = 140; e.basic.shadows = 30
        #expect(S.blockReason(effect: e, source: .rec709) == nil, "Basic Correction's own values are un-toned")
    }

    // MARK: White balance sample

    @Test func neutralSampleAveragesNearGreyPixelsOnly() throws {
        let cast = SIMD3<Float>(1.08, 1, 0.9)
        var px = (0..<400).map { i in cast * (0.05 + 0.4 * Float(i) / 400) }
        px += Array(repeating: SIMD3<Float>(0.6, 0.02, 0.02), count: 100)   // a saturated red object
        let s = try #require(S.neutralSample(px))
        #expect(abs(s.x / s.y - 1.08) < 0.01 && abs(s.z / s.y - 0.9) < 0.01, "the red object is ignored")
    }

    @Test func neutralSampleSkipsNeutralStrongCastAndColourfulFrames() {
        #expect(S.neutralSample((0..<400).map { SIMD3(repeating: 0.02 + Float($0) / 1000) }) == nil, "already neutral")
        #expect(S.neutralSample((0..<400).map { SIMD3<Float>(1.6, 1, 0.5) * (0.02 + Float($0) / 1000) }) == nil,
                "a strong cast is treated as intended (sunset, tungsten mood)")
        #expect(S.neutralSample(Array(repeating: SIMD3<Float>(0.5, 0.05, 0.4), count: 400)) == nil, "no gray pixels")
        #expect(S.neutralSample([]) == nil)
    }
}
