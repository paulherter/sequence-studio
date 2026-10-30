import Foundation
import Testing
@testable import SQCore

@Suite struct TransitionBorderTests {
    @Test func oldFileDecodesWithoutBorderAndRoundTrips() throws {
        let t = Transition(kind: .push, duration: Time(10, 30), outgoing: UUID(), incoming: UUID())
        let data = try JSONEncoder().encode(t)
        #expect(!String(decoding: data, as: UTF8.self).contains("border"))
        let back = try JSONDecoder().decode(Transition.self, from: data)
        #expect(back.borderWidth == nil && back.borderColor == nil)
        var b = t
        b.borderWidth = 0.02; b.borderColor = [255, 0, 0]
        #expect(try JSONDecoder().decode(Transition.self, from: JSONEncoder().encode(b)) == b)
    }

    @Test func borderOnlyForEdgeKindsAndOffByDefault() {
        func eval(_ k: TransitionKind, _ b: TransitionRender.Border?) -> TransitionRender {
            TransitionRender.evaluate(kind: k, direction: .left, softness: 0.1, motionBlur: 0, easing: .linear,
                                      frameIndex: 4, frames: 9, border: b)
        }
        let b = TransitionRender.Border(width: 0.02, color: nil)
        let d = eval(.push, nil)
        #expect(d.border == nil)
        var p = eval(.push, b)
        #expect(p.border == b)
        p.border = nil; p.wipe = d.wipe
        #expect(p == d, "the border changes nothing else")
        #expect(eval(.softWipe, b).border == b)
        #expect(eval(.slide, b).border == b)
        #expect(eval(.crossDissolve, b).border == nil)
        #expect(TransitionRender.Border(width: 0, color: nil) == nil)
        #expect(TransitionRender.Border(width: 5, color: nil)?.width == TransitionKind.maxBorderWidth)
    }

    @Test func coverageIsOneInsideZeroOutsideAndHalfAtTheBandEdge() {
        let f = TransitionRender.Border.coverage
        #expect(f(0.5, 0.5, 0.1, 0.001) == 1)
        #expect(f(0.7, 0.5, 0.1, 0.001) == 0)
        #expect(abs(f(0.55, 0.5, 0.1, 0.001) - 0.5) < 1e-9)
    }

    @Test func bandFadesAtTheFirstAndLastFrame() {
        let f = TransitionRender.Border.coverage
        #expect(f(0.01, 0.01, 0.1, 0.001) < 0.15, "e = 0.01: no solid strip")
        #expect(f(0.99, 0.99, 0.1, 0.001) < 0.15, "e = 0.99: no solid strip")
        #expect(f(0.5, 0.5, 0.1, 0.001) == 1)
    }

    @Test func presetCarriesTheBorderAndApplyReplacesIt() throws {
        var t = Transition(kind: .push, duration: Time(10, 30), outgoing: UUID(), incoming: UUID())
        #expect(TransitionPreset.capture(from: t).borderWidth == nil)
        t.borderWidth = 0.03; t.borderColor = [255, 0, 0]
        let p = TransitionPreset.capture(from: t)
        #expect(p.borderWidth == 0.03 && p.borderColor == [255, 0, 0])
        let old = try JSONEncoder().encode(TransitionPreset(kind: .push, duration: Time(10, 30)))
        #expect(!String(decoding: old, as: UTF8.self).contains("border"))
        #expect(try JSONDecoder().decode(TransitionPreset.self, from: JSONEncoder().encode(p)) == p)
    }
}
