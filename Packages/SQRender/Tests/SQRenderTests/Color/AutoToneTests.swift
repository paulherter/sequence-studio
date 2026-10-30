import Testing
#if canImport(simd)
import simd
#endif
import SQCore
@testable import SQRender

/// Auto Tone on whole frames: SQCore's gray-axis tone model matches the real Basic Correction maths, a dark frame is
/// brightened, a color cast is neutralised, and a second press changes nothing more.
@Suite struct AutoToneTests {
    static func apply(_ b: BasicCorrection, _ linear: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let p = PreparedBasic(b, gamut: .rec709)
        return linear.map { TransferFunctions.bt709InverseOETF(p.apply(TransferFunctions.bt709OETF($0), pre: false)) }
    }
    static func greys(_ lo: Float, _ hi: Float, cast: SIMD3<Float> = .one, n: Int = 600) -> [SIMD3<Float>] {
        (0..<n).map { cast * TransferFunctions.bt709InverseOETF(lo + (hi - lo) * Float($0) / Float(n - 1)) }
    }

    @Test func coreToneModelMatchesBasicCorrection() {
        var b = BasicCorrection()
        b.exposure = 0.7; b.contrast = 35; b.shadows = -25; b.highlights = 45; b.whites = 30; b.blacks = -60
        let p = PreparedBasic(b, gamut: .rec709)
        for y in stride(from: Float(0), through: 1.1, by: 0.05) {
            #expect(abs(AutoToneSolver.tone(y, b) - p.apply(SIMD3(repeating: y), pre: false).y) < 2e-4, "y \(y)")
        }
    }

    @Test func darkFrameIsBrightenedAndStable() throws {
        let frame = Self.greys(0.03, 0.4)
        let b = try #require(AutoTone.solve(linear: frame, current: BasicCorrection()))
        #expect(b.exposure > 0.3 && b.temperature == 0 && b.tint == 0)
        #expect(AutoTone.solve(linear: Self.apply(b, frame), current: b) == nil)
    }

    @Test func colourCastIsNeutralisedOnceOnly() throws {
        let frame = Self.greys(0.02, 0.97, cast: SIMD3(1.07, 1, 0.9))
        let b = try #require(AutoTone.solve(linear: frame, current: BasicCorrection()))
        #expect(b.temperature < 0, "a warm cast is cooled")
        let shown = Self.apply(b, frame)
        let mid = shown[shown.count / 2]
        #expect(abs(mid.x / mid.y - 1) < 0.02 && abs(mid.z / mid.y - 1) < 0.02)
        if let again = AutoTone.solve(linear: shown, current: b) {
            #expect(abs(again.temperature - b.temperature) <= 1 && abs(again.tint - b.tint) <= 1)
            #expect(abs(again.exposure - b.exposure) <= 0.03)
        }
    }

    @Test func rec709FirstEffectRunsTheSameToneBeforeTheConversion() {
        // The first effect's Basic Correction works on source-linear light (pre); for Rec.709 that is the same picture.
        var b = BasicCorrection()
        b.exposure = -0.6; b.contrast = 20; b.shadows = 15; b.whites = 40; b.blacks = -20
        let p = PreparedBasic(b, gamut: .rec709)
        for y in stride(from: Float(0.02), through: 1.0, by: 0.07) {
            let pre = TransferFunctions.bt709OETF(p.apply(SIMD3(repeating: TransferFunctions.bt709InverseOETF(y)), pre: true).y)
            #expect(abs(AutoToneSolver.tone(y, b) - pre) < 2e-4)
        }
    }

    static func displayLuma(_ px: [SIMD3<Float>]) -> [Float] {
        px.map { TransferFunctions.bt709OETF(max(simd_dot(AutoTone.luma, $0), 0)) }.sorted()
    }

    // The casts are passed as plain arrays: on Windows a SIMD3<Float> test argument reaches the test with its x and y
    // lanes garbled (Swift 6 Windows codegen), so the vector is built inside the test.
    @Test(arguments: [[Float(1.1), 1, 0.85], [Float(0.88), 1, 1.15]])
    func warmAndCoolCastsDoNotClipAndASecondPressStaysInTheDeadBand(castLanes: [Float]) throws {
        let cast = SIMD3<Float>(castLanes[0], castLanes[1], castLanes[2])
        let frame = Self.greys(0.04, 0.85, cast: cast)
        let b = try #require(AutoTone.solve(linear: frame, current: BasicCorrection()))
        #expect(b.temperature != 0 || b.tint != 0)
        let shown = Self.apply(b, frame)
        let l = Self.displayLuma(shown)
        #expect(l[Int(Float(l.count - 1) * 0.995)] <= AutoToneSolver.whiteTarget + 0.01, "highlights do not clip after the white balance")
        let mid = shown[shown.count / 2]
        #expect(abs(mid.x / mid.y - 1) < 0.02 && abs(mid.z / mid.y - 1) < 0.02)
        if let again = AutoTone.solve(linear: shown, current: b) {
            #expect(abs(again.exposure - b.exposure) <= 0.02)
            #expect(abs(again.contrast - b.contrast) <= 0.5 && abs(again.whites - b.whites) <= 0.5 && abs(again.blacks - b.blacks) <= 0.5)
            #expect(again.temperature == b.temperature && again.tint == b.tint)
        }
    }

    @Test func strongCastAndFullRangeFramesAreLeftAlone() {
        #expect(AutoTone.solve(linear: Self.greys(0, 1), current: BasicCorrection()) == nil)
        #expect(AutoTone.solve(linear: Self.greys(0, 1, cast: SIMD3(1.6, 1, 0.5)), current: BasicCorrection()) == nil)
        #expect(AutoTone.solve(linear: [], current: BasicCorrection()) == nil)
    }
}
