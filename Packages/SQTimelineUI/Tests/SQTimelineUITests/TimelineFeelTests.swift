#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import SQTimelineUI

@Suite struct TimelineFeelTests {
    // MARK: Presets

    @Test func normalIsTodaysBehaviour() {
        let n = TimelineFeel.normal
        #expect(n.trackpadScrollGain == ScrollTuning.trackpadScrollGain)
        #expect(n.axisRule == .lockPerGesture)
        #expect(!n.rubberBand)
        #expect(n.verticalSwipeScrollsTime)
        #expect(!n.doubleTapFits)
        #expect(n.playbackFollow == .page)
        #expect(TimelineFeel() == .normal)
    }

    @Test func fastCutIsFinalCutLike() {
        let f = TimelineFeel.fastCut
        #expect(f.trackpadScrollGain == 1)
        #expect(f.axisRule == .predominant)
        #expect(f.rubberBand)
        #expect(!f.verticalSwipeScrollsTime)
        #expect(f.doubleTapFits)
        #expect(f.playbackFollow == .page)
        #expect(TimelineFeel.forMagnetic(true) == .fastCut && TimelineFeel.forMagnetic(false) == .normal)
    }

    @Test func amountsUseFeelGain() {
        let a = ScrollTuning.scrollAmounts(dx: 10, dy: 4, precise: true, horizontalOnly: false, feel: .fastCut)
        #expect(a.x == 10 && a.y == 4)
        let n = ScrollTuning.scrollAmounts(dx: 10, dy: 4, precise: true, horizontalOnly: false, feel: .normal)
        #expect(abs(n.x - 16) < 1e-9 && n.y == 4)
        // Fast Cut: a trackpad swipe without vertical room never turns vertical motion into time.
        let h = ScrollTuning.scrollAmounts(dx: 1, dy: 9, precise: true, horizontalOnly: true, feel: .fastCut)
        #expect(h.x == 1 && h.y == 0)
        // The mouse wheel keeps mapping vertical notches onto time in both feels.
        let w = ScrollTuning.scrollAmounts(dx: 0, dy: 1, precise: false, horizontalOnly: true, feel: .fastCut)
        #expect(w.x == 48 && w.y == 0)
    }

    // MARK: Predominant axis (free diagonal)

    @Test func predominantLocksClearlyHorizontalSwipe() {
        var l = ScrollAxisLock(rule: .predominant)
        let r = l.filter(phase: .began, momentumPhase: .none, dx: 6, dy: 2)
        #expect(l.axis == .horizontal && r.dx == 6 && r.dy == 0)
        let r2 = l.filter(phase: .changed, momentumPhase: .none, dx: 3, dy: 5)
        #expect(r2.dx == 3 && r2.dy == 0)
    }

    @Test func predominantLocksClearlyVerticalSwipe() {
        var l = ScrollAxisLock(rule: .predominant)
        let r = l.filter(phase: .began, momentumPhase: .none, dx: 1, dy: -6)
        #expect(l.axis == .vertical && r.dx == 0 && r.dy == -6)
    }

    @Test func diagonalStartStaysFreeForWholeGestureAndMomentum() {
        var l = ScrollAxisLock(rule: .predominant)
        let r = l.filter(phase: .began, momentumPhase: .none, dx: 4, dy: 4)
        #expect(l.axis == .free && r.dx == 4 && r.dy == 4)
        let r2 = l.filter(phase: .changed, momentumPhase: .none, dx: 10, dy: 0.5)
        #expect(r2.dx == 10 && r2.dy == 0.5)
        _ = l.filter(phase: .ended, momentumPhase: .none, dx: 0, dy: 0)
        let m = l.filter(phase: .none, momentumPhase: .changed, dx: 2, dy: 3)
        #expect(m.dx == 2 && m.dy == 3)
        _ = l.filter(phase: .none, momentumPhase: .ended, dx: 0, dy: 0)
        #expect(l.axis == nil)
    }

    @Test func predominantHoldsBackUntilThreshold() {
        var l = ScrollAxisLock(rule: .predominant)
        let r = l.filter(phase: .began, momentumPhase: .none, dx: 1, dy: 0.5)
        #expect(r.dx == 0 && r.dy == 0 && l.axis == nil)
        let r2 = l.filter(phase: .changed, momentumPhase: .none, dx: 1.5, dy: 2)
        // Accumulated 2.5 x 2.5: diagonal, everything held back is released.
        #expect(l.axis == .free && r2.dx == 2.5 && r2.dy == 2.5)
    }

