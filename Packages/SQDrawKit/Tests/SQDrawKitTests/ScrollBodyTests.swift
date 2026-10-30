import Foundation
import Testing
@testable import SQDrawKit

@Suite struct ScrollBodyTests {
    private func pad(_ phase: ScrollPhase, momentum: ScrollPhase = .none) -> ScrollGesture {
        ScrollGesture(precise: true, phase: phase, momentumPhase: momentum)
    }
    private func body(max: Double = 1000, system: Bool = false) -> ScrollBody {
        let b = ScrollBody()
        b.maxOffset = max; b.extent = 400; b.systemMomentum = system
        return b
    }
    /// Runs the frames of one second at 60 Hz from `t0`.
    private func run(_ b: ScrollBody, from t0: Double, seconds: Double = 1) -> Double {
        var t = t0
        while t < t0 + seconds { t += 1.0 / 60; b.advance(to: t) }
        return t
    }

    @Test func rubberBandResistsAndStaysBelowTheViewport() {
        #expect(ScrollBody.rubber(0, 400) == 0)
        let a = ScrollBody.rubber(100, 400), b = ScrollBody.rubber(1000, 400)
        #expect(a > 0 && a < 100)               // resisted
        #expect(b > a && b < 400)               // grows, never reaches the viewport
        #expect(abs(ScrollBody.unrubber(a, 400) - 100) < 1e-6)
    }

    @Test func fingersInsideTheRangeMoveOneToOne() {
        let b = body()
        b.scroll(by: 10, gesture: pad(.began), now: 0)
        b.scroll(by: 15, gesture: pad(.changed), now: 0.01)
        #expect(b.offsetNow(0.01) == 25)
    }

    @Test func pullingPastTheTopResistsThenReleaseSpringsBack() {
        let b = body()
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: -200, gesture: pad(.changed), now: 0.01)
        let pulled = b.offsetNow(0.01)
        #expect(pulled < 0 && pulled > -200)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.5)          // rested: no fling
        #expect(b.isAnimating)
        let t = run(b, from: 0.5, seconds: 1.5)
        #expect(b.offsetNow(t) == 0)
        #expect(!b.isAnimating)
    }

    @Test func springNeverOvershootsTheEdgeFromRest() {
        let b = body()
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: 300, gesture: pad(.changed), now: 0.01)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.5)
        var t = 0.5, last = b.offsetNow(t)
        while t < 3 { t += 1.0 / 60; let o = b.offsetNow(t); #expect(o <= last + 1e-9 && o.isFinite && o >= 0); last = o }
    }

    @Test func aFlingWithoutSystemMomentumGlidesAndSettles() {
        let b = body(max: 100_000)
        var t = 0.0
        b.scroll(by: 0, gesture: pad(.began), now: t)
        for _ in 0..<6 { t += 1.0 / 60; b.scroll(by: 20, gesture: pad(.changed), now: t) }    // 1200 pt/s
        let lift = b.offsetNow(t)
        b.scroll(by: 0, gesture: pad(.ended), now: t + 0.01)
        #expect(b.isAnimating)
        let end = run(b, from: t + 0.01, seconds: 6)
        let final = b.offsetNow(end)
        #expect(final > lift + 300)                  // travelled roughly v/2 = 600 pt
        #expect(final < lift + 900)
        #expect(!b.isAnimating)
    }

    @Test func aStalledFingerLiftsWithoutAFling() {
        let b = body()
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: 30, gesture: pad(.changed), now: 0.01)
        b.scroll(by: 30, gesture: pad(.changed), now: 0.02)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.6)
        #expect(!b.isAnimating)
    }

    @Test func aFlingIntoTheEndBouncesAndComesBack() {
        let b = body(max: 500)
        var t = 0.0
        b.scroll(by: 0, gesture: pad(.began), now: t)
        for _ in 0..<8 { t += 1.0 / 60; b.scroll(by: 40, gesture: pad(.changed), now: t) }    // 2400 pt/s, ends at 320
        b.scroll(by: 0, gesture: pad(.ended), now: t + 0.01)
        var peak = 0.0
        t += 0.01
        while t < t + 0.0 + 8 && t < 10 { t += 1.0 / 60; b.advance(to: t); peak = max(peak, b.offsetNow(t)) ; if !b.isAnimating { break } }
        #expect(peak > 500)                          // stretched past the end
        #expect(b.offsetNow(t) == 500)               // and rested on it
    }

    @Test func systemMomentumIsUsedAsDeliveredThenBouncesAtTheEnd() {
        let b = body(max: 100, system: true)
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: 50, gesture: pad(.changed), now: 0.01)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.02)
        #expect(!b.isAnimating)                      // the system sends the tail
        b.scroll(by: 30, gesture: pad(.none, momentum: .began), now: 0.03)
        #expect(b.offsetNow(0.03) == 80)
        b.scroll(by: 30, gesture: pad(.none, momentum: .changed), now: 0.05)    // reaches the end
        #expect(b.isAnimating)
        b.scroll(by: 20, gesture: pad(.none, momentum: .changed), now: 0.07)    // ignored
        let t = run(b, from: 0.07, seconds: 2)
        #expect(b.offsetNow(t) == 100)
    }

    @Test func aMouseWheelClampsAtOnceAndNeverBounces() {
        let b = body(max: 100)
        b.scroll(by: -50, gesture: ScrollGesture(deltaY: 5), now: 0)
        #expect(b.offsetNow(0) == 0)
        b.scroll(by: 500, gesture: ScrollGesture(deltaY: -5), now: 0.1)
        #expect(b.offsetNow(0.1) == 100)
        #expect(!b.isAnimating)
    }

    @Test func aContentThatFitsDoesNotBounce() {
        let b = body(max: 0)
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: -100, gesture: pad(.changed), now: 0.01)
        #expect(b.offsetNow(0.01) == 0)
    }

    @Test func aNewGestureTakesOverARunningSpring() {
        let b = body()
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: -300, gesture: pad(.changed), now: 0.01)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.5)
        b.advance(to: 0.6)
        let mid = b.offsetNow(0.6)
        b.scroll(by: 0, gesture: pad(.began), now: 0.6)
        #expect(!b.isAnimating)
        b.scroll(by: 0, gesture: pad(.changed), now: 0.61)
        #expect(abs(b.offsetNow(0.61) - mid) < 0.01)  // picks up where the band is
    }

    @Test func layoutClampDoesNotKillABounce() {
        let b = body()
        b.scroll(by: 0, gesture: pad(.began), now: 0)
        b.scroll(by: -300, gesture: pad(.changed), now: 0.01)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.5)
        b.assign(0)                                    // `scroll = max(scroll, 0)` of a layout pass
        #expect(b.isAnimating)
    }

    @Test func noNaNOnOddInput() {
        let b = body()
        b.scroll(by: .nan, gesture: pad(.changed), now: 0)
        b.scroll(by: .infinity, gesture: pad(.changed), now: 0.01)
        b.scroll(by: 0, gesture: pad(.ended), now: 0.02)
        b.advance(to: 5)
        #expect(b.offsetNow(5).isFinite)
    }
}

