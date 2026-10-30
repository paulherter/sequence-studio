import Foundation
import Testing
@testable import SQCore

@Suite struct FourPointFitTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    @Test func eachChoiceDropsOneMark() {
        let m = SourceMarks(markIn: s(2), markOut: s(4))
        let a = FourPointFit.ignoreSourceIn.apply(source: m, sequenceIn: s(10), sequenceOut: s(15))
        #expect(a.source.markIn == nil && a.source.markOut == s(4) && a.sequenceIn == s(10) && a.sequenceOut == s(15))
        let b = FourPointFit.ignoreSequenceOut.apply(source: m, sequenceIn: s(10), sequenceOut: s(15))
        #expect(b.source == m && b.sequenceIn == s(10) && b.sequenceOut == nil)
        let c = FourPointFit.ignoreSequenceIn.apply(source: m, sequenceIn: s(10), sequenceOut: s(15))
        #expect(c.sequenceIn == nil && c.sequenceOut == s(15))
        let d = FourPointFit.trimSourceEnd.apply(source: m, sequenceIn: s(10), sequenceOut: s(15))
        #expect(d.source == m && d.sequenceIn == s(10) && d.sequenceOut == s(15))
    }

    @Test func loneSourceOutIsNotPaddedPastItsEnd() {
        let p = Timeline.sourceEditPlan(sourceMarks: SourceMarks(markIn: nil, markOut: s(4)), total: s(10), sequenceIn: s(10),
                                        sequenceOut: s(15), playhead: .zero, frameDuration: Time(1, 30))
        #expect(p?.source == TimeRange(start: .zero, end: s(4)) && p?.at == s(10))
    }
}
