import Foundation
import Testing
@testable import SQCore

@Suite struct IrisLightLeakTransitionTests {
    private func eval(_ k: TransitionKind, _ i: Int, _ n: Int = 11, soft: Double = 0.1) -> TransitionRender {
        TransitionRender.evaluate(kind: k, direction: .left, softness: soft, motionBlur: 0, easing: .linear, frameIndex: i, frames: n)
    }

    @Test func kindsAreVideoMotionWithEditableParameters() {
        for k in [TransitionKind.iris, .lightLeak] {
            #expect(k.trackKind == .video && k.isMotion && k.usesEasing && k.usesSoftness && !k.usesMotionBlur)
            #expect(TransitionKind.kinds(for: .video).contains(k))
            #expect(k.presetDuration(frameDuration: Time(1, 30)) != nil)
        }
        #expect(TransitionKind.iris.name == "Iris" && TransitionKind.lightLeak.name == "Light Leak")
        #expect(TransitionKind.lightLeak.usesDirection && !TransitionKind.iris.usesDirection)
        #expect(TransitionKind(rawValue: "iris") == .iris && TransitionKind(rawValue: "lightLeak") == .lightLeak)
    }

    @Test func irisGrowsFromNothingToCoveringTheFrame() {
        let first = eval(.iris, 0, 30), last = eval(.iris, 29, 30)
        #expect(first.compose == .iris && last.compose == .iris)
        // Corner radius is 1: the soft edge starts inside the center and ends beyond the corners.
        #expect(first.wipe.front - first.wipe.softness < 0.1)
        #expect(last.wipe.front - last.wipe.softness > 0.85)
        var prev = -1.0
        for i in 0..<11 { let f = eval(.iris, i).wipe.front; #expect(f > prev); prev = f }
    }

    @Test func irisMaskIsAnEllipseFittingTheFrame() {
        typealias I = TransitionRender.Iris
        #expect(I.radius(u: 0.5, v: 0.5) == 0)
        #expect(abs(I.radius(u: 0, v: 0) - 1) < 1e-12 && abs(I.radius(u: 1, v: 1) - 1) < 1e-12)
        // Edge midpoints are equally far whatever the aspect: an ellipse, not a circle.
        #expect(abs(I.radius(u: 1, v: 0.5) - 1 / 2.0.squareRoot()) < 1e-12 && I.radius(u: 1, v: 0.5) == I.radius(u: 0.5, v: 1))
        #expect(I.mask(u: 0.5, v: 0.5, front: 0.5, softness: 0.1) == 1)
        #expect(I.mask(u: 0, v: 0, front: 0.5, softness: 0.1) == 0)
        #expect(abs(I.mask(u: 1, v: 0.5, front: 1 / 2.0.squareRoot(), softness: 0.1) - 0.5) < 1e-9)
    }

    @Test func lightLeakMixesAtTheMiddleAndPeaksThere() {
        typealias L = TransitionRender.LightLeak
        #expect(L.mixWeight(progress: 0) == 0 && L.mixWeight(progress: 1) == 1)
        #expect(abs(L.mixWeight(progress: 0.5) - 0.5) < 1e-12)
        #expect(L.bell(progress: 0) == 0 && abs(L.bell(progress: 1)) < 1e-12 && abs(L.bell(progress: 0.5) - 1) < 1e-12)
        let mid = L.leak(u: 0.5, v: 0.5, progress: 0.5, direction: Vec2(-1, 0), softness: 0.1)
        let off = L.leak(u: 0.5, v: 0.5, progress: 0.0, direction: Vec2(-1, 0), softness: 0.1)
        #expect(mid.r > 0.8 && mid.r >= mid.g && mid.g >= mid.b)   // warm
        #expect(off.r == 0 && off.g == 0 && off.b == 0)
        let r = eval(.lightLeak, 5)
        #expect(r.compose == .lightLeak && abs(r.wipe.front - 0.5) < 0.1 && r.wipe.softness == 0.1)
    }

    @Test func screenBlendOnlyBrightens() {
        typealias L = TransitionRender.LightLeak
        let out = L.screen(base: (0.2, 0.4, 0.6), alpha: 1, leak: (0.5, 0.5, 0.5))
        #expect(out.r > 0.2 && out.g > 0.4 && out.b > 0.6 && out.r <= 1)
        let none = L.screen(base: (0.2, 0.4, 0.6), alpha: 1, leak: (0, 0, 0))
        #expect(none.r == 0.2 && none.g == 0.4 && none.b == 0.6)
    }
}
