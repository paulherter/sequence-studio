import Testing
import SQCore
@testable import SQPlayback

/// Edge-gesture rewind with Loop on and an empty (zero-length) range: wrapping must not divide, trap or leave the point.
@Suite struct DisplayLeadEmptyLoopTests {
    private let empty = TimeRange(start: .zero, duration: .zero)

    @Test func wrapInEmptyLoopStaysAtItsStart() {
        for t in [Time(-5, 1), .zero, Time(3, 1), Time(1, 60)] {
            #expect(DisplayLead.wrapped(t, in: empty) == .zero)
        }
    }

    @Test func parkInEmptyLoopIsFinite() {
        let p = DisplayLead.parkPosition(handed: Time(1, 30), clock: .zero, rate: .forward, loop: empty)
        #expect(p == Time(1, 30) || p == .zero)
        let q = DisplayLead.parkPosition(handed: nil, clock: Time(2, 1), rate: .forward, loop: empty)
        #expect(q == Time(2, 1))
    }
}
