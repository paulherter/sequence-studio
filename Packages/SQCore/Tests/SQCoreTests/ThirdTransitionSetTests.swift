import Foundation
import Testing
@testable import SQCore

/// Flip 3D, Spring, Fall, Burn, Flare, Warp, Shake.
@Suite struct ThirdTransitionSetTests {
    static let kinds: [TransitionKind] = [.flip3D, .spring, .fall, .burn, .flare, .warp, .shake]

    private func eval(_ k: TransitionKind, _ i: Int, _ n: Int = 11, dir: TransitionDirection = .left, blur: Double = 0) -> TransitionRender {
        TransitionRender.evaluate(kind: k, direction: dir, softness: 0, motionBlur: blur, easing: .linear, frameIndex: i, frames: n)
    }

    @Test func areVideoMotionTransitionsWithADefaultLength() {
        for k in Self.kinds {
            #expect(k.trackKind == .video && k.isMotion && !k.isShapeReveal, "\(k)")
            #expect(k.presetDuration(frameDuration: Time(1, 30)) != nil, "\(k)")
            #expect(!k.name.isEmpty)
        }
    }

    @Test func progressRunsFromAlmostAToAlmostB() {
        for k in [TransitionKind.flip3D, .burn, .flare, .warp, .shake] {
            let f = (0..<11).map { eval(k, $0).wipe.front }
            #expect(f == f.sorted() && f.first! < 0.1 && f.last! > 0.9, "\(k)")
        }
    }

    @Test func flipCardIsWholeAtRestAndEdgeOnInTheMiddle() {
        typealias F = TransitionRender.Flip3D
        let p = F.cardPoint(x: 0.4, y: -0.3, angle: 0)
        #expect(p != nil && abs(p!.x - 0.4) < 1e-9 && abs(p!.y + 0.3) < 1e-9)
        #expect(F.cardPoint(x: 0, y: 0, angle: .pi / 2) == nil)
        #expect(F.cardPoint(x: 0, y: 0, angle: -0.5)!.x.magnitude < 1e-9)
    }

    @Test func springOvershootsThenSettlesExactly() {
        typealias S = TransitionRender.SpringFall
        #expect(S.spring(0) == 0 && abs(S.spring(1) - 1) < 1e-12)
        let top = (1...99).map { S.spring(Double($0) / 100) }.max()!
        #expect(top > 1.03 && top < 1.2, "\(top)")
        let r = eval(.spring, 5, dir: .left)
        #expect(r.compose == .incomingOver && r.outgoing == .identity)
    }

    @Test func fallDropsAndTilts() {
        let a = eval(.fall, 2, dir: .down), b = eval(.fall, 8, dir: .down)
        #expect(a.compose == .outgoingOver && a.incoming == .identity)
        #expect(b.outgoing.offset.y > a.outgoing.offset.y && b.outgoing.rotation > a.outgoing.rotation && a.outgoing.rotation > 0)
        #expect(eval(.fall, 10, dir: .down).outgoing.offset.y > 0.8)
    }
}
