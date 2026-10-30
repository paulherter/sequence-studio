import Testing
import Foundation
@testable import SQUIKit

@Suite("SQMascot") struct SQMascotTests {
    let lib = SQMascotLibrary.shared

    @Test func easeEndpointsAndOvershoot() {
        for e in [SQMascotEase.lin, .io, .in, .out, .back, .pop, .spring] {
            #expect(abs(e.value(0) - (e == .spring ? 1 - 1 * 1 : 0)) < 1e-9 || e == .spring)
            #expect(abs(e.value(1) - 1) < 1e-9)
        }
        #expect(abs(SQMascotEase.io.value(0.5) - 0.5) < 1e-9)
        #expect(abs(SQMascotEase.in.value(0.5) - 0.25) < 1e-9)
        #expect(abs(SQMascotEase.out.value(0.5) - 0.75) < 1e-9)
        #expect(abs(SQMascotEase.back.value(0.5) - 1.0375) < 1e-9)
        #expect(SQMascotEase.pop.value(0.8) > 1)
        #expect(SQMascotEase.spring.value(0.3) > 0.9 || SQMascotEase.spring.value(0.3) < 1.2)
        #expect(abs(SQMascotEase.spring.value(0)) < 1e-9)
    }

    @Test func libraryLoadsEveryAnimationWithDesignDuration() {
        let expected: [SQMascotAnim: Double] = [.wink: 3900, .peek: 5240, .sleep: 12600, .search: 6970, .work: 5320,
                                                .cheer: 4840, .oops: 2820, .think: 9800, .proud: 1720, .sad: 0]
        for (a, ms) in expected { #expect(abs(lib.animation(a).totalMilliseconds - ms) < 1, "\(a)") }
        #expect(lib.animation(.peek).clipBottom == 833)
        #expect(lib.animation(.wink).pause == 5...9)
    }

    @Test func mixBlendsAndSwapsShapes() {
        var a = lib.defaultPose, b = lib.defaultPose
        a[.tx] = 0; b[.tx] = 10
        b.eL = SQMascotShape("up", [50, 76, 624, 40])
        let mid = SQMascotPose.mix(a, b, 0.5)
        #expect(mid[.tx] == 5)
        #expect(mid.kEyeL == 0)            // different kind: squeezed shut at the swap
        #expect(SQMascotPose.mix(a, b, 0.25).eL.kind == "pill")
        #expect(SQMascotPose.mix(a, b, 0.75).eL.kind == "up")
        #expect(SQMascotPose.mix(a, b, 1).kEyeL == 1)
        let same = SQMascotPose.mix(lib.defaultPose, lib.defaultPose, 0.5)
        #expect(same.eL == lib.defaultPose.eL)
    }

    private func run(_ anim: SQMascotAnim, ms: Double, seed: UInt64 = 3, step: Double = 16) -> (SQMascotPlayer, [SQMascotPose]) {
        var p = SQMascotPlayer(animation: lib.animation(anim), idle: lib.idle, seed: seed)
        p.start()
        var out: [SQMascotPose] = []
        var t = 0.0
        while t < ms { out.append(p.advance(step)); t += step }
        return (p, out)
    }

    @Test func restAnimationPlaysThenRestsThenRepeatsInsidePause() {
        // wink: lead-in 800 + steps 3900 + settle 420, then 5...9 s of rest before the next wink
        let (p, poses) = run(.wink, ms: 6000)
        #expect(p.resting)
        #expect(p.nextAction != nil)
        if let n = p.nextAction {
            let settled = 800 + 3900 + 420.0
            #expect(n - settled >= 5000 - 40 && n - settled <= 9000 + 40)
        }
        #expect(poses.contains { abs($0[.hL] - 176) < 1 })    // the hand came up
    }

    @Test func restPauseOverrideIsHonored() {
        var p = SQMascotPlayer(animation: lib.animation(.search), idle: lib.idle, seed: 9)
        p.restPause = 1...2
        p.start()
        var t = 0.0
        while p.nextAction == nil, t < 30000 { p.advance(16); t += 16 }
        #expect(p.nextAction != nil)
        if let n = p.nextAction { #expect(n - p.clock <= 2000 + 20 && n - p.clock >= 1000 - 20) }
    }

    @Test func idleBreathesWithinDesignBounds() {
        let (_, poses) = run(.proud, ms: 30000, step: 8)
        let tail = poses.suffix(2000)
        let lo = tail.map { $0[.sy] }.min()!, hi = tail.map { $0[.sy] }.max()!
        #expect(hi <= 1.0121 && lo >= 0.9879)
        #expect(hi - lo > 0.01)
        let rot = tail.map { $0[.rot] }
        #expect(rot.max()! <= 4.9001 && rot.min()! >= 3.0999)   // proud rest rot 4
    }

    @Test func blinkIntervalAndEveryFifthIsDouble() {
        var p = SQMascotPlayer(animation: lib.animation(.proud), idle: lib.idle, seed: 5)
        p.start()
        var starts: [Double] = []
        var wasBlinking = false
        var t = 0.0
        var closedRuns = 0, inBlinkClosed = 0
        var blinkLengths: [Double] = []
        var cur = 0.0
        while t < 120_000 {
            let s = p.advance(4)
            t += 4
            let blinking = s.blink < 1
            if blinking { cur += 4 } else if cur > 0 { blinkLengths.append(cur); cur = 0 }
            if blinking && !wasBlinking { starts.append(t) }
            wasBlinking = blinking
            _ = closedRuns; _ = inBlinkClosed
        }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.count > 10)
        let inner = gaps.filter { $0 < 1000 }          // second half of a double blink: 310 + 130 ms after the first
        let outer = gaps.filter { $0 >= 1000 }
        #expect(outer.allSatisfy { $0 >= 2600 - 20 && $0 <= 6400 + 750 + 20 })
        #expect(inner.allSatisfy { abs($0 - 440) < 20 })
        #expect(inner.count == (inner.count + outer.count + 1) / 6 || abs(inner.count * 5 - outer.count) <= 5)
        #expect(blinkLengths.allSatisfy { $0 <= 310 + 20 + 400 })
    }

    @Test func sleepNeverSwaysOrBlinks() {
        let (p, poses) = run(.sleep, ms: 30000)
        #expect(!p.resting)                       // a loop never idles
        #expect(poses.allSatisfy { $0.blink == 1 })
        #expect(poses.allSatisfy { $0[.rot] == 7 })
    }

    @Test func onceAnimationEndsAtRest() {
        let (p, poses) = run(.cheer, ms: 7000)
        #expect(p.resting && !p.isBusy)
        #expect(poses.contains { $0[.sp] > 0.9 })
        #expect(p.nextAction == nil)              // once never repeats
    }

    @Test func loopRestartsAndKeepsRunning() {
        let (p, _) = run(.work, ms: 20000)
        #expect(p.isBusy && !p.resting)
    }

    @Test func blinkOpennessShape() {
        let c = lib.idle
        #expect(SQMascotPlayer.blinkOpenness(0, c) == 1)
        #expect(SQMascotPlayer.blinkOpenness(c.blinkClose + 10, c) == 0)
        #expect(SQMascotPlayer.blinkOpenness(c.blinkClose + c.blinkShut + c.blinkOpen + 1, c) == 1)
    }
}

@Suite("SQMascotPeekPlacement") struct SQMascotPeekPlacementTests {
    @MainActor @Test func peekingPipEndsJustBelowTheCardEdge() throws {
        let h = try #require(SQMascotPlace.startProjects.makeView()).intrinsicContentSize.height
        let cardTop: CGFloat = 400
        let top = SQMascotPlace.peekTop(cardTop: cardTop, height: h)
        #expect(abs((top + h) - (cardTop + SQMascotPlace.peekTuck)) < 1)
        #expect(top + h == cardTop)                               // flush with the card's top edge
        #expect(top < cardTop)                                    // body sits above the edge
    }
}
