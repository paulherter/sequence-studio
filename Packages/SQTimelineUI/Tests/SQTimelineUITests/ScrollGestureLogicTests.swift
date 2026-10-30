import Foundation
import Testing
@testable import SQTimelineUI

@Suite struct ScrollGestureLogicTests {
    @Test func constants() {
        #expect(ScrollTuning.trackpadScrollGain == 1.6)
        #expect(ScrollTuning.wheelNotch == 48)
    }

    @Test func amountsTrackpadGainHorizontalOnly() {
        let a = ScrollTuning.scrollAmounts(dx: 10, dy: 10, precise: true, horizontalOnly: false)
        #expect(abs(a.x - 16) < 1e-9 && a.y == 10)
        let w = ScrollTuning.scrollAmounts(dx: 1, dy: 2, precise: false, horizontalOnly: false)
        #expect(w.x == 48 && w.y == 96)
        let h = ScrollTuning.scrollAmounts(dx: 1, dy: 3, precise: false, horizontalOnly: true)
        #expect(h.x == 144 && h.y == 0)
        let h2 = ScrollTuning.scrollAmounts(dx: 5, dy: 1, precise: true, horizontalOnly: true)
        #expect(abs(h2.x - 8) < 1e-9 && h2.y == 0)
    }

    @Test func horizontalSwipeDropsVerticalWholeGestureAndMomentum() {
        var l = ScrollAxisLock()
        var r = l.filter(phase: .began, momentumPhase: .none, dx: 5, dy: 1)
        #expect(r.dx == 5 && r.dy == 0)               // released on lock
        r = l.filter(phase: .changed, momentumPhase: .none, dx: 8, dy: 6)
        #expect(r.dx == 8 && r.dy == 0)
        r = l.filter(phase: .ended, momentumPhase: .none, dx: 0, dy: 0)
        r = l.filter(phase: .none, momentumPhase: .began, dx: 3, dy: 2)
        #expect(r.dx == 3 && r.dy == 0)
        r = l.filter(phase: .none, momentumPhase: .ended, dx: 1, dy: 1)
        #expect(r.dx == 1 && r.dy == 0)
        #expect(l.axis == nil)
    }

    @Test func verticalNeedsBias() {
        var l = ScrollAxisLock()
        _ = l.filter(phase: .began, momentumPhase: .none, dx: 3, dy: 4)     // 4 < 3*1.5: stays horizontal
        #expect(l.axis == .horizontal)
        l = ScrollAxisLock()
        let r = l.filter(phase: .began, momentumPhase: .none, dx: 1, dy: 4)
        #expect(l.axis == .vertical && r.dx == 0 && r.dy == 4)
    }

    @Test func accumulatesBelowThresholdAndNewGestureResets() {
        var l = ScrollAxisLock()
        var r = l.filter(phase: .began, momentumPhase: .none, dx: 0, dy: 1)
        #expect(r.dx == 0 && r.dy == 0 && l.axis == nil)
        r = l.filter(phase: .changed, momentumPhase: .none, dx: 0, dy: 2)
        #expect(l.axis == .vertical && r.dy == 3)
        r = l.filter(phase: .began, momentumPhase: .none, dx: 4, dy: 0)
        #expect(l.axis == .horizontal && r.dx == 4)
    }

    @Test func mouseWheelStateless() {
        var l = ScrollAxisLock()
        _ = l.filter(phase: .began, momentumPhase: .none, dx: 5, dy: 0)
        let r = l.filter(phase: .none, momentumPhase: .none, dx: 1, dy: 2)
        #expect(r.dx == 1 && r.dy == 2 && l.axis == nil)
    }

    @Test func pinchGuardWindow() {
        var g = PinchScrollGuard()
        #expect(!g.suppressesVertical(now: 0))
        g.magnify(phase: .began, now: 1)
        #expect(g.suppressesVertical(now: 5))           // still active
        g.magnify(phase: .ended, now: 6)
        #expect(g.suppressesVertical(now: 6.2))
        #expect(!g.suppressesVertical(now: 6.26))
    }
}