extension ScrollBody {
    /// The offset at a given clock (tests do not use the wall clock).
    func offsetNow(_ t: Double) -> Double { advance(to: t); return positionAt }
}

@Suite struct ScrollerBarTests {
    let view = CGRect(x: 0, y: 0, width: 300, height: 400)

    @Test func knobIsProportionalAndFollowsTheOffset() {
        #expect(ScrollerBar.knob(viewport: view, content: 400, offset: 0, wide: false) == nil)     // fits: none
        let top = ScrollerBar.knob(viewport: view, content: 800, offset: 0, wide: false)!
        let end = ScrollerBar.knob(viewport: view, content: 800, offset: 400, wide: false)!
        #expect(abs(top.height - 198) < 1)               // half the content visible: about half the track
        #expect(top.minY == 2 && abs(end.maxY - 398) < 1e-9)
        #expect(top.maxX < view.maxX)
    }

    @Test func knobFadesAfterTheScrollStops() {
        let b = ScrollBody()
        b.scroll(by: 5, gesture: ScrollGesture(deltaY: -1), now: 10)
        #expect(b.scrollerAlpha(now: 10.5) == 1)
        #expect(b.scrollerAlpha(now: 10 + ScrollerBar.visibleFor + ScrollerBar.fade + 0.01) == 0)
        #expect(b.needsFrames(now: 10.5))
        #expect(!b.needsFrames(now: 20))
    }

    @Test func draggingTheKnobSetsTheOffset() {
        let b = ScrollBody()
        b.maxOffset = 400
        let now = HostScroll.now()
        func at(_ y: CGFloat) -> (Float, Float) { (Float(view.maxX - 5), Float(y)) }
        b.touch(now)
        let k = ScrollerBar.knob(viewport: view, content: 800, offset: 0, wide: true)!
        let (x, y) = at(k.midY)
        #expect(b.scrollerEvent(.mouseDown(x: x, y: y, modifiers: []), scale: 1, viewport: view, content: 800, now: now))
        #expect(b.scrollerEvent(.mouseDragged(x: x, y: Float(k.midY + 100)), scale: 1, viewport: view, content: 800, now: now))
        #expect(b.positionAt > 150 && b.positionAt < 250)      // 100 of 202 free track points
        #expect(b.scrollerEvent(.mouseUp(x: x, y: y), scale: 1, viewport: view, content: 800, now: now))
        #expect(!b.scrollerEvent(.mouseDown(x: 10, y: 10, modifiers: []), scale: 1, viewport: view, content: 800, now: now))
    }
}
