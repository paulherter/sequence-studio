import Foundation
import Testing
@testable import SQCore

// Stabilizer v2: the per-frame residual perspective (what the similarity cannot express) is smoothed like the other
// channels, scaled by Strength, and written as keys the one warp pass reads. Zero perspective changes nothing.

private struct Rng {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private func vclip(_ seconds: Int64) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
}

/// A tilting camera: the perspective terms g, h wobble around a slow drift, the similarity stays still.
private func tilting(frames n: Int = 240, wobble: Double = 4e-5, seed: UInt64 = 9) -> (StabilizationAnalysis, [PerspectiveResidual]) {
    var r = Rng(s: seed)
    var real: [[Double]] = []
    for k in 0..<n {
        var v = [Double](repeating: 0, count: 8)
        v[6] = wobble * r.next() + 2e-6 * Double(k)
        v[7] = wobble * r.next()
        v[0] = wobble * 0.5 * r.next()
        real.append(v)
    }
    var pairs = [PerspectiveResidual.zero]
    for k in 1..<n { pairs.append(PerspectiveResidual(zip(real[k], real[k - 1]).map { $0 - $1 })) }
    let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: (0..<n).map { Time(1, 30) * Int64($0) },
                                  motions: [CameraMotion](repeating: .identity, count: n), perspective: pairs)
    return (a, real.map(PerspectiveResidual.init))
}

/// Shake of a point set after the plan's correction: jitter of where the corner points land over the frames.
private func shake(_ a: StabilizationAnalysis, _ real: [PerspectiveResidual], _ plan: StabilizationPlan?) -> Double {
    let corners = [Vec2(960, 540), Vec2(-960, 540), Vec2(960, -540), Vec2(-960, -540)]
    var total = 0.0
    for c in corners {
        let landed = real.indices.map { k -> Vec2 in
            var p = real[k].map(c)
            if let plan, k < plan.perspective.count { p = plan.perspective[k].map(p) }
            return p
        }
        total += Stabilizer.jitter(landed)
    }
    return total
}

@Suite struct StabilizerPerspectiveTests {
    @Test func aPoorInlierPairItsCheckAgreesWithAddsNoPerspective() throws {
        // The check agrees with the similarity (both still), which trusts the motion, not the pair's homography.
        var (a, _) = tilting()
        a.confidence = [Double](repeating: 1, count: a.motions.count)
        a.confidence[100] = 0.3
        a.checks = a.motions.map { $0 }
        #expect(a.confidence(at: 100) == 1 && a.storedConfidence(at: 100) == 0.3)
        a.perspective[100] = PerspectiveResidual([Double](repeating: 0, count: 6) + [3e-4, -3e-4])
        var without = a
        without.perspective[100] = .zero
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let clean = try #require(Stabilizer.plan(without, options: StabilizerOptions()))
        #expect(!plan.perspective.isEmpty)
        #expect(plan.perspective == clean.perspective)
        a.confidence[100] = 1                                    // trusted: the pair does count
        #expect(try #require(Stabilizer.plan(a, options: StabilizerOptions())).perspective != clean.perspective)
    }

    @Test func analysisVersionIsBumpedAndPerspectiveRoundTrips() throws {
        #expect(StabilizationAnalysis.currentVersion >= 8)
        let (a, _) = tilting(frames: 12)
        let back = try JSONDecoder().decode(StabilizationAnalysis.self, from: JSONEncoder().encode(a))
        #expect(back.perspective == a.perspective)
        let old = StabilizationAnalysis(pictureWidth: 10, pictureHeight: 10, frameTimes: [Time(0, 30)], motions: [.identity])
        #expect(try JSONDecoder().decode(StabilizationAnalysis.self, from: JSONEncoder().encode(old)).perspective.isEmpty)
    }

    @Test func residualPerspectiveShakeFallsBelowAThirdAndStrengthScalesIt() throws {
        let (a, real) = tilting()
        var o = StabilizerOptions()
        o.strength = 1
        let plan = try #require(Stabilizer.plan(a, options: o))
        #expect(plan.perspective.count == a.frameTimes.count)
        let before = shake(a, real, nil), after = shake(a, real, plan)
        #expect(before > 1)
        #expect(after < before * 0.33, "before \(before) after \(after)")
        o.strength = 0.5
        let half = try #require(Stabilizer.plan(a, options: o))
        let mid = shake(a, real, half)
        #expect(mid > after && mid < before)
        o.strength = 0
        let none = try #require(Stabilizer.plan(a, options: o))
        #expect(none.perspective.isEmpty)
    }

    @Test func zeroPerspectiveLeavesThePlanAndTheEffectUntouched() throws {
        let (withP, _) = tilting(frames: 60, wobble: 0)
        var a = withP
        a.perspective = []
        var zeros = a
        zeros.perspective = [PerspectiveResidual](repeating: .zero, count: a.frameTimes.count)
        let o = StabilizerOptions()
        let p1 = try #require(Stabilizer.plan(a, options: o)), p2 = try #require(Stabilizer.plan(zeros, options: o))
        #expect(p1.corrections == p2.corrections && p2.perspective.isEmpty)
        let clip = vclip(2)
        let e1 = Stabilizer.effect(plan: p1, analysis: a, clip: clip, frameDuration: Time(1, 30), options: o)
        let e2 = Stabilizer.effect(plan: p2, analysis: zeros, clip: clip, frameDuration: Time(1, 30), options: o)
        #expect(e1.parameters == e2.parameters)
        #expect(ClipEffect.stabilizePerspectiveKeys.allSatisfy { e2.parameters[$0] == nil })
        #expect(e2.rollingShutterFilter(atLocal: Time(1, 3)) == nil)
    }

    @Test func effectCarriesPerspectiveKeysAndTheFilterReadsThem() throws {
        let (a, _) = tilting(frames: 90)
        var o = StabilizerOptions()
        o.strength = 1
        let plan = try #require(Stabilizer.plan(a, options: o))
        let clip = vclip(3)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: clip, frameDuration: Time(1, 30), options: o)
        #expect(ClipEffect.stabilizePerspectiveKeys.contains { e.parameters[$0] != nil })
        let t = Time(1, 1)
        let f = try #require(e.rollingShutterFilter(atLocal: t))
        guard case .stabilizeWarp(let shear, _, let h) = f else { Issue.record("expected the combined warp"); return }
        #expect(shear == .zero && h.count == 8)
        // The keys follow the exact per-frame correction within the tolerances.
        let exact = Stabilizer.perspectiveCorrection(plan, a, at: clip.sourceTime(at: clip.start + t, frameDuration: Time(1, 30)))
        for i in 0..<8 { #expect(abs(h[i] - exact.values[i]) < (i == 6 || i == 7 ? 1e-6 : 1e-3)) }
    }

    @Test func rollingShutterComposesInTheSameFilter() throws {
        let (a, _) = tilting(frames: 90)
        var o = StabilizerOptions()
        o.strength = 1
        o.rollingShutter = true
        let plan = try #require(Stabilizer.plan(a, options: o))
        var e = Stabilizer.effect(plan: plan, analysis: a, clip: vclip(3),
                                  frameDuration: Time(1, 30), options: o)
        e.parameters[ClipEffect.rollingShearYKey] = AnimatedProperty(0.01)
        e.parameters[ClipEffect.rollingShearXKey] = AnimatedProperty(0)
        guard case .stabilizeWarp(let shear, _, let h)? = e.rollingShutterFilter(atLocal: Time(1, 1)) else {
            Issue.record("expected one combined warp"); return
        }
        #expect(abs(shear.y - 0.01) < 1e-12 && h.count == 8)
    }
}
