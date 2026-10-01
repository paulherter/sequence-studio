import Testing
import simd
import SQCore
@testable import SQRender

/// Basic Correction "Auto": Exposure and Blacks that use the picture's tonal range, added to the current values.
@Suite struct AutoToneTests {
    static func ramp(_ lo: Float, _ hi: Float, n: Int = 1000) -> [Float] { (0..<n).map { lo + (hi - lo) * Float($0) / Float(n - 1) } }
    static func apply(_ b: BasicCorrection, to y: Float) -> Float {
        PreparedBasic(b, gamut: .rec709).apply(SIMD3(repeating: y), pre: false).x
    }

    @Test func brightensADarkPictureToJustBelowWhite() throws {
        let b = try #require(AutoTone.solve(luma: Self.ramp(0.02, 0.5), current: BasicCorrection()))
        #expect(b.exposure > 0.5 && b.exposure <= 5)
        #expect(abs(Self.apply(b, to: 0.5) - 0.96) < 0.03, "the bright end lands near white")
        #expect(b.contrast == 0 && b.highlights == 0 && b.shadows == 0 && b.whites == 0)
    }

    @Test func liftsTheBlackPointOfAFlatPicture() throws {
        // 0.12…0.96: bright end is fine, the dark end floats above black; Blacks moves towards crushing it as far as it reaches.
        let b = try #require(AutoTone.solve(luma: Self.ramp(0.12, 0.96), current: BasicCorrection()))
        #expect(b.exposure == 0)
        #expect(b.blacks < 0 && b.blacks >= -100, "negative Blacks (more black clipping) raises the black point: the dark end gets darker")
        #expect(Self.apply(b, to: 0.12) < 0.12 - 0.04)
    }

    @Test func isStableWhenPressedTwice() throws {
        let first = try #require(AutoTone.solve(luma: Self.ramp(0.1, 0.55), current: BasicCorrection()))
        // What the monitor would now show (approximately: the same ramp through the new settings).
        let shown = Self.ramp(0.1, 0.55).map { Self.apply(first, to: $0) }
        let second = AutoTone.solve(luma: shown, current: first)
        if let second { #expect(abs(second.exposure - first.exposure) < 0.25 && abs(second.blacks - first.blacks) < 15) }
    }

    @Test func fullRangeOrFlatPicturesAreLeftAlone() {
        #expect(AutoTone.solve(luma: Self.ramp(0, 1), current: BasicCorrection()) == nil)
        #expect(AutoTone.solve(luma: Self.ramp(0.4, 0.42), current: BasicCorrection()) == nil, "flat frame: nothing to stretch")
        #expect(AutoTone.solve(luma: [], current: BasicCorrection()) == nil)
    }

    @Test func outliersDoNotDecideTheRangeAndSlidersStayInRange() throws {
        var l = Self.ramp(0.25, 0.6); l[0] = 0; l[1] = 1
        let b = try #require(AutoTone.solve(luma: l, current: BasicCorrection()))
        #expect(b.exposure > 0.3)
        #expect(abs(b.blacks) <= 100 && abs(b.exposure) <= 5)
        var hot = BasicCorrection(); hot.exposure = 4.9
        let c = AutoTone.solve(luma: Self.ramp(0.05, 0.3), current: hot)
        #expect((c?.exposure ?? 0) <= 5)
    }
}
