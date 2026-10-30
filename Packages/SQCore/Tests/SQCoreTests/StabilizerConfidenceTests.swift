import Foundation
import Testing
@testable import SQCore

// W9.7 (2a/2b): low-confidence measurements must never make a clip shakier, and cuts restart the path.

private struct Rand {
    var s: UInt64
    mutating func next() -> Double {          // -1...1
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private let fd = Time(1, 30)

/// True hand-held motions (jitter px / degrees) for `n` frames.
private func trueMotions(_ n: Int, jitter: Double = 6, rot: Double = 0.2, seed: UInt64 = 11) -> [CameraMotion] {
    var r = Rand(s: seed)
    let poses = (0..<n).map { _ in CameraPose(translation: Vec2(jitter * r.next(), jitter * r.next()), rotation: rot * r.next()) }
    return [.identity] + (1..<n).map { CameraMotion(from: poses[$0 - 1], to: poses[$0]) }
}

private func analysis(_ motions: [CameraMotion]) -> StabilizationAnalysis {
    StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: motions.indices.map { fd * Int64($0) },
                          motions: motions)
}

/// What the viewer sees: a world point through the TRUE camera path and the plan's correction.
private func seen(_ truth: [CameraMotion], _ plan: StabilizationPlan, _ range: Range<Int>? = nil) -> [Vec2] {
    let path = Stabilizer.path(truth)
    let r = range ?? path.indices
    return r.map { Affine2(plan.corrections[$0]).apply(path[$0].apply(Vec2(100, -50))) }
}

private func unstabilised(_ truth: [CameraMotion], _ range: Range<Int>? = nil) -> [Vec2] {
    let path = Stabilizer.path(truth)
    return (range ?? path.indices).map { path[$0].apply(Vec2(100, -50)) }
}

/// Measured = truth + noise of `noise` px on `range` (what a registration fitted to a blank wall delivers).
private func noisy(_ truth: [CameraMotion], _ range: Range<Int>, noise: Double, seed: UInt64 = 5) -> [CameraMotion] {
    var r = Rand(s: seed)
    var m = truth
    for k in range { m[k].dx += noise * r.next(); m[k].dy += noise * r.next(); m[k].rotation += r.next() }
    return m
}

@Suite struct StabilizerConfidenceTests {
    @Test func analysisVersionIsBumpedSoOldCachesAreMeasuredAgain() {
        #expect(StabilizationAnalysis.currentVersion >= 5)
    }

    @Test func confidenceAndChecksRoundTripAndOldAnalysesDecodeWithout() throws {
        var a = analysis(trueMotions(6))
        a.confidence = [1, 1, 0.2, 1, 0, 1]
        a.checks = [.identity, CameraMotion(dx: 1), nil, CameraMotion(dy: -2), nil, .identity]
        #expect(try JSONDecoder().decode(StabilizationAnalysis.self, from: JSONEncoder().encode(a)) == a)
        a.confidence = []; a.checks = []
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(!json.contains("confidence") && !json.contains("checks"))
        let back = try JSONDecoder().decode(StabilizationAnalysis.self, from: Data(json.utf8))
        #expect(back.confidence.isEmpty && back.checks.isEmpty)
        #expect(back.confidence(at: 3) == 1)
    }

    @Test func lowConfidenceStretchDoesNotAddShake() throws {
        let truth = trueMotions(300)
        let bad = 100..<160
        var a = analysis(noisy(truth, bad, noise: 25))
        // Without a confidence measure the noise is "corrected" into the picture.
        let blind = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(Stabilizer.jitter(seen(truth, blind, bad)) > Stabilizer.jitter(unstabilised(truth, bad)) * 1.5)
        // Flagged: the stretch falls back to the neighboring path, no worse than untouched.
        a.confidence = truth.indices.map { bad.contains($0) ? 0 : 1 }
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let ratio = Stabilizer.jitter(seen(truth, plan, bad)) / Stabilizer.jitter(unstabilised(truth, bad))
        let inner = 105..<155
        let innerRatio = Stabilizer.jitter(seen(truth, plan, inner)) / Stabilizer.jitter(unstabilised(truth, inner))
        #expect(ratio <= 1.05, "r \(ratio) inner \(innerRatio)")
        // The trusted parts are still steadied.
        let good = 10..<90
        #expect(Stabilizer.jitter(seen(truth, plan, good)) < Stabilizer.jitter(unstabilised(truth, good)) * 0.5)
        #expect(plan.uncorrectedFrames == 0)
    }

