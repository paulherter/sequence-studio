import Testing
@testable import SQTimelineUI

@Suite struct PanelSyncThrottleTests {
    private static func go(_ t: inout PanelSyncThrottle, _ now: Double, _ only: Bool, _ scroll: Double) -> Bool {
        t.shouldSyncPanels(now: now, playheadOnly: only, lastScroll: scroll)
    }

    @Test func syncsEveryTickWhenNotScrolling() {
        var t = PanelSyncThrottle()
        for i in 0..<10 { #expect(Self.go(&t, 10 + Double(i) / 30, true, 0)) }
    }

    @Test func throttlesPlayheadTicksWhileScrolling() {
        var t = PanelSyncThrottle()
        var synced = 0
        for i in 0..<30 {   // one second of 30 Hz ticks with a scroll in every tick
            let now = 10 + Double(i) / 30
            if t.shouldSyncPanels(now: now, playheadOnly: true, lastScroll: now - 0.005) { synced += 1 }
        }
        #expect(synced >= 7 && synced <= 11)
    }

    @Test func otherChangesAlwaysSyncAndRestartTheInterval() {
        var t = PanelSyncThrottle()
        #expect(Self.go(&t, 10, true, 10))
        #expect(!Self.go(&t, 10.03, true, 10.02))
        #expect(Self.go(&t, 10.04, false, 10.03))
        #expect(!Self.go(&t, 10.07, true, 10.06))
    }

    @Test func catchesUpOnceScrollingStops() {
        var t = PanelSyncThrottle()
        #expect(Self.go(&t, 10, true, 10))
        #expect(Self.go(&t, 10.03, true, 9))
    }
}
