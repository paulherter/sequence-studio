import Testing
@testable import SQMonitorUI

@Suite struct LoudnessReadoutTests {
    @Test func noSignalHasNoReadout() {
        #expect(LoudnessReadout.text(.silent) == nil)
        #expect(LoudnessReadout.text(LoudnessReading(momentaryLUFS: -20)) == nil)   // momentary alone flickers: not shown
    }

    @Test func showsShortTermAndIntegrated() {
        let r = LoudnessReading(momentaryLUFS: -9, shortTermLUFS: -14.24, integratedLUFS: -15.06)
        #expect(LoudnessReadout.text(r) == "S -14.2  I -15.1 LUFS")
        #expect(LoudnessReadout.text(LoudnessReading(integratedLUFS: -16)) == "I -16.0 LUFS")
        #expect(LoudnessReadout.text(LoudnessReading(shortTermLUFS: -12)) == "S -12.0 LUFS")
    }

    @Test func overTargetFlagFollowsTheTarget() {
        let t = LoudnessTarget(lufs: -14, truePeakDB: -1)
        #expect(LoudnessReadout.isOver(LoudnessReading(shortTermLUFS: -12), target: t))
        #expect(!LoudnessReadout.isOver(LoudnessReading(shortTermLUFS: -14.5, integratedLUFS: -14.2), target: t))
        #expect(LoudnessReadout.isOver(LoudnessReading(integratedLUFS: -20, truePeakDB: 0.5), target: t))   // true peak over ceiling
    }
}