    @Test func mostlyUntrustedShotIsLeftAlone() throws {
        let truth = trueMotions(200)
        var a = analysis(noisy(truth, 0..<200, noise: 10))
        a.confidence = truth.indices.map { $0 % 10 < 3 ? 1 : 0 }   // 30 % trusted (a blank wall)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.zoom == 1)
        #expect(plan.corrections.allSatisfy { $0 == .identity })
        #expect(plan.uncorrectedFrames == 200)
        // The same noisy shot with checks that see the true motion: the guard confirms it would get shakier.
        a.checks = truth
        let checked = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(checked.uncorrectedFrames == 200)
    }

    @Test func mostlyUntrustedShotIsCorrectedWhenTheCheckConfirmsItGetsSteadier() throws {
        // Vision is right, the check could vouch for few pairs (moving subject) but measures less shake after.
        let truth = trueMotions(200)
        var a = analysis(truth)
        a.confidence = truth.indices.map { $0 % 10 < 3 ? 1 : 0 }
        a.checks = truth.indices.map { $0 % 2 == 0 ? truth[$0] : nil }
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.uncorrectedFrames == 0)
        let all = 10..<190
        #expect(Stabilizer.jitter(seen(truth, plan, all)) < Stabilizer.jitter(unstabilised(truth, all)) * 0.5)
    }

