import Testing
@testable import SQEditorUI

@Suite struct LoudnessMeterTests {
    @Test func lufsScaleMapping() {
        #expect(LoudnessScale.fraction(lufs: -40) == 0)
        #expect(LoudnessScale.fraction(lufs: 0) == 1)
        #expect(LoudnessScale.fraction(lufs: -20) == 0.5)
        #expect(LoudnessScale.fraction(lufs: -90) == 0)
        #expect(LoudnessScale.fraction(lufs: 5) == 1)
        #expect(LoudnessScale.fraction(lufs: nil) == 0)
        #expect(abs(LoudnessScale.fraction(lufs: LoudnessScale.targetLUFS) - 26.0 / 40) < 1e-12)
    }

    @Test func numberText() {
        #expect(LoudnessScale.text(lufs: -14.04) == "-14.0")
        #expect(LoudnessScale.text(lufs: nil) == "-inf")
        #expect(LoudnessScale.text(lufs: -200) == "-inf")
    }

    @Test func peakHoldHoldsThenFalls() {
        var h = PeakHold(holdSeconds: 2, fallDBPerSecond: 20)
        h.update(-6, dt: 0.1)
        #expect(h.valueDB == -6)
        h.update(-20, dt: 1.0)
        #expect(h.valueDB == -6)
        h.update(-20, dt: 1.5) // 2.5 s since peak, 0.5 s falling
        #expect(abs(h.valueDB - -16) < 1e-9)
        h.update(-20, dt: 10)
        #expect(h.valueDB == -20)
        h.update(-3, dt: 0.1)
        #expect(h.valueDB == -3)
    }

    @Test func overFlag() {
        #expect(LoudnessReading(truePeakDB: 0.5).truePeakOver)
        #expect(!LoudnessReading(truePeakDB: -1.0).truePeakOver)
    }
}