    @Test func predominantWheelIsStateless() {
        var l = ScrollAxisLock(rule: .predominant)
        let r = l.filter(phase: .none, momentumPhase: .none, dx: 1, dy: 2)
        #expect(r.dx == 1 && r.dy == 2 && l.axis == nil)
    }

    // MARK: Rubber band

    @Test func dampIsMonotonicBoundedAndInvertible() {
        let d = 800.0
        #expect(RubberBand.damp(0, dimension: d) == 0)
        var last = 0.0
        for x in stride(from: 10.0, through: 5000, by: 10) {
            let y = RubberBand.damp(x, dimension: d)
            #expect(y > last && y < d)
            #expect(abs(RubberBand.undamp(y, dimension: d) - x) < 1e-6 * x + 1e-9)
            last = y
        }
        #expect(RubberBand.damp(-100, dimension: d) == -RubberBand.damp(100, dimension: d))
        // Small pulls follow the fingers at about coefficient speed.
        #expect(abs(RubberBand.damp(1, dimension: d) - RubberBand.coefficient) < 0.01)
    }

    @Test func scrollInsideRangeIsPlain() {
        let p = RubberBand.scroll(position: 100, by: 50, range: 0...1000, dimension: 800)
        #expect(p == 150)
    }

    @Test func scrollPastEdgeIsDampedAndReturnsExactly() {
        let r = 0.0...1000.0
        let p = RubberBand.scroll(position: 10, by: -110, range: r, dimension: 800)
        // 10 points plain, 100 past the edge damped.
        #expect(p < 0 && p > -100)
        #expect(abs(p + RubberBand.damp(100, dimension: 800)) < 1e-9)
        let back = RubberBand.scroll(position: p, by: 110, range: r, dimension: 800)
        #expect(abs(back - 10) < 1e-9)
        let far = RubberBand.scroll(position: 990, by: 60, range: r, dimension: 800)
        #expect(far > 1000 && far < 1050)
    }

    @Test func springBackEasesToEdge() {
        #expect(RubberBand.springBack(from: -40, to: 0, progress: 0) == -40)
        #expect(RubberBand.springBack(from: -40, to: 0, progress: 1) == 0)
        var last = -40.0
        for i in 1...10 {
            let v = RubberBand.springBack(from: -40, to: 0, progress: Double(i) / 10)
            #expect(v >= last)
            last = v
        }
        #expect(RubberBand.edge(of: -5, range: 0...10) == 0)
        #expect(RubberBand.edge(of: 15, range: 0...10) == 10)
        #expect(RubberBand.edge(of: 5, range: 0...10) == nil)
    }

    // MARK: Elastic gesture

    private let r = 0.0...1000.0
    private let dim = 800.0

    @Test func wheelClampsHard() {
        var e = ElasticAxis()
        let s = e.step(position: 5, delta: -50, range: r, dimension: dim, phase: .none, momentumPhase: .none)
        #expect(s.position == 0 && !s.springBack)
    }

    @Test func fingersOverscrollThenReleaseSpringsBack() {
        var e = ElasticAxis()
        var s = e.step(position: 0, delta: -30, range: r, dimension: dim, phase: .began, momentumPhase: .none)
        #expect(s.position < 0 && !s.springBack)
        s = e.step(position: s.position, delta: -30, range: r, dimension: dim, phase: .changed, momentumPhase: .none)
        #expect(s.position < 0 && !s.springBack)
        let held = s.position
        s = e.step(position: held, delta: 0, range: r, dimension: dim, phase: .ended, momentumPhase: .none)
        #expect(s.springBack && s.position == held)
        // The momentum tail of that gesture is swallowed while it springs back.
        s = e.step(position: held, delta: -20, range: r, dimension: dim, phase: .none, momentumPhase: .began)
        #expect(s.position == held && !s.springBack)
        s = e.step(position: held, delta: -1, range: r, dimension: dim, phase: .none, momentumPhase: .ended)
        #expect(s.position == held)
    }

