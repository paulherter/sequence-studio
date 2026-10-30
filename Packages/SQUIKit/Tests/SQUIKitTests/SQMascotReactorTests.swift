import Testing
import Foundation
@testable import SQUIKit

@Suite("SQMascotReactor") struct SQMascotReactorTests {
    let lib = SQMascotLibrary.shared

    private func sleeper(reacts: Bool = true) -> SQMascotReactor {
        var r = SQMascotReactor(base: lib.animation(.sleep), library: lib, seed: 4, reacts: reacts)
        r.start()
        return r
    }

    private func run(_ r: inout SQMascotReactor, ms: Double, step: Double = 16) {
        var t = 0.0
        while t < ms { r.advance(step); t += step }
    }

    @Test func lookConfigMatchesDesign() {
        let l = lib.look
        #expect(l.rx == 55 && l.ry == 42 && l.lag == 130)
        #expect(l.x[.ex] == 15 && l.x[.fx] == 8 && l.x[.rot] == 2.4)
        #expect(l.y[.ey] == 13 && l.y[.fy] == 7)
    }

    @Test func targetIsStepsClampedToThreeAndOne() {
        let l = lib.look
        let a = l.target(dx: 110, dy: 21)
        #expect(abs(a.x - 2) < 1e-9 && abs(a.y - 0.5) < 1e-9)
        let b = l.target(dx: -1000, dy: 1000)
        #expect(b.x == -3 && b.y == 1)
    }

    @Test func followerLagsWithTimeConstant() {
        var f = SQMascotFollower(look: lib.look)
        _ = f.advance(130, dx: 55 * 2, dy: 0)          // one time constant toward 2 steps
        #expect(abs(f.gx - 2 * (1 - exp(-1))) < 1e-9)
        for _ in 0..<200 { _ = f.advance(16, dx: 55 * 2, dy: 0) }
        #expect(abs(f.gx - 2) < 1e-3)
        let p = f.look.pose(gx: 3, gy: 1)
        #expect(abs(p[.ex] - (lib.look.base[.ex] + 45)) < 1e-9)
        #expect(abs(p[.ey] - (lib.look.base[.ey] + 13)) < 1e-9)
    }

    @Test func dragWakesFollowsThenSleepsOrHops() {
        var r = sleeper()
        #expect(r.mode == .base)
        let began = r.dragBegan(); #expect(began)
        #expect(r.mode == .waking)
        run(&r, ms: 1500)
        #expect(r.mode == .following)
        r.dragMoved(dx: 200, dy: 0)
        run(&r, ms: 1000)
        #expect(abs(r.pose[.ex] - (lib.look.base[.ex] + 3 * 15)) < 0.5)   // clamped to 3 steps
        r.dragMoved(dx: -55, dy: 100)
        run(&r, ms: 1000)
        #expect(abs(r.pose[.ex] - (lib.look.base[.ex] - 15)) < 0.5)
        #expect(abs(r.pose[.ey] - (lib.look.base[.ey] + 13)) < 0.5)
        var away = r
        r.dragEnded(dropped: false)
        #expect(r.mode == .base)
        away.dragEnded(dropped: true)
        #expect(away.mode == .leaving)
        run(&away, ms: 1500)
        #expect(away.pose[.hide] == 1)
    }

    @Test func nonSleepingPipIgnoresEverything() {
        var r = sleeper(reacts: false)
        let began = r.dragBegan(); #expect(!began)
        r.hoverChanged(true)
        #expect(r.mode == .base)
    }

    @Test func hoverOpensAnEyeAndFallsShut() {
        var r = sleeper()
        r.hoverChanged(true)
        #expect(r.mode == .opening)
        run(&r, ms: 1500)
        #expect(r.mode == .open)
        #expect(r.pose.eR.kind == "pill")            // one eye open and held
        r.hoverChanged(false)
        #expect(r.mode == .dozing)
        run(&r, ms: 1500)
        #expect(r.mode == .base)
        #expect(r.animation.kind == lib.animation(.sleep).kind)
    }

    @Test func leavingMidOpenStillCloses() {
        var r = sleeper()
        r.hoverChanged(true)
        run(&r, ms: 200)
        r.hoverChanged(false)
        #expect(r.mode == .dozing)
        run(&r, ms: 1500)
        #expect(r.mode == .base)
    }

    @Test func dragTakesOverFromHover() {
        var r = sleeper()
        r.hoverChanged(true)
        run(&r, ms: 1500)
        let began = r.dragBegan(); #expect(began)
        #expect(r.mode == .waking)
    }
}
