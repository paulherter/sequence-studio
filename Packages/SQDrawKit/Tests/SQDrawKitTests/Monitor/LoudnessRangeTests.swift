import Foundation
import Testing
@testable import SQDrawKit

@Suite struct LoudnessRangeTests {
    private func fed(seconds: Double, level: (Double) -> Double) -> LoudnessRangeTracker {
        var t = LoudnessRangeTracker()
        var s = 0.0
        while s < seconds { t.add(shortTermLUFS: level(s), dt: 0.1); s += 0.1 }
        return t
    }

    @Test func underAMinuteIsGreyedOut() {
        let t = fed(seconds: 30) { $0 < 15 ? -30 : -20 }
        #expect(!t.isReliable)
        #expect(t.value == nil)
        #expect(t.text == "LRA --")
        #expect(t.range != nil)
    }

    @Test func rangeIsP95MinusP10OfGatedValues() {
        // Half the time -30, half -20: P10 = -30, P95 = -20.
        let t = fed(seconds: 90) { $0 < 45 ? -30 : -20 }
        #expect(t.isReliable)
        #expect(abs((t.value ?? 0) - 10) < 0.2)
        #expect(t.text.hasPrefix("LRA 10"))
    }

    @Test func quietPassagesBelowTheRelativeGateAreIgnored() {
        let t = fed(seconds: 90) { $0 < 80 ? -20 : -60 }
        #expect(abs(t.value ?? 99) < 0.1)
    }

    @Test func silenceNeverCounts() {
        var t = LoudnessRangeTracker()
        for _ in 0..<1000 { t.add(shortTermLUFS: nil, dt: 0.1) }
        #expect(t.measuredSeconds == 0)
        #expect(t.value == nil)
    }

    @Test func resetClears() {
        var t = fed(seconds: 70) { _ in -23 }
        #expect(t.isReliable)
        t.reset()
        #expect(!t.isReliable)
    }
}