    @Test func releaseInsideNeedsNoSpring() {
        var e = ElasticAxis()
        _ = e.step(position: 500, delta: 10, range: r, dimension: dim, phase: .began, momentumPhase: .none)
        let s = e.step(position: 510, delta: 0, range: r, dimension: dim, phase: .ended, momentumPhase: .none)
        #expect(!s.springBack && s.position == 510)
    }

    @Test func momentumIntoEdgeBouncesOnce() {
        var e = ElasticAxis()
        _ = e.step(position: 100, delta: -10, range: r, dimension: dim, phase: .began, momentumPhase: .none)
        _ = e.step(position: 90, delta: 0, range: r, dimension: dim, phase: .ended, momentumPhase: .none)
        var s = e.step(position: 90, delta: -60, range: r, dimension: dim, phase: .none, momentumPhase: .began)
        #expect(s.position == 30 && !s.springBack)
        s = e.step(position: 30, delta: -50, range: r, dimension: dim, phase: .none, momentumPhase: .changed)
        #expect(s.position < 0 && s.position > -20)
        var springs = s.springBack ? 1 : 0
        var p = s.position
        for _ in 0..<20 {
            s = e.step(position: p, delta: -20, range: r, dimension: dim, phase: .none, momentumPhase: .changed)
            if s.springBack { springs += 1 }
            p = s.position
        }
        #expect(springs == 1)
        #expect(p > -ElasticAxis.maxMomentumBounce(dimension: dim) - 1e-9)
        s = e.step(position: p, delta: 0, range: r, dimension: dim, phase: .none, momentumPhase: .ended)
        #expect(!s.springBack)
    }

    @Test func momentumEndingOutsideSpringsBack() {
        var e = ElasticAxis()
        _ = e.step(position: 10, delta: -1, range: r, dimension: dim, phase: .began, momentumPhase: .none)
        _ = e.step(position: 9, delta: 0, range: r, dimension: dim, phase: .ended, momentumPhase: .none)
        var s = e.step(position: 9, delta: -12, range: r, dimension: dim, phase: .none, momentumPhase: .changed)
        #expect(s.position < 0 && !s.springBack)
        s = e.step(position: s.position, delta: 0, range: r, dimension: dim, phase: .none, momentumPhase: .ended)
        #expect(s.springBack)
    }

    @Test func newGestureGrabsMidBounce() {
        var e = ElasticAxis()
        _ = e.step(position: 0, delta: -40, range: r, dimension: dim, phase: .began, momentumPhase: .none)
        _ = e.step(position: -20, delta: 0, range: r, dimension: dim, phase: .ended, momentumPhase: .none)
        let s = e.step(position: -10, delta: 5, range: r, dimension: dim, phase: .began, momentumPhase: .none)
        #expect(s.position > -10 && s.position < 0 && !s.springBack)
    }

    // MARK: Continuous playback scroll

    @Test func continuousKeepsPlayheadAtCentreOncePassed() {
        let f = TimelineFollow()
        // Content area 100...1100, center 600.
        #expect(f.continuousScroll(playheadX: 400, scrollX: 0, viewLeft: 100, viewRight: 1100) == nil)
        #expect(f.continuousScroll(playheadX: 610, scrollX: 50, viewLeft: 100, viewRight: 1100) == CGFloat(60))
        // Off screen to the left (loop back to the start): bring it to the center, never before time 0.
        #expect(f.continuousScroll(playheadX: 50, scrollX: 2000, viewLeft: 100, viewRight: 1100) == CGFloat(1450))
        #expect(f.continuousScroll(playheadX: 50, scrollX: 20, viewLeft: 100, viewRight: 1100) == CGFloat(0))
    }

    @Test func continuousRespectsManualScroll() {
        var f = TimelineFollow()
        f.userScrolled(whilePlaying: true)
        #expect(f.continuousScroll(playheadX: 900, scrollX: 0, viewLeft: 100, viewRight: 1100) == nil)
    }

    @Test func followDispatchesOnMode() {
        let f = TimelineFollow()
        #expect(f.scroll(mode: .page, playheadX: 700, scrollX: 0, viewLeft: 100, viewRight: 1100) == nil)
        #expect(f.scroll(mode: .continuous, playheadX: 700, scrollX: 0, viewLeft: 100, viewRight: 1100) == CGFloat(100))
    }
}
