import Foundation
import Testing
@testable import SQCore

// Stabilizer rebuild: bilateral smoothing, crop-limited strength, Camera Lock on a synthetic shaky clip.

private struct Rng {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private func shaky(frames n: Int = 240, pan: Double = 0, jitter: Double = 8, rot: Double = 0.4, seed: UInt64 = 11) -> StabilizationAnalysis {
    var r = Rng(s: seed)
    let poses = (0..<n).map { k in
        CameraPose(translation: Vec2(pan * Double(k) + jitter * r.next(), jitter * r.next()), rotation: rot * r.next())
    }
    var motions = [CameraMotion.identity]
    for k in 1..<n { motions.append(CameraMotion(from: poses[k - 1], to: poses[k])) }
    return StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080,
                                 frameTimes: (0..<n).map { Time(1, 30) * Int64($0) }, motions: motions)
}

private func residual(_ a: StabilizationAnalysis, _ plan: StabilizationPlan, locked: Bool = false) -> (before: Double, after: Double) {
    let path = Stabilizer.path(a.motions)
    let w = Vec2(100, -50)
    let before = path.map { $0.apply(w) }
    let after = path.indices.map { Affine2(plan.corrections[$0]).apply(path[$0].apply(w)) }
    return (Stabilizer.jitter(before), Stabilizer.jitter(after))
}

@Suite struct StabilizerRebuildTests {
    @Test func bilateralSmoothFollowsAStepButFlattensJitter() {
        var poses = (0..<120).map { _ in CameraPose.identity }
        for k in 60..<120 { poses[k] = CameraPose(translation: Vec2(400, 0)) }
        let s = Stabilizer.bilateralSmooth(poses, sigma: 8, motionSigma: 50, reach: 1000)
        #expect(abs(s[59].translation.x) < 1)          // the step is not smeared backwards
        #expect(abs(s[60].translation.x - 400) < 1)
        let g = Stabilizer.smooth(poses, sigma: 8)
        #expect(abs(g[59].translation.x) > 20)          // a plain Gaussian smears it
    }

    @Test func smoothResidualDropsAndCropStaysBounded() throws {
        let a = shaky(pan: 1.5)
        var o = StabilizerOptions(); o.mode = .smooth
        let plan = try #require(Stabilizer.plan(a, options: o))
        let r = residual(a, plan)
        #expect(r.after < r.before * 0.4)
        #expect(plan.zoom <= 1 / (1 - o.maxCrop) + 1e-6)
    }

    @Test func cameraLockHoldsTheShot() throws {
        let a = shaky(jitter: 6, rot: 0.2)
        var o = StabilizerOptions(); o.mode = .locked
        let plan = try #require(Stabilizer.plan(a, options: o))
        let path = Stabilizer.path(a.motions)
        let w = Vec2(100, -50)
        let after = path.indices.map { Affine2(plan.corrections[$0]).apply(path[$0].apply(w)) }
        let xs = after.map(\.x), ys = after.map(\.y)
        #expect(xs.max()! - xs.min()! < 3)
        #expect(ys.max()! - ys.min()! < 3)
        #expect(plan.zoom <= 1 / (1 - o.maxLockedCrop) + 1e-6)
    }

    @Test func lockGivesWayOnAPanInsteadOfLeavingTheEdge() throws {
        let a = shaky(pan: 4, jitter: 2, rot: 0)
        var o = StabilizerOptions(); o.mode = .locked
        let plan = try #require(Stabilizer.plan(a, options: o))
        #expect(plan.fullyCovered)
        #expect(plan.zoom <= 1 / (1 - o.maxLockedCrop) + 1e-6)
    }

    @Test func aJumpTheSmoothingCannotFollowStillNeedsTheCutFlag() throws {
        // A 40 px jump the bilateral term still averages over (inside its width): without the flag the picture is dragged
        // across the jump, with the flag each side stays on its own.
        var a = shaky(frames: 200, jitter: 0, rot: 0)
        a.motions[100] = CameraMotion(dx: 40, dy: 0)
        var o = StabilizerOptions(); o.mode = .smooth
        let blind = try #require(Stabilizer.plan(a, options: o))
        a.cuts = [100]
        let cut = try #require(Stabilizer.plan(a, options: o))
        #expect(blind.corrections.contains { $0 != .identity })
        #expect(cut.corrections.allSatisfy { $0 == .identity })
    }
}