    @Test func guardFallsBackWhenTheIndependentCheckMeasuresMoreShake() throws {
        let truth = trueMotions(240, jitter: 2)
        // Undetected noise (confidence high everywhere), but the independent check sees the true motion.
        var a = analysis(noisy(truth, 0..<240, noise: 12))
        a.checks = truth
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.corrections.allSatisfy { $0 == .identity })
        #expect(plan.zoom == 1)
        #expect(plan.uncorrectedFrames == 240)
        // A good measurement with the same check keeps its correction.
        var good = analysis(trueMotions(240, jitter: 6))
        good.checks = good.motions
        let kept = try #require(Stabilizer.plan(good, options: StabilizerOptions()))
        #expect(kept.zoom > 1 && kept.uncorrectedFrames == 0)
    }

    @Test func guardDecidesPerSegment() throws {
        let truth = trueMotions(240, jitter: 6)
        var measured = noisy(truth, 120..<240, noise: 30)
        measured[120] = .identity
        var a = analysis(measured)
        a.cuts = [120]
        var checks: [CameraMotion?] = truth
        checks[120] = nil
        a.checks = checks
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.uncorrectedFrames == 120)
        let first = 10..<110
        #expect(Stabilizer.jitter(seen(truth, plan, first)) < Stabilizer.jitter(unstabilised(truth, first)) * 0.5)
        // The skipped segment only carries the shared zoom: no shift, no turn.
        let z = plan.zoom
        #expect(plan.corrections[120..<240].allSatisfy { $0.position.length < 1e-9 && abs($0.scale - z) < 1e-9 })
    }

    @Test func noisyZoomAndTurnAreLeftOutWhenTheCheckSaysTheyAddShake() throws {
        // A small iPhone-like shake that only moves (no turn, no zoom), measured with zoom / turn noise (Vision at 512 px
        // on 60 fps footage): the full similarity correction adds shake, the translation-only one removes it.
        let truth = trueMotions(300, jitter: 3, rot: 0)
        var r = Rand(s: 21)
        var measured = truth
        for k in 1..<300 { measured[k].rotation += 0.25 * r.next(); measured[k].scale *= exp(0.006 * r.next()) }
        var a = analysis(measured)
        a.checks = truth
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.uncorrectedFrames == 0)
        #expect(plan.models == [.translation])
        let all = 10..<290
        #expect(Stabilizer.jitter(seen(truth, plan, all)) < Stabilizer.jitter(unstabilised(truth, all)) * 0.6)
        #expect(plan.corrections.allSatisfy { abs($0.rotation) < 1e-9 && abs($0.scale - plan.zoom) < 1e-9 })
    }

    @Test func framesBetweenAnalysedFramesGetTheInterpolatedCorrection() throws {
        // 60 fps footage analyzed at 30 fps: every other source frame lies between two analyzed frames.
        let fd60 = Time(1, 60)
        var a = analysis(trueMotions(60))
        a.frameTimes = (0..<60).map { fd60 * Int64(2 * $0) }
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        let c10 = plan.corrections[10], c11 = plan.corrections[11]
        let mid = Stabilizer.correction(plan, a, at: fd60 * 21)
        #expect((mid.position - (c10.position + c11.position) * 0.5).length < 1e-9)
        #expect(abs(mid.rotation - (c10.rotation + c11.rotation) / 2) < 1e-9)
        #expect(abs(mid.scale - (c10.scale * c11.scale).squareRoot()) < 1e-9)
        #expect(Stabilizer.correction(plan, a, at: fd60 * 20) == c10)
        // Before the first / after the last analyzed frame: held.
        #expect(Stabilizer.correction(plan, a, at: fd60 * 200) == plan.corrections[59])
        // The effect on a 60 fps clip keys the in-between frames too.
        let clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd60 * 100), start: .zero)
        let e = Stabilizer.effect(plan: plan, analysis: a, clip: clip, frameDuration: fd60, options: StabilizerOptions())
        let s = e.stageTransform(atLocal: fd60 * 21, clipDuration: clip.duration, frame: Vec2(1920, 1080))
        #expect(abs(s.position.x - mid.position.x) <= Stabilizer.positionTolerance + 1e-9)
    }

    @Test func aCutBetweenAnalysedFramesIsNotBlended() throws {
        let fd60 = Time(1, 60)
        var a = analysis(trueMotions(60))
        a.frameTimes = (0..<60).map { fd60 * Int64(2 * $0) }
        a.cuts = [30]
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        // Source frame 59 lies between analyzed 29 (old shot) and 30 (new shot): it keeps the old shot's correction.
        #expect(Stabilizer.correction(plan, a, at: fd60 * 59) == plan.corrections[29])
    }

    @Test func aRealTurnKeepsTheFullModel() throws {
        let truth = trueMotions(300, jitter: 4, rot: 0.6)
        var a = analysis(truth)
        a.checks = truth
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.models == [.similarity])
        #expect(plan.corrections.contains { abs($0.rotation) > 0.1 })
    }

    @Test func withoutChecksTheFullModelIsUsed() throws {
        let plan = try #require(Stabilizer.plan(analysis(trueMotions(200)), options: StabilizerOptions()))
        #expect(plan.models == [.similarity])
    }

    @Test func missingChecksNeverBlockTheCorrection() throws {
        var a = analysis(trueMotions(200))
        a.checks = Array(repeating: nil, count: 200)
        let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
        #expect(plan.zoom > 1 && plan.uncorrectedFrames == 0)
    }
}

@Suite struct StabilizationCutTests {
    private func calm(_ n: Int) -> [CameraMotion] { trueMotions(n, jitter: 2, rot: 0.1) }

    @Test func aHistogramJumpIsACut() {
        var h = (0..<120).map { 0.02 + 0.01 * Double($0 % 3) }
        h[60] = 0.45
        let cuts = StabilizationCuts.detect(motions: calm(120), histogram: h, residual: Array(repeating: 3, count: 120))
        #expect(cuts == [60])
    }

    @Test func aResidualSpikeIsACutEvenWithSimilarColours() {
        // A jump cut inside the same room: colors match, but no motion explains the change.
        var r = (0..<120).map { 2.5 + 0.5 * Double($0 % 4) }
        r[45] = 24
        let cuts = StabilizationCuts.detect(motions: calm(120), histogram: Array(repeating: 0.03, count: 120), residual: r)
        #expect(cuts == [45])
    }

