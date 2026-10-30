import Foundation
import Testing
@testable import SQCore

/// C2: perceptual (Oklab) color match with skin protection and a hue-cast clamp, fitted onto the Color Wheels.
@Suite struct ColorMatchOklabTests {
    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.z - b.z) <= tol
    }

    /// Patch of one color with small deterministic noise and a luma spread.
    static func patch(_ c: SIMD3<Float>, n: Int = 1200, shift: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        var s: UInt32 = 777
        func r() -> Float { s = s &* 1_664_525 &+ 1_013_904_223; return Float(s >> 8) / Float(1 << 24) }
        return (0..<n).map { i in
            let k = 0.75 + 0.5 * Float(i) / Float(n)
            return simd_clamp3(c * k + SIMD3(0.02 * (r() - 0.5), 0.02 * (r() - 0.5), 0.02 * (r() - 0.5)) + shift, 0, 1)
        }
    }

    static func meanMove(_ px: [SIMD3<Float>], _ w: ColorWheels) -> Float {
        px.reduce(0) { acc, p in
            let d = Oklab.fromDisplay(ColorWheelsModel.apply(p, w)) - Oklab.fromDisplay(p)
            return acc + (d * d).sum().squareRoot()
        } / Float(px.count)
    }

    @Test func oklabOfWhiteGreyAndRedMatchesThePublishedValues() {
        #expect(Self.near(Oklab.fromDisplay(.one), SIMD3(1, 0, 0), 1e-3))
        let g = Oklab.fromDisplay(SIMD3(repeating: 0.5))
        #expect(abs(g.y) < 1e-3 && abs(g.z) < 1e-3)
        // Linear sRGB red (display 1,0,0 is linear 1,0,0): L 0.628, a 0.225, b 0.126.
        #expect(Self.near(Oklab.fromDisplay(SIMD3(1, 0, 0)), SIMD3(0.628, 0.225, 0.126), 2e-3))
        // Round trip.
        let c = SIMD3<Float>(0.3, 0.6, 0.2)
        #expect(Self.near(Oklab.toDisplay(Oklab.fromDisplay(c)), c, 1e-4))
    }

    @Test func neutralInputGivesIdentity() throws {
        let grey = Self.patch(SIMD3(repeating: 0.5))
        let ref = try #require(ColorMatchStats.measure(grey))
        #expect(ColorMatchSolver.solve(display: grey, current: ColorWheels(), reference: ref) == nil)
        let plan = ColorMatchTargets(clip: ref, reference: ref)
        for p in grey.prefix(50) { #expect(Self.near(plan.target(Oklab.fromDisplay(p), display: p), Oklab.fromDisplay(p), 1e-5)) }
    }

    @Test func skinHuesAreRecognisedAndOthersAreNot() {
        #expect(ColorMatchTargets.skinWeight(Oklab.fromDisplay(SIMD3(0.82, 0.62, 0.50))) > 0.9)
        #expect(ColorMatchTargets.skinWeight(Oklab.fromDisplay(SIMD3(0.62, 0.42, 0.32))) > 0.9)
        #expect(ColorMatchTargets.skinWeight(Oklab.fromDisplay(SIMD3(0.30, 0.55, 0.22))) == 0)
        #expect(ColorMatchTargets.skinWeight(Oklab.fromDisplay(SIMD3(0.25, 0.36, 0.62))) == 0)
        #expect(ColorMatchTargets.skinWeight(Oklab.fromDisplay(SIMD3(repeating: 0.5))) == 0)
    }

    /// A gray scene with a colored object (about a fifth of the picture).
    static func scene(_ object: SIMD3<Float>, shift: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        ColorMatchTests.picture(1600).map { simd_clamp3($0 + shift, 0, 1) } + patch(object, n: 500, shift: shift)
    }

    @Test func aSkinObjectMovesLessThanAGreenObjectForTheSameCast() throws {
        let shift = SIMD3<Float>(-0.04, 0.0, 0.05)
        let skinColour = SIMD3<Float>(0.78, 0.58, 0.46), greenColour = SIMD3<Float>(0.36, 0.56, 0.30)
        let skinRef = try #require(ColorMatchStats.measure(Self.scene(skinColour, shift: shift)))
        let greenRef = try #require(ColorMatchStats.measure(Self.scene(greenColour, shift: shift)))
        let ws = try #require(ColorMatchSolver.solve(display: Self.scene(skinColour), current: ColorWheels(), reference: skinRef))
        let wg = try #require(ColorMatchSolver.solve(display: Self.scene(greenColour), current: ColorWheels(), reference: greenRef))
        let ms = Self.meanMove(Self.patch(skinColour), ws), mg = Self.meanMove(Self.patch(greenColour), wg)
        #expect(ms < mg, "skin \(ms) green \(mg)")
        // The plan itself keeps a fifth of the change on skin.
        let clip = try #require(ColorMatchStats.measure(Self.scene(skinColour)))
        let plan = ColorMatchTargets(clip: clip, reference: skinRef)
        let p = skinColour, lab = Oklab.fromDisplay(p)
        let full = plan.plain(lab, display: p) - lab, kept = plan.target(lab, display: p) - lab
        #expect((kept * kept).sum().squareRoot() < 0.3 * (full * full).sum().squareRoot())
    }

    @Test func matchOnAColouredSceneMovesTheBandsTowardsTheReference() throws {
        // Clip: a cooler, darker copy of a scene with a green and a skin object; reference: the scene itself.
        let refPic = Self.scene(SIMD3(0.36, 0.56, 0.30)) + Self.patch(SIMD3(0.78, 0.58, 0.46), n: 300)
        let clipPic = refPic.map { simd_clamp3(SIMD3($0.x * 0.85 - 0.02, $0.y * 0.9, $0.z * 0.95 + 0.04), 0, 1) }
        let ref = try #require(ColorMatchStats.measure(refPic))
        let before = try #require(ColorMatchStats.measure(clipPic))
        let w = try #require(ColorMatchSolver.solve(display: clipPic, current: ColorWheels(), reference: ref))
        let after = try #require(ColorMatchStats.measure(clipPic.map { ColorWheelsModel.apply($0, w) }))
        let e0 = ColorMatchTests.maxBandError(before, ref), e1 = ColorMatchTests.maxBandError(after, ref)
        #expect(e1 < e0 / 2, "band error \(e0) -> \(e1)")
        for (a, (b, r)) in zip(after.bands, zip(before.bands, ref.bands)) {
            #expect(ColorMatchTests.maxAbs(a - r) < ColorMatchTests.maxAbs(b - r), "\(b) -> \(a), ref \(r)")
        }
    }

    @Test func aSceneWideWarmCastIsCorrectedInFull() throws {
        // Every pixel is orange only because of the cast: nothing stands out, so nothing is protected.
        let ref = try #require(ColorMatchStats.measure(ColorMatchTests.picture()))
        let warm = ColorMatchTests.picture().map { simd_clamp3(SIMD3($0.x * 1.0, $0.y * 0.85, $0.z * 0.7), 0, 1) }
        let clip = try #require(ColorMatchStats.measure(warm))
        let plan = ColorMatchTargets(clip: clip, reference: ref)
        var held = 0, n = 0
        for i in Swift.stride(from: 0, to: warm.count, by: 8) {
            let p = warm[i], lab = Oklab.fromDisplay(p)
            n += 1
            if !Self.near(plan.target(lab, display: p), plan.plain(lab, display: p), 1e-4) { held += 1 }
        }
        #expect(held * 20 < n, "\(held) of \(n) held back")   // only stray noisy pixels
    }

    @Test func theHueOfAClearlyColouredObjectTurnsAtMostEightDegrees() throws {
        // Reference: the blue object turned towards cyan (a large hue cast).
        let blue = SIMD3<Float>(0.20, 0.30, 0.75)
        let clip = try #require(ColorMatchStats.measure(Self.scene(blue)))
        let ref = try #require(ColorMatchStats.measure(Self.scene(SIMD3(0.20, 0.60, 0.65))))
        let plan = ColorMatchTargets(clip: clip, reference: ref)
        var turned = 0
        for p in Self.patch(blue).prefix(200) {
            let lab = Oklab.fromDisplay(p), t = plan.target(lab, display: p), u = plan.plain(lab, display: p)
            func turn(_ x: SIMD3<Float>) -> Float {
                var d = abs(atan2f(x.z, x.y) - atan2f(lab.z, lab.y)) * 180 / .pi
                if d > 180 { d = 360 - d }
                return d
            }
            if turn(u) > 9 { turned += 1 }
            #expect(turn(t) <= ColorMatchTargets.maxHueCastDegrees + 0.01)
        }
        #expect(turned > 100)   // without the clamp the object would turn further
    }

    @Test func resultStaysWithinTheGradeBounds() throws {
        let src = ColorMatchTests.picture()
        // An extreme reference: very dark and very blue.
        let ref = try #require(ColorMatchStats.measure(src.map { simd_clamp3($0 * SIMD3(0.1, 0.2, 1.4), 0, 1) }))
        let w = try #require(ColorMatchSolver.solve(display: src, current: ColorWheels(), reference: ref))
        for v in [w.shadows, w.midtones, w.highlights] { #expect(v.amount >= 0 && v.amount <= 1 && v.hue >= 0 && v.hue < 360) }
        for l in [w.shadowsLuma, w.midtonesLuma, w.highlightsLuma] { #expect(l >= -100 && l <= 100) }
        #expect(w.saturation >= 0 && w.saturation <= 200)
    }
}
