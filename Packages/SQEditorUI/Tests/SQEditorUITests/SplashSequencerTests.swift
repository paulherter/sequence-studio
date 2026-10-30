import Foundation
import Testing
@testable import SQEditorUI

@Suite struct SplashSequencerTests {
    private func run(_ s: inout SplashSequencer, to end: TimeInterval, step: TimeInterval = 1.0 / 60, from: TimeInterval = 0) {
        var t = from
        while t < end { t += step; s.advance(to: t) }
    }

    @Test func travelIgnoresStartupProgressAndRespectsDuration() {
        var a = SplashSequencer(), b = SplashSequencer()
        var t = 0.0
        while t < SplashSequencer.minDisplay {
            t += 1.0 / 60
            a.advance(to: t); b.advance(to: t)
            #expect(a.progress == b.progress)
        }
        #expect(abs(b.progress - 1) < 1e-9)
        #expect(SplashSequencer.minDisplay == 2.2)
    }

    @Test func neverMovesBackwardsOnIrregularTicks() {
        var s = SplashSequencer()
        var prev = 0.0, t = 0.0
        for dt in [0.008, 0.27, 0.008, 0.16, 0.14, 0.008, 0.5, 0.01] {
            t += dt
            s.advance(to: t)
            #expect(s.progress >= prev)
            prev = s.progress
        }
    }

    @Test func readyBeforeDurationWaitsForTheTravel() {
        var s = SplashSequencer()
        s.requestFinish()
        run(&s, to: 2.1)
        #expect(s.phase == .loading)
        run(&s, to: 2.25, from: 2.1)
        #expect(s.phase == .ready)
        #expect(s.progress == 1)
    }

    @Test func readyAfterDurationRestsAtTheEnd() {
        var s = SplashSequencer()
        run(&s, to: 4)
        #expect(s.phase == .loading)
        #expect(s.progress == 1)
        s.requestFinish()
        s.advance(to: 4.01)
        #expect(s.phase == .ready)
    }

    @Test func readyThenFadeThenDone() {
        var s = SplashSequencer()
        s.requestFinish()
        let d = SplashSequencer.minDisplay
        run(&s, to: d + 0.01)
        #expect(s.phase == .ready)
        run(&s, to: d + SplashSequencer.readyHold + 0.1, from: d + 0.01)
        #expect(s.phase == .fading)
        #expect(s.alpha < 1 && s.alpha > 0)
        run(&s, to: d + 1.2, from: d + SplashSequencer.readyHold + 0.1)
        #expect(s.phase == .done && s.alpha == 0)
    }

    @Test func travelStepIsSmall() {
        var s = SplashSequencer()
        var prev = 0.0, maxStep = 0.0, t = 0.0
        while t < SplashSequencer.minDisplay {
            t += 1.0 / 120
            s.advance(to: t)
            maxStep = max(maxStep, s.progress - prev)
            prev = s.progress
        }
        // Peak speed of smootherstep is 1.875 / 2.2 per second; x spans about 232 pt: < 2.5 pt per 8 ms tick.
        #expect(maxStep * 232 < 2.5)
    }
}

@Suite struct SplashTravelMonotoneTests {
    @Test func xNeverMovesBackUnderStalledTicks() {
        var s = SplashSequencer()
        var t = 0.0, prev = -Double.infinity
        for dt in [0.008, 0.008, 0.27, 0.008, 0.14, 0.16, 0.008, 0.5, 0.3, 0.008, 0.008] {
            t += dt
            s.advance(to: t)
            let x = Double(SplashScene.travelX(at: SplashScene.tau(progress: s.progress, ready: false, readyElapsed: 0)))
            #expect(x >= prev)
            prev = x
        }
    }

    @Test func noPoseGestureDuringTravel() {
        var t = 0.0
        while t < SplashScene.driveEnd {
            let p = SplashScene.pose(at: t)
            #expect(p.y == 0 && p.sx == 1 && p.sy == 1 && p.r == 0)
            t += 0.05
        }
    }
}
