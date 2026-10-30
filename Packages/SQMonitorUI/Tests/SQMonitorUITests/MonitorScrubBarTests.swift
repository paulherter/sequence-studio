import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

@Suite struct MonitorScrubBarTests {
    private let m = MonitorScrubMath(duration: Time(10, 1), frameDuration: Time(1, 30), width: 216, inset: 8)

    @Test func endsMapToFirstAndLastFrame() {
        #expect(m.time(atX: 0) == .zero)
        #expect(m.time(atX: 8) == .zero)
        #expect(m.time(atX: 1000) == Time(10, 1) - Time(1, 30))
    }

    @Test func middleAndRoundTrip() {
        #expect(m.time(atX: 108) == Time(5, 1))
        #expect(m.x(for: Time(5, 1)) == 108)
        #expect(m.x(for: .zero) == 8)
        #expect(m.x(for: Time(10, 1)) == 208)
        #expect(m.x(for: Time(99, 1)) == 208)     // beyond the end stays on the bar
    }

    @Test func emptyDurationIsSafe() {
        let e = MonitorScrubMath(duration: .zero, frameDuration: Time(1, 30), width: 100)
        #expect(e.time(atX: 50) == .zero)
        #expect(e.x(for: Time(1, 1)) == 12)
    }

    @Test func rangeFromTwoFramesEitherOrder() {
        let fd = Time(1, 30)
        let a = MonitorScrubMath.range(Time(2, 1), Time(5, 1), frameDuration: fd)
        let b = MonitorScrubMath.range(Time(5, 1), Time(2, 1), frameDuration: fd)
        #expect(a.markIn == Time(2, 1) && a.markOut == Time(5, 1) + fd)
        #expect(a.markIn == b.markIn && a.markOut == b.markOut)
    }

    @Test func movedRangeKeepsLengthInsideDuration() {
        let r = m.movedRange(markIn: Time(2, 1), markOut: Time(4, 1), by: Time(100, 1))
        #expect(r.markIn == Time(8, 1) && r.markOut == Time(10, 1))
        let l = m.movedRange(markIn: Time(2, 1), markOut: Time(4, 1), by: Time(-100, 1))
        #expect(l.markIn == .zero && l.markOut == Time(2, 1))
    }
}
