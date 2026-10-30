import Foundation
import Testing
@testable import SQCore

@Suite struct DuckPresetTests {
    @Test func presetsDifferAndMatch() {
        #expect(DuckPreset.soft.amountDB < DuckPreset.hard.amountDB)
        #expect(DuckPreset.matching(amountDB: 18, timing: DuckPreset.hard.timing) == .hard)
        #expect(DuckPreset.matching(amountDB: 12, timing: DuckPreset.hard.timing) == nil)
    }

    @Test func amountIsClamped() {
        #expect(DuckPreset.clampedAmount(100) == 40)
        #expect(DuckPreset.clampedAmount(-3) == 0.5)
        #expect(DuckPreset.clampedAmount(7.3) == 7.5)
        #expect(DuckPreset.clampedAmount(.nan) == Ducking.defaultAmountDB)
    }

    @Test func presetTimingsSurviveClamping() {
        for p in DuckPreset.all { #expect(p.timing == p.timing.clamped) }
    }
}
