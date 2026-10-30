import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// QA after the redesign: the cache strip along the ruler's top edge showed scattered blue specks next to the playhead head.
@MainActor struct RulerCacheStripTests {
    @Test func nearbySpansJoinAndSpecksDisappear() {
        let g = TimelineGeometry(frameDuration: Time(1, 30), pointsPerSecond: 40)
        func span(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: Time(a, 30), end: Time(b, 30)) }
        // 10 frames = 13.3 pt; a 1-frame gap (1.3 pt) joins, a 20-frame gap (26 pt) does not, a 1-frame run (1.3 pt) is dropped.
        let bars = RulerView.cacheBars([span(40, 50), span(0, 10), span(11, 20), span(200, 201)], geometry: g)
        #expect(bars.count == 2)
        #expect(bars[0].lowerBound == g.x(for: Time(0, 30)) && bars[0].upperBound == g.x(for: Time(20, 30)))
        #expect(bars[1].lowerBound == g.x(for: Time(40, 30)))
    }
}
