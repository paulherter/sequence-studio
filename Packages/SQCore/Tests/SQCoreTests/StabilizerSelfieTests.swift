import Foundation
import Testing
@testable import SQCore

// Feedback 2026-10-18: Standard Stabilizer on a hand-held selfie "still feels very shaky". A synthetic selfie at the plan's
// interface: portrait 1080x1920 at 30 fps, hand shake of 1-4 Hz (5-12 px per part, about 0.6-1 degree), optionally a slow
// sway. The analysis as SQAnalysis delivers it for a large face in front of a textured background: the feature RANSAC
// keeps the background (motions = camera), but the face's points are outliers, so the inlier ratio and with it the
// feature confidence scatter around `Stabilizer.minConfidence`; the photometric check sees a blend of background and
// face (the face bobs on its own). The default settings must remove at least 80 % of the high-frequency shake.

private let fps = 30.0
private let width = 1080.0, height = 1920.0, frames = 300

private struct Rand {
    var s: UInt64
    mutating func next() -> Double {          // -1...1
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private func sine(_ t: Double, _ parts: [(a: Double, f: Double, p: Double)]) -> Double {
    parts.reduce(0) { $0 + $1.a * sin(2 * .pi * $1.f * t + $1.p) }
}

/// The true camera path: hand shake plus a slow sway of `drift` px.
private func shake(drift: Double) -> [CameraPose] {
    (0..<frames).map { k in
        let t = Double(k) / fps
        let x = sine(t, [(12, 1.3, 0), (6, 3.1, 1), (4, 2.2, 2.5)]) + drift * sine(t, [(1, 0.15, 0)])
        let y = sine(t, [(10, 1.7, 0.5), (5, 3.7, 0), (4, 1.1, 1.2)]) + drift * 0.5 * sine(t, [(1, 0.11, 1)])
        let r = sine(t, [(0.6, 1.1, 0), (0.3, 2.9, 2), (0.2, 3.9, 0.4)])
        return CameraPose(translation: Vec2(x, y), rotation: r)
    }
}

private func motions(_ poses: [CameraPose]) -> [CameraMotion] {
    [.identity] + (1..<poses.count).map { CameraMotion(from: poses[$0 - 1], to: poses[$0]) }
}

/// The selfie analysis: inlier ratio per frame uniform in `ratios` (feature confidence as FeatureTracker rates it), checks
/// 60 % background / 40 % face plus `checkNoise` px.
private func selfie(_ truth: [CameraPose], ratios: ClosedRange<Double>, checkNoise: Double = 0.5) -> StabilizationAnalysis {
    let ms = motions(truth)
    var r = Rand(s: 3)
    var a = StabilizationAnalysis(pictureWidth: Int(width), pictureHeight: Int(height),
                                  frameTimes: (0..<frames).map { Time(1, 30) * Int64($0) }, motions: ms)
    a.confidence = ms.map { _ in
        let ratio = ratios.lowerBound + (ratios.upperBound - ratios.lowerBound) * (r.next() + 1) / 2
        return min(max((ratio - 0.3) / 0.3, 0), 1)
    }
    let face = motions(truth.indices.map { k in
        truth[k].after(CameraPose(translation: Vec2(3 * sin(Double(k) / 5), 4 * sin(Double(k) / 7))))
    })
    a.checks = ms.indices.map { k in
        CameraMotion(dx: 0.6 * ms[k].dx + 0.4 * face[k].dx + checkNoise * r.next(),
                     dy: 0.6 * ms[k].dy + 0.4 * face[k].dy + checkNoise * r.next(),
                     rotation: 0.6 * ms[k].rotation + 0.4 * face[k].rotation + 0.02 * r.next())
    }
    return a
}

/// High-frequency part (above about 0.6 Hz): the track minus a second-difference smoother of it.
private func highPass(_ xs: [Double]) -> [Double] {
    let low = Stabilizer.solveSecondDifference(xs, lambda: [Double](repeating: 4000, count: xs.count - 2))
    return xs.indices.map { xs[$0] - low[$0] }
}

/// RMS high-frequency shake of four background points (half way to the corners): unstabilized and after the plan.
private func residual(_ truth: [CameraPose], _ plan: StabilizationPlan) -> (before: Double, after: Double) {
    var b = 0.0, a = 0.0, count = 0.0
    for q in [Vec2(-width / 4, -height / 4), Vec2(width / 4, -height / 4), Vec2(width / 4, height / 4), Vec2(-width / 4, height / 4)] {
        let before = truth.map { $0.apply(q) }
        let after = truth.indices.map { Affine2(plan.corrections[$0]).apply(truth[$0].apply(q)) }
        for v in [highPass(before.map(\.x)), highPass(before.map(\.y))] { b += v.reduce(0) { $0 + $1 * $1 } }
        for v in [highPass(after.map(\.x)), highPass(after.map(\.y))] { a += v.reduce(0) { $0 + $1 * $1 } }
        count += Double(truth.count * 2)
    }
    return ((b / count).squareRoot(), (a / count).squareRoot())
}

@Suite struct StabilizerSelfieTests {
    @Test(arguments: [0.0, 80, 160])
    func selfieShakeIsRemovedAtDefaultSettings(drift: Double) throws {
        let truth = shake(drift: drift)
        for ratios in [0.5...0.8, 0.35...0.65, 0.3...0.5] {
            let a = selfie(truth, ratios: ratios)
            for mode in [StabilizerMode.smooth, .auto, .locked] {
                var o = StabilizerOptions(); o.mode = mode
                let plan = try #require(Stabilizer.plan(a, options: o))
                let r = residual(truth, plan)
                // Locked on a sway the crop limit cannot hold gives way (by design), so only Smooth and Auto are held to
                // 80 % there; a still selfie (drift 0) is held to it in every mode.
                let required = mode == .locked && drift > 100 ? 0.5 : 0.8
                #expect(r.after <= r.before * (1 - required),
                        "drift \(drift) ratios \(ratios) \(mode): \(r.before) -> \(r.after), uncorrected \(plan.uncorrectedFrames)")
                #expect(plan.uncorrectedFrames == 0)
            }
        }
    }

    @Test func aMotionItsCheckAgreesWithIsTrustedWhateverItsOwnConfidence() {
        var a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: [.zero, Time(1, 30), Time(2, 30)],
                                      motions: [.identity, CameraMotion(dx: 4, dy: -3, rotation: 0.2), CameraMotion(dx: 4)])
        a.confidence = [1, 0.1, 0.1]
        a.checks = [nil, CameraMotion(dx: 4.5, dy: -3, rotation: 0.2), CameraMotion(dx: 30)]
        #expect(a.confidence(at: 1) == 1)                       // agrees within a pixel: trusted
        #expect(a.confidence(at: 2) == 0.1)                     // 26 px apart: the stored value stays
        a.checks = []
        #expect(a.confidence(at: 1) == 0.1)                     // no check: the stored value
    }

    @Test func registrationNoiseOnUntrustedFramesIsStillNotCorrectedIn() throws {
        // A blank-wall stretch: the motions there are 10-25 px of noise (confidence 0) the checks disagree with; they
        // still fall back to the neighbors' mean (which itself leaves a little of the wall's shake in).
        let truth = shake(drift: 0)
        var a = selfie(truth, ratios: 0.7...0.8, checkNoise: 0.3)
        var r = Rand(s: 9)
        let wall = 100..<160
        for k in wall {
            let x = r.next(), y = r.next()
            a.motions[k].dx += (x < 0 ? -1 : 1) * (10 + 15 * abs(x)); a.motions[k].dy += 25 * y; a.confidence[k] = 0
        }
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(wall.allSatisfy { a.confidence(at: $0) < Stabilizer.minConfidence })
        let seen = truth.indices.map { Affine2(plan.corrections[$0]).apply(truth[$0].apply(Vec2(100, -50))) }
        let raw = truth.map { $0.apply(Vec2(100, -50)) }
        #expect(Stabilizer.jitter(Array(seen[wall])) <= Stabilizer.jitter(Array(raw[wall])) * 1.1)
    }
}
