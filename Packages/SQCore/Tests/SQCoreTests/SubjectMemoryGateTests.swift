import Testing
@testable import SQCore

@Suite struct SubjectMemoryGateTests {
    let sure = [Float](repeating: 8, count: 16), blurry = [Float](repeating: 0.2, count: 16)

    @Test func certaintyIsMeanDistanceFromHalf() {
        #expect(SubjectMemoryGate.certainty(logits: [0, 0]) == 0)
        #expect(SubjectMemoryGate.certainty(logits: sure) > 0.49)
        #expect(SubjectMemoryGate.certainty(logits: []) == 0)
    }

    @Test func defaultAdmitsEveryFrame() {
        var g = SubjectMemoryGate()
        var all = true
        for _ in 0..<5 { all = g.admit(logits: blurry) && all }
        #expect(all)
    }

    @Test func distanceSpacesEntries() {
        var g = SubjectMemoryGate(minDistance: 3)
        var got: [Bool] = []
        for _ in 0..<7 { got.append(g.admit(logits: sure)) }
        #expect(got == [true, false, false, true, false, false, true])
    }

    @Test func blurryMasksNeverEnterAndDoNotRestartDistance() {
        var g = SubjectMemoryGate(minDistance: 2, minCertainty: 0.3)
        let r1 = g.admit(logits: sure)
        #expect(r1)
        let r2 = g.admit(logits: sure)      // too near
        #expect(!r2)
        let r3 = g.admit(logits: blurry)    // far enough but uncertain
        #expect(!r3)
        let r4 = g.admit(logits: sure)       // still far enough
        #expect(r4)
    }

    @Test func nanLogitsCountAsZeroCertainty() {
        let nan = [Float](repeating: .nan, count: 4)
        #expect(SubjectMemoryGate.certainty(logits: nan) == 0)
        var g = SubjectMemoryGate()
        let admitted = g.admit(logits: nan)
        #expect(admitted)
        var strict = SubjectMemoryGate(minDistance: 1, minCertainty: 0.1)
        let refused = strict.admit(logits: nan)
        #expect(!refused)
    }

    @Test func resetLetsNextFrameIn() {
        var g = SubjectMemoryGate(minDistance: 4)
        _ = g.admit(logits: sure); g.reset()
        let r5 = g.admit(logits: sure)
        #expect(r5)
    }
}

@Suite struct SubjectAbsenceMemoryTests {
    @Test func onlyTheFirstEmptyFramesInARowAreRemembered() {
        var m = SubjectAbsenceMemory(limit: 2)
        let first = (0..<5).map { _ in m.admitsEmpty() }
        #expect(first == [true, true, false, false, false])
        // The subject is back: the count starts over.
        m.found()
        let again = (0..<3).map { _ in m.admitsEmpty() }
        #expect(again == [true, true, false])
    }

    @Test func noLimitRemembersEveryEmptyFrameAndZeroNone() {
        var all = SubjectAbsenceMemory()
        let every = (0..<50).map { _ in all.admitsEmpty() }
        #expect(every.allSatisfy { $0 })
        var none = SubjectAbsenceMemory(limit: 0)
        let n = none.admitsEmpty()
        #expect(!n)
        // A negative limit counts as none.
        var negative = SubjectAbsenceMemory(limit: -3)
        let m = negative.admitsEmpty()
        #expect(!m)
    }

    let box = SubjectTrackBox(x0: 0.6, y0: 0.1, x1: 0.8, y1: 0.9)

    @Test func aWeakMaskAfterAGapIsNoReacquisition() {
        var rule = SubjectReacquireRule(minScore: 2, afterLost: 3, settle: 3)
        // Inside a track or after a short dropout every mask counts.
        let inside = [rule.accepts(score: 0.3, area: 0.05, box: box, lostRun: 0), rule.accepts(score: 0.3, area: 0.02, box: box, lostRun: 2)]
        #expect(inside == [true, true])
        // After the gap a sure one counts at once, a weak one that jumps around never (judo: the other fighter).
        let sure = rule.accepts(score: 2, area: 0.05, box: box, lostRun: 3)
        #expect(sure)
        let areas = [0.024, 0.031, 0.040, 0.061, 0.019, 0.040]
        let jumping = areas.map { rule.accepts(score: 0.4, area: $0, box: box, lostRun: 10) }
        #expect(jumping.allSatisfy { !$0 })
        #expect(SubjectReacquireRule(minScore: 1, afterLost: 0, settle: 0).afterLost == 1)
    }

    @Test func aWeakMaskThatHoldsStillIsTheSubjectBack() {
        var rule = SubjectReacquireRule(minScore: 2, afterLost: 3, settle: 3)
        // Lady running, moved during the gap: the same weak mask frame after frame.
        let areas = [0.0733, 0.0723, 0.0722, 0.0724]
        let held = areas.map { rule.accepts(score: 0.7, area: $0, box: box, lostRun: 15) }
        #expect(held == [false, false, true, true])
        // A box elsewhere starts the count over.
        let moved = SubjectTrackBox(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.9)
        var other = SubjectReacquireRule(minScore: 2, afterLost: 3, settle: 2)
        let a = other.accepts(score: 0.7, area: 0.07, box: box, lostRun: 15)
        let b = other.accepts(score: 0.7, area: 0.07, box: moved, lostRun: 15)
        let c = other.accepts(score: 0.7, area: 0.07, box: moved, lostRun: 15)
        #expect(!a && !b && c)
        // An empty frame starts it over too.
        var gap = SubjectReacquireRule(minScore: 2, afterLost: 3, settle: 2)
        let d = gap.accepts(score: 0.7, area: 0.07, box: box, lostRun: 15)
        gap.empty()
        let e = gap.accepts(score: 0.7, area: 0.07, box: box, lostRun: 15)
        let f = gap.accepts(score: 0.7, area: 0.07, box: box, lostRun: 15)
        #expect(!d && !e && f)
    }

    @Test func offTakesEveryMask() {
        var off = SubjectReacquireRule.off
        let all = off.accepts(score: -100, area: 0.5, box: box, lostRun: 1000)
        #expect(all)
    }

    @Test func theTrackerKeepsFramesWithTheSubjectInItsMemory() {
        // The default must stay under the six recent-frame slots (EdgeTAM), else the memory can fill with empty frames.
        #expect(SubjectAbsenceMemory.tracker.limit < 6)
    }
}