    @Test func aWrongMatchWithAZoomJumpIsACut() {
        var m = calm(120)
        m[80] = CameraMotion(dx: 30, dy: -10, rotation: 8, scale: 0.84)   // Vision "matched" across a cut
        let cuts = StabilizationCuts.detect(motions: m, histogram: Array(repeating: 0.03, count: 120),
                                            residual: Array(repeating: 3, count: 120))
        #expect(cuts == [80])
    }

    @Test func aFastPanOrBusySceneIsNotACut() {
        // Uniformly high change everywhere (a whip pan, leaves in wind): no single frame stands out.
        var r = Rand(s: 3)
        let h = (0..<150).map { _ in 0.25 + 0.05 * r.next() }
        let res = (0..<150).map { _ in 18 + 3 * r.next() }
        let m = (0..<150).map { _ in CameraMotion(dx: 40 + 5 * r.next(), dy: 2 * r.next(), rotation: 0.5 * r.next(), scale: 1 + 0.01 * r.next()) }
        #expect(StabilizationCuts.detect(motions: m, histogram: h, residual: res).isEmpty)
    }

    @Test func aLightChangeBothRegistrationsAgreeOnIsNoCut() {
        // C2160 7.07 s: histogram and residual jump (exposure / light), but Vision and the check agree on the motion, so
        // the camera path is measured across it and need not restart.
        var h = Array(repeating: 0.01, count: 120), r = Array(repeating: 1.6, count: 120)
        h[60] = 0.2; r[60] = 10.6
        var conf = Array(repeating: 1.0, count: 120)
        #expect(StabilizationCuts.detect(motions: calm(120), histogram: h, residual: r, checks: [], confidence: conf).isEmpty)
        conf[60] = 0.1   // they disagree there: a cut
        #expect(StabilizationCuts.detect(motions: calm(120), histogram: h, residual: r, checks: [], confidence: conf) == [60])
    }

    @Test func aVisionZoomJumpTheCheckDoesNotSeeIsNoCut() {
        // IMG_1281 0.6 s: Vision reports zoom 0.82-0.89 per frame on four frames, the check (well aligned, normal residual)
        // sees the steady camera: Vision's error (low confidence handles it), not a cut.
        let m0 = calm(120)
        var m = m0
        for k in 36...41 { m[k] = CameraMotion(dx: -20, dy: 60, rotation: -2.5, scale: 0.86) }
        let flat = Array(repeating: 0.02, count: 120), res = Array(repeating: 2.5, count: 120)
        var checks: [CameraMotion?] = m0
        #expect(StabilizationCuts.detect(motions: m, histogram: flat, residual: res, checks: checks, confidence: []).isEmpty)
        // The check sees the jump too (or cannot measure): a cut.
        checks[38] = CameraMotion(scale: 0.85)
        checks[40] = nil
        #expect(StabilizationCuts.detect(motions: m, histogram: flat, residual: res, checks: checks, confidence: []) == [38, 40])
    }

    @Test func everyCutNamesItsReason() {
        var m = calm(120)
        m[80] = CameraMotion(scale: 0.84)
        var h = Array(repeating: 0.03, count: 120)
        h[30] = 0.45
        var r = Array(repeating: 3.0, count: 120)
        r[55] = 24
        let found = StabilizationCuts.detectWithReasons(motions: m, histogram: h, residual: r)
        #expect(found.map(\.index) == [30, 55, 80])
        #expect(found.map(\.reason) == [.histogram, .residual, .motion])
    }

    @Test func missingScoresOnlyUseTheMotion() {
        var m = calm(50)
        m[20] = CameraMotion(scale: 1.18)
        #expect(StabilizationCuts.detect(motions: m, histogram: [], residual: []) == [20])
    }
}

@Suite struct StabilizationCutsReferenceTests {
    @Test func localReferenceSurvivesTinyInputs() {
        #expect(StabilizationCuts.localReference([], at: 0) == 0)
        #expect(StabilizationCuts.localReference([1], at: 0) == 0)
        #expect(StabilizationCuts.localReference([1, 2], at: 1) == 0)
        #expect(StabilizationCuts.localReference([1, 2], at: 0) == 0)
    }
}
