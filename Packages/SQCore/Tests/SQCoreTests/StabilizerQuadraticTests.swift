import Foundation
import Testing
@testable import SQCore

// Stabilizer v2: quadratic path smoothing with adaptive weights, Strength, Auto, live parameters on one analysis.

private struct Rng {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private func shaky(frames n: Int = 240, pan: Double = 0, jitter: Double = 8, rot: Double = 0.4, seed: UInt64 = 5) -> StabilizationAnalysis {
    var r = Rng(s: seed)
    let poses = (0..<n).map { k in
        CameraPose(translation: Vec2(pan * Double(k) + jitter * r.next(), jitter * r.next()), rotation: rot * r.next())
    }
    var motions = [CameraMotion.identity]
    for k in 1..<n { motions.append(CameraMotion(from: poses[k - 1], to: poses[k])) }
    return StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080,
                                 frameTimes: (0..<n).map { Time(1, 30) * Int64($0) }, motions: motions)
}

private func steadied(_ a: StabilizationAnalysis, _ plan: StabilizationPlan) -> (before: Double, after: Double) {
    let path = Stabilizer.path(a.motions)
    let w = Vec2(100, -50)
    let before = path.map { $0.apply(w) }
    let after = path.indices.map { Affine2(plan.corrections[$0]).apply(path[$0].apply(w)) }
    return (Stabilizer.jitter(before), Stabilizer.jitter(after))
}

@Suite struct StabilizerQuadraticTests {
    @Test func bandedSolveMatchesTheNormalEquations() {
        let p = [0, 3, -1, 4, 1, 5, 9, 2, 6.0]
        let lambda = [2, 0.5, 3, 1, 4, 0.2, 7.0]
        let s = Stabilizer.solveSecondDifference(p, lambda: lambda)
        // (I + D^T L D) s - p must vanish.
        for i in p.indices {
            var v = s[i]
            for r in max(0, i - 2)...min(i, p.count - 3) {
                let c: Double = i == r + 1 ? -2 : 1
                let ds = s[r] - 2 * s[r + 1] + s[r + 2]
                v += c * lambda[r] * ds
            }
            #expect(abs(v - p[i]) < 1e-9)
        }
    }

