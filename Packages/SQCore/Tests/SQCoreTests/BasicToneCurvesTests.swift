import Foundation
import Testing
@testable import SQCore

/// Lumetri-matched Basic Correction tone curves (docs/research/COLOR-CORRECTION-MATH.md): numbers on the Rec.709 signal
/// (0...1 = 0...100 IRE), plus the model flag that keeps old projects on the legacy maths.
@Suite struct BasicToneCurvesTests {
    typealias C = BasicToneCurves
    static let grid: [Float] = stride(from: Float(-0.5), through: 1.5, by: 0.01).map { $0 }
    static let amounts: [Float] = [-1, -0.75, -0.5, -0.25, -0.1, 0.1, 0.25, 0.5, 0.75, 1]

    static func monotone(_ f: (Float) -> Float) -> Bool {
        var prev = -Float.infinity
        for x in grid { let y = f(x); if !(y > prev) { return false }; prev = y }
        return true
    }

    static func isMonotone(_ f: (Float, Float) -> Float, _ a: Float) -> Bool { monotone { f($0, a) } }

    /// Grid point (0...1) where `f(x, 1) - x` is largest.
    static func peak(_ f: (Float, Float) -> Float) -> Float {
        var best: Float = 0, bestD = -Float.infinity
        for x in stride(from: Float(0), through: 1, by: 0.01) { let d = f(x, 1) - x; if d > bestD { bestD = d; best = x } }
        return best
    }

    // MARK: Contrast

    @Test func contrastKeepsMidGreyBlackAndWhite() {
        for c in Self.amounts {
            #expect(abs(C.contrast(0.5, c) - 0.5) < 1e-6, "mid gray stays at 50 IRE (c \(c))")
            #expect(abs(C.contrast(0, c)) < 1e-6 && abs(C.contrast(1, c) - 1) < 1e-6, "ends stay (c \(c))")
        }
        #expect(C.contrast(0.3, 0) == 0.3, "0 is the identity")
    }

    @Test func contrastIsAnSCurveUpAndAnInverseSCurveDown() {
        // +50: 25 IRE goes down, 75 IRE up by the same amount (symmetric about the pivot).
        let lo = C.contrast(0.25, 0.5), hi = C.contrast(0.75, 0.5)
        #expect(lo < 0.25 && hi > 0.75)
        #expect(abs((0.25 - lo) - (hi - 0.75)) < 1e-5)
        #expect(abs(lo - 0.2) < 1e-4, "+50 puts 25 IRE at 20 IRE")
        let flo = C.contrast(0.25, -0.5), fhi = C.contrast(0.75, -0.5)
        #expect(flo > 0.25 && fhi < 0.75)
        // +100 is strong but never clips: 10 IRE stays above black.
        #expect(C.contrast(0.1, 1) > 0.02 && C.contrast(0.9, 1) < 0.98)
        // -100 does not flatten to gray: the ramp keeps half its slope at the pivot.
        #expect(C.contrast(0.75, -1) - C.contrast(0.25, -1) > 0.3)
    }

