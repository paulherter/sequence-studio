import Foundation
import Testing
@testable import SQTimelineUI

@Suite struct ZoomAnimationTests {
    let anim = ZoomAnimation(fromScale: 10, fromScroll: 300, toScale: 25, toScroll: 900, mode: .anchored(x: 200))

    @Test func frameCountAt60Hz() { #expect(ZoomAnimation.frameCount == 7) }   // 0.12 s * 60 = 7.2 -> 7

    @Test func endpointsExact() {
        #expect(anim.state(progress: 0) == (10, 300))
        #expect(anim.state(progress: 1) == (25, 900))
        #expect(anim.state(progress: 2) == (25, 900))
        #expect(ZoomAnimation.ease(0) == 0 && ZoomAnimation.ease(1) == 1)
    }

    @Test func monotonicScaleAndEase() {
        var last = -1.0, lastScale = 0.0
        for i in 0...60 {
            let p = Double(i) / 60
            let e = ZoomAnimation.ease(p)
            #expect(e >= last); last = e
            let s = anim.state(progress: p).scale
            #expect(s >= lastScale); lastScale = s
        }
        #expect(ZoomAnimation.ease(0.5) > 0.5)        // ease-out: ahead of linear
    }

    @Test func logSpaceKeepsRatioPerEase() {
        let s = anim.state(progress: 0.5)
        let e = ZoomAnimation.ease(0.5)
        #expect(abs(s.scale - 10 * pow(2.5, e)) < 1e-9)
    }

    @Test func anchoredTimeInvariant() {
        let t0 = (200 + 300.0) / 10
        for p in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let s = anim.state(progress: p)
            #expect(abs((200 + s.scrollX) / s.scale - t0) < 1e-9)
        }
    }

    @Test func freeModeEndpointsAndMonotonicLeftEdge() {
        let a = ZoomAnimation(fromScale: 50, fromScroll: 5000, toScale: 2, toScroll: 0, mode: .free)
        #expect(a.state(progress: 0) == (50, 5000) && a.state(progress: 1) == (2, 0))
        var last = Double.infinity
        for i in 0...20 {
            let s = a.state(progress: Double(i) / 20)
            let left = s.scrollX / s.scale
            #expect(left <= last + 1e-9); last = left
        }
    }

    @Test func progressClamps() {
        #expect(ZoomAnimation.progress(elapsed: 0.06) == 0.5)
        #expect(ZoomAnimation.progress(elapsed: 1) == 1 && ZoomAnimation.progress(elapsed: -1) == 0)
    }
}

@Suite struct ScrollZoomStateTests {
    typealias P = ScrollZoomState.Phase
    func run(_ events: [(P, P, Bool)]) -> [Bool] {
        var s = ScrollZoomState()
        return events.map { s.isZoom(phase: $0.0, momentumPhase: $0.1, modifierHeld: $0.2) }
    }

    @Test func releasedDuringMomentumKeepsZooming() {
        let r = run([(.began, .none, true), (.changed, .none, true), (.ended, .none, true),
                     (.none, .began, false), (.none, .changed, false), (.none, .ended, false)])
        #expect(r == [true, true, true, true, true, true])
    }

    @Test func zoomEndsAfterMomentumEnded() {
        let r = run([(.began, .none, true), (.ended, .none, true), (.none, .changed, false), (.none, .ended, false),
                     (.began, .none, false)])
        #expect(r == [true, true, true, true, false])
    }

    @Test func plainScrollNeverZoomsEvenIfKeyPressedInMomentum() {
        let r = run([(.began, .none, false), (.changed, .none, false), (.ended, .none, false),
                     (.none, .began, true), (.none, .changed, true), (.none, .ended, true)])
        #expect(r == [false, false, false, false, false, false])
    }

    @Test func releaseWithFingersDownReturnsToScroll() {
        #expect(run([(.began, .none, true), (.changed, .none, false)]) == [true, false])
    }

    @Test func mouseWheelIsStateless() {
        #expect(run([(.none, .none, true), (.none, .none, false), (.none, .none, true)]) == [true, false, true])
    }

    @Test func cancelledMomentumResets() {
        let r = run([(.began, .none, true), (.ended, .none, true), (.none, .cancelled, false), (.none, .changed, false)])
        #expect(r == [true, true, true, false])
    }
}

@Suite struct PlayheadHitTests {
    func hit(_ x: Double, _ y: Double = 100) -> Bool {
        PlayheadHit.isOnLine(pointX: x, pointY: y, playheadX: 500, contentLeft: 100, contentTop: 30, contentBottom: 400)
    }

    @Test func toleranceBand() {
        #expect(hit(500) && hit(496) && hit(504))
        #expect(!hit(495.9) && !hit(504.1))
    }

    @Test func outsideTrackAreaNeverHits() {
        #expect(!hit(500, 20))        // ruler
        #expect(!hit(500, 400))       // zoom bar / below
        let p = PlayheadHit.isOnLine(pointX: 50, pointY: 100, playheadX: 50, contentLeft: 100, contentTop: 30, contentBottom: 400)
        #expect(!p)                   // playhead scrolled under the headers
    }
}
