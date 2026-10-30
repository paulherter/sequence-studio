import Foundation
import Testing
@testable import SQCore

/// Mask tracking beyond translation/scale: the motion model (3 x 3 projective map), robust fits per track mode from
/// point correspondences with known ground truth, and writing tracked motions as path keys.
@Suite struct MaskMotionTests {
    func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { (a - b).length < tol }

    /// Ground truth: rotate by `deg` and scale by `s` about `c`, then move by `t` (pixel space).
    func similarity(_ p: Vec2, deg: Double, s: Double, c: Vec2, t: Vec2) -> Vec2 {
        let a = deg * .pi / 180, d = p - c
        return c + t + Vec2((cos(a) * d.x - sin(a) * d.y) * s, (sin(a) * d.x + cos(a) * d.y) * s)
    }

    func grid(_ lo: Vec2, _ hi: Vec2, _ n: Int) -> [Vec2] {
        (0..<n).flatMap { i in (0..<n).map { j in
            Vec2(lo.x + (hi.x - lo.x) * Double(i) / Double(n - 1), lo.y + (hi.y - lo.y) * Double(j) / Double(n - 1))
        } }
    }

    @Test func motionAppliesComposesAndInverts() throws {
        let t = MaskMotion(translation: Vec2(3, -2))
        let r = MaskMotion(rotation: .pi / 2, about: Vec2(1, 1))
        #expect(near(t.apply(Vec2(1, 1)), Vec2(4, -1)))
        #expect(near(r.apply(Vec2(2, 1)), Vec2(1, 2)))           // y down: +90 deg turns +x into +y
        let both = t.then(r)                                     // t first, then r
        #expect(near(both.apply(Vec2(0, 0)), r.apply(t.apply(Vec2(0, 0)))))
        let inv = try #require(both.inverse)
        #expect(near(inv.apply(both.apply(Vec2(5, 7))), Vec2(5, 7)))
        #expect(near(MaskMotion.identity.apply(Vec2(0.3, 0.4)), Vec2(0.3, 0.4)))
    }

    @Test func pixelMotionMapsToFrameFractions() {
        // A pixel rotation on a 16:9 frame is no rotation in fractions; the conjugated map must still agree.
        let px = MaskMotion(rotation: 0.3, about: Vec2(960, 540))
        let f = px.inFractions(width: 1920, height: 1080)
        let p = Vec2(0.7, 0.2)
        let viaPx = px.apply(Vec2(p.x * 1920, p.y * 1080))
        #expect(near(f.apply(p), Vec2(viaPx.x / 1920, viaPx.y / 1080), 1e-9))
        #expect(near(f.inPixels(width: 1920, height: 1080).apply(Vec2(100, 50)), px.apply(Vec2(100, 50)), 1e-6))
    }

    @Test func boxMotionMatchesTheOldBoxTracking() {
        let p = MaskPath.rectangle(Vec2(0.2, 0.2), Vec2(0.4, 0.6))
        let a = p.bounds, b = MaskTrackBox(center: Vec2(0.5, 0.5), size: Vec2(0.4, 0.4))
        for scale in [true, false] {
            let old = p.tracked(from: a, to: b, scale: scale)
            let new = p.transformed(by: MaskMotion(from: a, to: b, scale: scale))
            for (o, n) in zip(old.vertices, new.vertices) {
                #expect(near(o.point, n.point) && near(o.inTangent, n.inTangent) && near(o.outTangent, n.outTangent))
            }
        }
    }