    @Test func aStraightLineStaysAndJitterGoes() {
        let line = (0..<100).map { Double($0) * 3 + 7 }
        let l = Stabilizer.baseLambda(sigma: 10)
        let s = Stabilizer.solveSecondDifference(line, lambda: Array(repeating: l, count: 98))
        for i in line.indices { #expect(abs(s[i] - line[i]) < 1e-6) }
    }

    @Test func residualShakeIsBelowThirtyPercent() throws {
        for pan in [0.0, 1.5] {
            let a = shaky(pan: pan)
            let plan = try #require(Stabilizer.plan(a, options: StabilizerOptions()))
            let r = steadied(a, plan)
            #expect(r.after < r.before * 0.3, "pan \(pan): \(r.after) vs \(r.before)")
        }
    }

    @Test func tripodHoldsAndAutoPicksItForAStillShot() throws {
        let a = shaky(jitter: 6, rot: 0.2)
        var o = StabilizerOptions(); o.mode = .locked
        let tripod = try #require(Stabilizer.plan(a, options: o))
        let t = steadied(a, tripod)
        #expect(t.after < t.before * 0.05)
        o.mode = .auto
        let auto = try #require(Stabilizer.plan(a, options: o))
        #expect(auto.corrections == tripod.corrections)
        let pan = shaky(pan: 1.5)
        let panAuto = try #require(Stabilizer.plan(pan, options: o))
        var s = StabilizerOptions(); s.mode = .smooth
        #expect(panAuto.corrections == (try #require(Stabilizer.plan(pan, options: s))).corrections)
    }

    @Test func strengthBlendsTowardNoCorrection() throws {
        let a = shaky()
        var o = StabilizerOptions()
        let full = steadied(a, try #require(Stabilizer.plan(a, options: o)))
        o.strength = 0.5
        let half = steadied(a, try #require(Stabilizer.plan(a, options: o)))
        o.strength = 0
        let none = steadied(a, try #require(Stabilizer.plan(a, options: o)))
        #expect(full.after < half.after && half.after < none.after)
        #expect(abs(none.after - none.before) < none.before * 0.05)
    }

    @Test func parametersReplanFromTheSameAnalysis() throws {
        // The plan is a pure function of the stored analysis: Strength / Smoothness / Crop Limit never need a new analysis.
        let a = shaky(), copy = a
        var o = StabilizerOptions()
        _ = Stabilizer.plan(a, options: o)
        o.strength = 0.4; o.smoothness = 1.2; o.maxCrop = 0.15
        _ = Stabilizer.plan(a, options: o)
        #expect(a == copy)
        #expect(StabilizationAnalysis.currentVersion >= 6)
    }

    @Test func cropLimitHoldsWhereSmoothingWouldOverCut() throws {
        let a = shaky(frames: 300, pan: 0.5, jitter: 40, rot: 2)
        var o = StabilizerOptions(); o.maxCrop = 0.08
        let plan = try #require(Stabilizer.plan(a, options: o))
        #expect(plan.zoom <= 1 / (1 - o.maxCrop) + 1e-6)
    }
}

@Suite struct StabilizerL1Tests {
    @Test func l1PathNeedsLessZoomThanTheQuadraticPathAtNoMoreJitter() {
        var r = Rng(s: 11)
        // Hand-held walk: slow sway of 150 px plus 35 px of shake.
        let real = (0..<300).map { k -> CameraPose in
            let t = Double(k)
            return CameraPose(translation: Vec2(150 * sin(t / 25) + 35 * r.next(), 100 * sin(t / 31) + 35 * r.next()), rotation: 3 * sin(t / 40) + 1.0 * r.next())
        }
        let hw = 960.0, hh = 540.0, cap = 1.06   // a tight crop limit: the quadratic path has to give way and gets jittery
        func correction(_ w: CameraPose, _ k: Int) -> CameraPose { w.after(real[k].inverse) }
        func zoom(_ p: [CameraPose]) -> Double? {
            var z = 1.0
            for k in p.indices { guard let c = Stabilizer.requiredZoom(correction(p[k], k), hw: hw, hh: hh, cap: cap) else { return nil }; z = max(z, c) }
            return z
        }
        let quad = Stabilizer.adaptiveQuadraticPath(real: real, sigma: 10) { Stabilizer.requiredZoom(correction($0, $1), hw: hw, hh: hh, cap: cap) != nil }
        let l1 = Stabilizer.l1CropPath(real: real, base: quad, hw: hw, hh: hh) { Stabilizer.requiredZoom(correction($0, $1), hw: hw, hh: hh, cap: cap) }
        let d = (hw * hw + hh * hh).squareRoot()
        let zq = zoom(quad)!, zl = zoom(l1)!
        let jq = Stabilizer.pathJitter(quad, reach: d), jl = Stabilizer.pathJitter(l1, reach: d)
        #expect(zl < zq - 0.005)
        #expect(jl <= jq * 1.0001)
    }

    @Test func lockedPoseIsCropAware() {
        // A path that drifts one way: the middle of the translation range is not the least-zoom pose once turn is involved.
        let real = (0..<120).map { k in CameraPose(translation: Vec2(Double(k) * 0.8, 0), rotation: k < 100 ? 0 : 6) }
        let hw = 960.0, hh = 540.0, cap = 3.0
        func z(_ p: CameraPose, _ k: Int) -> Double? { Stabilizer.requiredZoom(p.after(real[k].inverse), hw: hw, hh: hh, cap: cap) }
        let mid = CameraPose(translation: Vec2(47.6, 0), rotation: 0.3)
        let best = Stabilizer.lockPose(real: real, start: mid, step: 48, zoomOf: z)
        func worst(_ p: CameraPose) -> Double { real.indices.map { z(p, $0) ?? 9 }.max()! }
        #expect(worst(best) <= worst(mid))
    }
}