    @Test func contrastNeverFolds() {
        for c in Self.amounts { #expect(Self.isMonotone(C.contrast, c), "c \(c)") }
    }

    // MARK: Highlights / Shadows

    @Test func highlightsAndShadowsKeepTheEnds() {
        for a in Self.amounts {
            #expect(C.highlights(0, a) == 0 && C.highlights(1, a) == 1)
            #expect(C.shadows(0, a) == 0 && C.shadows(1, a) == 1)
        }
    }

    @Test func shadowsBarelyMoveHighlightsAndHighlightsBarelyMoveShadows() {
        // Shadows +50: 25 IRE clearly up, 90 IRE nearly still.
        #expect(C.shadows(0.25, 0.5) - 0.25 > 0.04)
        #expect(abs(C.shadows(0.9, 0.5) - 0.9) < 0.01)
        #expect(C.shadows(0.25, -0.5) < 0.25 - 0.04)
        // Highlights +50: 75 IRE clearly up, 10 IRE nearly still.
        #expect(C.highlights(0.75, 0.5) - 0.75 > 0.03)
        #expect(abs(C.highlights(0.1, 0.5) - 0.1) < 0.01)
        #expect(C.highlights(0.75, -0.5) < 0.75 - 0.03)
        // The bump peaks where it should: shadows around 33 IRE, highlights around 67 IRE.
        let sPeak = Self.peak(C.shadows), hPeak = Self.peak(C.highlights)
        #expect(abs(sPeak - 1.0 / 3) < 0.02 && abs(hPeak - 2.0 / 3) < 0.02)
    }

    @Test func highlightsAndShadowsNeverFoldAndStayInRange() {
        for a in Self.amounts {
            #expect(Self.isMonotone(C.highlights, a), "h \(a)")
            #expect(Self.isMonotone(C.shadows, a), "s \(a)")
            for x in stride(from: Float(0), through: 1, by: 0.05) {
                #expect((0...1).contains(C.highlights(x, a)) && (0...1).contains(C.shadows(x, a)))
            }
        }
    }

    // MARK: Whites / Blacks

    @Test func whitesIsAGainAboutBlack() {
        #expect(C.whites(0, 1) == 0)
        #expect(abs(C.whites(0.5, 1) / 0.5 - exp2f(C.whitesStops)) < 1e-5)
        #expect(abs(C.whites(0.8, -1) / 0.8 - exp2f(-C.whitesStops)) < 1e-5)
        #expect(C.whites(0.4, 0) == 0.4)
    }

    @Test func blacksHingeLowAndLeaveHighlights() {
        // +100 lifts black to 20 IRE, mid gray a little, 90 IRE almost not at all.
        #expect(abs(C.blacks(0, 1) - 0.2) < 1e-6)
        #expect(C.blacks(0.5, 1) - 0.5 < 0.06)
        #expect(abs(C.blacks(0.9, 1) - 0.9) < 0.003)
        #expect(C.blacks(1, 1) == 1 && C.blacks(1, -1) == 1)
        // -100 pushes the darkest ~15 IRE to black or below (the display clips them), 50 IRE only to ~45.
        #expect(C.blacks(0.14, -1) <= 0.0)
        #expect(abs(C.blacks(0.5, -1) - 0.45) < 0.01)
        for b in Self.amounts { #expect(Self.isMonotone(C.blacks, b), "b \(b)") }
    }

    // MARK: Exposure

    @Test func exposureDownIsAGainAndUpRollsOffIntoWhite() {
        #expect(abs(C.exposure(0.5, -1) - 0.25) < 1e-6, "-1 halves linear light")
        #expect(abs(C.exposure(0.05, 1) - 0.1) < 1e-6, "below the knee +1 doubles")
        for ev: Float in [0.1, 0.5, 1, 2, 5] {
            #expect(abs(C.exposure(1, ev) - 1) < 1e-5, "white stays white at +\(ev)")
            #expect(C.exposure(0.9, ev) < 1, "nothing below white clips at +\(ev)")
            var prev = -Float.infinity
            for x in stride(from: Float(-0.2), through: 4, by: 0.01) {
                let y = C.exposure(x, ev); #expect(y > prev); prev = y
            }
        }
        // Mid gray (18 %) rises nearly a full stop at +1.
        #expect(log2f(C.exposure(0.18, 1) / 0.18) > 0.85)
        #expect(abs(C.exposure(0.4, 0.0001) - 0.4) < 1e-3, "continuous at 0")
    }

    @Test func exposureUpNeverDarkensAndIsMonotoneInStops() {
        // Superwhites: +ev must not pull them below the input (review: 2.0 -> 1.62 at +0.5, 1.1 -> 1.04 at +1).
        #expect(C.exposure(2, 0.5) >= 2)
        #expect(C.exposure(1.1, 1) >= 1.1)
        for x in stride(from: Float(0), through: 4, by: 0.05) {
            var prev = x
            for ev in stride(from: Float(0.05), through: 5, by: 0.05) {
                let y = C.exposure(x, ev)
                #expect(y >= x - 1e-5, "x \(x) ev \(ev) darkened to \(y)")
                #expect(y >= prev - 1e-5, "x \(x) not monotone at ev \(ev)")
                prev = y
            }
        }
        // Above the shoulder the slope is at least 1.
        for ev: Float in [0.5, 1, 3] {
            #expect(C.exposure(1.6, ev) - C.exposure(1.5, ev) >= 0.1 - 1e-5)
        }
    }

    // MARK: Gray-axis tone of the Lumetri model

    @Test func neutralToneIsTheIdentityAndRangesMapSensibly() {
        let b = BasicCorrection()
        #expect(b.model == .lumetri)
        for y in stride(from: Float(0), through: 1, by: 0.1) { #expect(C.tone(y, b) == y) }
        // Every slider at +-100 keeps black at or below 0.2 and never maps mid gray outside 0...1.
        for key in [\BasicCorrection.contrast, \.highlights, \.shadows, \.whites, \.blacks] {
            for v: Float in [-100, 100] {
                var t = BasicCorrection(); t[keyPath: key] = v
                #expect((0...1).contains(C.tone(0.5, t)))
            }
        }
    }

    // MARK: Model flag

    @Test func newGradesUseTheLumetriMathsAndOldOnesKeepTheLegacyMaths() throws {
        #expect(BasicCorrection().model == .lumetri)
        #expect(ColorEffect(id: 1).basic.model == .lumetri)
        // An old Basic Correction (no model key) with moved sliders reads as legacy; an untouched one as current.
        let old = #"{"temperature":0,"tint":0,"exposure":0,"contrast":40,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0}"#
        let neutral = #"{"temperature":0,"tint":0,"exposure":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0}"#
        #expect(try JSONDecoder().decode(BasicCorrection.self, from: Data(old.utf8)).model == .legacy)
        #expect(try JSONDecoder().decode(BasicCorrection.self, from: Data(neutral.utf8)).model == .lumetri)
        // Round trip keeps the flag.
        var legacy = BasicCorrection(model: .legacy); legacy.contrast = 40
        let back = try JSONDecoder().decode(BasicCorrection.self, from: JSONEncoder().encode(legacy))
        #expect(back == legacy)
        // Neutral ignores the flag.
        #expect(BasicCorrection(model: .legacy).isNeutral)
        // A model from a newer build (unknown raw value) falls back to the current maths instead of failing the load.
        let future = #"{"temperature":0,"tint":0,"exposure":0,"contrast":40,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":100,"vibrance":0,"model":7}"#
        let f = try JSONDecoder().decode(BasicCorrection.self, from: Data(future.utf8))
        #expect(f.model == .current)
        #expect(f.contrast == 40)
    }

    @Test func aStoredColourEffectWithoutTheFlagRendersWithTheLegacyMaths() throws {
        var e = ColorEffect(id: 1, inputLUT: .automatic); e.basic.contrast = 30
        var fx = ClipEffect.colorGrade(e)
        #expect(fx.parameters[ClipEffect.colorBasicModelKey]?.value == 1)
        #expect(fx.colorEffect(atLocal: nil, id: 1).basic.model == .lumetri)
        // Simulate a v27 file written before the flag existed.
        fx.parameters[ClipEffect.colorBasicModelKey] = nil
        let decoded = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(fx))
        #expect(decoded.colorEffect(atLocal: nil, id: 1).basic.model == .legacy)
        #expect(decoded.parameters[ClipEffect.colorBasicModelKey]?.value == 0, "pinned on load")
        // Moving a slider later (any panel) keeps it legacy.
        var moved = decoded
        moved.parameters[ClipEffect.colorContrastKey]?.value = 0
        #expect(moved.colorEffect(atLocal: nil, id: 1).basic.model == .legacy)
        // An untouched old effect loads with the current maths.
        var plain = ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic))
        plain.parameters[ClipEffect.colorBasicModelKey] = nil
        let plainBack = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(plain))
        #expect(plainBack.colorEffect(atLocal: nil, id: 1).basic.model == .lumetri)
    }

    @Test func theFlagIsHiddenFromEffectControlsAndSetForNewEffects() {
        #expect(!ColorGradeFields.params.contains { $0.key == ClipEffect.colorBasicModelKey })
        #expect(ClipEffect.defaultParameters(for: ClipEffect.colorKind)[ClipEffect.colorBasicModelKey]?.value == 1)
    }

    @Test func anEditOnALegacyEffectStaysLegacyAndAResetCanUpgrade() throws {
        var e = ColorEffect(id: 1, inputLUT: .automatic); e.basic.model = .legacy; e.basic.shadows = 20
        var fx = ClipEffect.colorGrade(e)
        let base = fx.colorEffect(atLocal: nil, id: 1)
        var edited = base; edited.basic.shadows = 35
        let did = fx.applyColorEdit(from: base, to: edited, atLocal: nil)
        #expect(did)
        #expect(fx.colorEffect(atLocal: nil, id: 1).basic == edited.basic)
        #expect(fx.colorEffect(atLocal: nil, id: 1).basic.model == .legacy)
        var reset = edited; reset.basic = BasicCorrection()
        let didReset = fx.applyColorEdit(from: edited, to: reset, atLocal: nil)
        #expect(didReset)
        #expect(fx.colorEffect(atLocal: nil, id: 1).basic.model == .lumetri)
    }
}
