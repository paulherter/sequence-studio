import Testing
import Foundation
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

@Suite struct ShellMascotTests {
    private func quads(_ pose: SQMascotPose, tight: Bool = false) -> Int {
        var c = Canvas(width: 200, height: 200, atlas: nil, scale: 1)
        ShellMascot.draw(pose: pose, tight: tight, viewBox: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                         in: CGRect(x: 0, y: 0, width: 200, height: 200), into: &c)
        return c.list.quads.count
    }

    private var base: SQMascotPose { SQMascotLibrary.shared.animation(.work).still }

    @Test func theLensAppearsOnlyWhenItHasSizeAndNotInTightMode() {
        var p = base
        p[.mgs] = 0
        let without = quads(p)
        p[.mgs] = 1; p[.mgx] = 600; p[.mgy] = 600; p[.mgo] = 0.8
        #expect(quads(p) > without)
        #expect(quads(p, tight: true) == quads(p.with(.mgs, 0), tight: true))
    }

    @Test func floatingMarksAppearOutsideTightMode() {
        var p = base
        for k in [SQMascotKey.bs, .d1, .d2, .d3, .z1, .z2, .z3, .sp, .h1, .h2] { p[k] = 0 }
        let none = quads(p)
        for k in [SQMascotKey.bs, .d1, .z1, .sp, .h1] {
            var q = p; q[k] = 1
            #expect(quads(q) > none, "\(k)")
            #expect(quads(q, tight: true) == quads(p, tight: true), "\(k) tight")
        }
    }

    @Test func aBlinkSqueezesTheEyesAndChangesTheOutput() {
        var open = base
        open.blink = 1
        var shut = base
        shut.blink = 0
        var a = Canvas(width: 200, height: 200, atlas: nil, scale: 1)
        var b = a
        let r = CGRect(x: 0, y: 0, width: 200, height: 200), vb = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        ShellMascot.draw(pose: open, tight: false, viewBox: vb, in: r, into: &a)
        ShellMascot.draw(pose: shut, tight: false, viewBox: vb, in: r, into: &b)
        #expect(a.list.quads != b.list.quads)
    }

    @Test func theStagePlaysAndBlinksOverTime() {
        let stage = ShellMascotStage()
        var seen = Set<Double>()
        for (n, anim) in [SQMascotAnim.proud, .think, .wink, .peek, .sad].enumerated() {
            var t = 0.0
            for _ in 0..<2400 {   // 24 s at 100 fps
                seen.insert((stage.pose(anim, slot: n, now: t).blink * 100).rounded())
                t += 0.01
            }
        }
        #expect(seen.contains(0) && seen.contains(100), "the eyes close and open")
        #expect(stage.animating)
        stage.forget(slot: 0)
    }

    @Test func aSlotRestartsWhenItsAnimationChanges() {
        let stage = ShellMascotStage()
        _ = stage.pose(.work, slot: 2, now: 0)
        let p = stage.pose(.cheer, slot: 2, now: 0.01)
        #expect(p[.hide] < 0.5)
    }
}

private extension SQMascotPose {
    func with(_ k: SQMascotKey, _ v: Double) -> SQMascotPose { var p = self; p[k] = v; return p }
}