    @Test func fitsEachModeExactlyFromCleanPoints() throws {
        let src = grid(Vec2(100, 80), Vec2(220, 200), 6)
        let c = Vec2(160, 140), t = Vec2(12, -7)
        let dst = src.map { similarity($0, deg: 17, s: 1.12, c: c, t: t) }
        let rot = try #require(MaskMotionFit.fit(from: src, to: dst, mode: .rotation))
        for (s, d) in zip(src, dst) { #expect(near(rot.motion.apply(s), d, 1e-6)) }
        #expect(rot.rms < 1e-6 && rot.inliers == src.count)

        // Position only: the mean shift, no turn (a point at the centroid lands on its target).
        let pos = try #require(MaskMotionFit.fit(from: src, to: dst, mode: .position))
        #expect(near(pos.motion.apply(c), c + t, 1e-6))
        #expect(near(pos.motion.apply(Vec2(0, 0)) - pos.motion.apply(Vec2(1, 0)), Vec2(-1, 0), 1e-9))

        // Scale: uniform zoom about the centroid, no turn.
        let sc = try #require(MaskMotionFit.fit(from: src, to: src.map { similarity($0, deg: 0, s: 0.8, c: c, t: t) }, mode: .scale))
        #expect(near(sc.motion.apply(Vec2(220, 200)), similarity(Vec2(220, 200), deg: 0, s: 0.8, c: c, t: t), 1e-6))

        // Perspective: a known projective map.
        let h = MaskMotion(m: [1.05, 0.08, 4, -0.03, 0.97, 9, 0.0004, -0.0002, 1])
        let persp = try #require(MaskMotionFit.fit(from: src, to: src.map { h.apply($0) }, mode: .perspective))
        for s in src { #expect(near(persp.motion.apply(s), h.apply(s), 1e-5)) }
    }

    @Test func robustFitIgnoresOutliers() throws {
        var rng = SplitMix(seed: 7)
        let src = grid(Vec2(0, 0), Vec2(200, 120), 8)
        var dst = src.map { similarity($0, deg: -9, s: 1, c: Vec2(100, 60), t: Vec2(5, 3)) }
        // Small noise on all, 15 % gross outliers (background flow leaking into the region).
        for i in dst.indices { dst[i] = dst[i] + Vec2(rng.unit() * 0.2, rng.unit() * 0.2) }
        for i in stride(from: 0, to: dst.count, by: 7) { dst[i] = dst[i] + Vec2(40 * rng.unit(), 40 * rng.unit()) }
        for mode in [MaskTrackMode.rotation, .perspective] {
            let fit = try #require(MaskMotionFit.fit(from: src, to: dst, mode: mode))
            for p in [Vec2(0, 0), Vec2(200, 120), Vec2(0, 120)] {
                let truth = similarity(p, deg: -9, s: 1, c: Vec2(100, 60), t: Vec2(5, 3))
                #expect((fit.motion.apply(p) - truth).length < 0.5, "mode \(mode)")
            }
            #expect(fit.inliers < src.count)
        }
    }

    @Test func fitNeedsEnoughPoints() {
        let p = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)]
        #expect(MaskMotionFit.fit(from: p, to: p, mode: .perspective) == nil)
        #expect(MaskMotionFit.fit(from: [], to: [], mode: .position) == nil)
        #expect(MaskMotionFit.fit(from: [Vec2(1, 1), Vec2(1, 1)], to: [Vec2(2, 2), Vec2(2, 2)], mode: .rotation) == nil)
    }

    @Test func samplePointsStayInsideThePolygon() {
        let tri = [Vec2(0, 0), Vec2(100, 0), Vec2(0, 100)]
        let pts = MaskMotionFit.samplePoints(in: tri, spacing: 10)
        #expect(pts.count > 30 && pts.count < 60)
        #expect(pts.allSatisfy { $0.x + $0.y < 100 && $0.x > 0 && $0.y > 0 })
        #expect(MaskMotionFit.samplePoints(in: tri, spacing: 10, limit: 12).count <= 12)
    }

    @Test func transformedPathRotatesPointsAndTangents() {
        let p = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.2, 0.2))
        let r = p.transformed(by: MaskMotion(rotation: .pi / 2, about: Vec2(0.5, 0.5)))
        for (a, b) in zip(p.vertices, r.vertices) {
            let d = a.point - Vec2(0.5, 0.5)
            #expect(near(b.point, Vec2(0.5 - d.y, 0.5 + d.x)))
            #expect(near(b.outTangent, Vec2(-a.outTangent.y, a.outTangent.x)))
        }
    }

    @Test func applyingMotionsKeysTurnedShapes() {
        var m = ClipMask.make(.rectangle, name: "M")
        m.path = AnimatedProperty(MaskPath.rectangle(Vec2(0.4, 0.4), Vec2(0.6, 0.6)))
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.masks = [m]
        let turn = MaskMotion(rotation: .pi / 4, about: Vec2(0.5, 0.5))
        let n = c.applyMaskTrack(m.id, times: [.zero, Time(1, 2), Time(1, 1)], motions: [.identity, turn, nil])
        #expect(n == 2)
        let keys = c.mask(m.id)!.path.track.keys.sorted { $0.time < $1.time }
        #expect(keys.count == 2)
        #expect(near(keys[1].value.vertices[0].point, turn.apply(Vec2(0.4, 0.4))))
    }

    @Test func modeTitlesAndPointUse() {
        #expect(MaskTrackMode.allCases.map(\.title) == ["Position", "+ Scale", "+ Rotation", "Perspective"])
        #expect(!MaskTrackMode.position.usesPoints && !MaskTrackMode.scale.usesPoints)
        #expect(MaskTrackMode.rotation.usesPoints && MaskTrackMode.perspective.usesPoints)
        #expect(MaskTrackMode.default == .scale)
    }
}

/// Deterministic noise in -1...1.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) * 2 - 1 }
}
