import Foundation
import Testing
import SQCore
@testable import SQEditorUI

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
        #expect(e.x(for: Time(1, 1)) == 8)
    }
}
