import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// +Rotation / Perspective mask tracking on synthetic frames with known ground truth: a textured patch carried by an
/// exact motion (rendered per pixel through its inverse) over a static textured background. Errors are measured on the
/// patch corners in px. The mask outline is the patch plus a few px of background all round.
@Suite struct MaskPointTrackerTests {
    static let w = 480, h = 270
    static let side = 110.0
    static let c0 = Vec2(170, 130)

    /// Smooth value noise in 0...1 (random lattice every `cell` px, bilinear in between), deterministic.
    struct Texture {
        let w: Int, h: Int, cell: Int
        var lattice: [Double]
        init(w: Int, h: Int, seed: UInt64, cell: Int = 6) {
            self.w = w; self.h = h; self.cell = cell
            var s = seed
            lattice = (0..<((w / cell + 2) * (h / cell + 2))).map { _ in
                s = s &* 6364136223846793005 &+ 1442695040888963407
                return Double(s >> 40) / Double(1 << 24)
            }
        }
        func at(_ x: Double, _ y: Double) -> Double {
            let lw = w / cell + 2
            let gx = min(max(x / Double(cell), 0), Double(w / cell)), gy = min(max(y / Double(cell), 0), Double(h / cell))
            let x0 = Int(gx), y0 = Int(gy), fx = gx - Double(x0), fy = gy - Double(y0)
            let a = lattice[y0 * lw + x0], b = lattice[y0 * lw + x0 + 1]
            let c = lattice[(y0 + 1) * lw + x0], d = lattice[(y0 + 1) * lw + x0 + 1]
            return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
        }
    }

    static let background = Texture(w: w, h: h, seed: 1)
    static let patch = Texture(w: Int(side), h: Int(side), seed: 99)

    /// Turn `deg` per frame about the start center and move `step` per frame; `tilt` adds a growing perspective (the
    /// patch's right side recedes) about the center.
    static func truth(_ i: Int, deg: Double, step: Vec2, tilt: Double = 0) -> MaskMotion {
        let k = tilt * Double(i)
        let toC = MaskMotion(translation: c0 * -1), back = MaskMotion(translation: c0)
        let persp = toC.then(MaskMotion(m: [1, 0, 0, 0, 1, 0, k, 0, 1])).then(back)
        return persp.then(MaskMotion(rotation: deg * Double(i) * .pi / 180, about: c0))
            .then(MaskMotion(translation: step * Double(i)))
    }

    /// Frame through motion `m`: each pixel looks up where it came from; inside the patch square it shows the patch.
    static func frame(_ m: MaskMotion) throws -> CVPixelBuffer {
        let inv = try #require(m.inverse)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        let b = try #require(pb)
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(b))
        let row = CVPixelBufferGetBytesPerRow(b)
        let lo = c0 - Vec2(side / 2, side / 2)
        for y in 0..<h {
            let r = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let p = Vec2(Double(x), Double(y)), q = inv.apply(p) - lo
                let v = q.x >= 0 && q.y >= 0 && q.x < side && q.y < side ? patch.at(q.x, q.y) : background.at(p.x, p.y)
                let u = UInt8(min(max(v * 255, 0), 255))
                r[x * 4] = u; r[x * 4 + 1] = u; r[x * 4 + 2] = u; r[x * 4 + 3] = 255
            }
        }
        return b
    }

    static var corners: [Vec2] { [Vec2(-1, -1), Vec2(1, -1), Vec2(1, 1), Vec2(-1, 1)].map { c0 + $0 * (side / 2) } }

    /// Final / worst mean corner error (px) and frames tracked over `n` frames.
    static func measure(mode: MaskTrackMode, deg: Double, step: Vec2, tilt: Double = 0, n: Int,
                        pad: Double = 6) throws -> (final: Double, worst: Double, frames: Int) {
        let region = corners.map { c0 + ($0 - c0) * ((side / 2 + pad) / (side / 2)) }
            .map { Vec2($0.x / Double(w), $0.y / Double(h)) }
        var tracker = MaskPointTracker(region: region, mode: mode)
        var worst = 0.0, final = Double.infinity, frames = 0
        for i in 0..<n {
            let t = truth(i, deg: deg, step: step, tilt: tilt)
            guard let f = tracker.step(try frame(t)) else { break }
            let px = f.inPixels(width: Double(w), height: Double(h))
            let err = corners.map { (px.apply($0) - t.apply($0)).length }.reduce(0, +) / 4
            worst = max(worst, err); final = err; frames = i + 1
        }
        return (final, worst, frames)
    }

    @Test func lucasKanadeFindsASubPixelShift() throws {
        let a = try #require(LucasKanade.gray(try Self.frame(.identity)))
        let b = try #require(LucasKanade.gray(try Self.frame(MaskMotion(translation: Vec2(3.4, -2.2)))))
        let pts = MaskMotionFit.samplePoints(in: Self.corners.map { Self.c0 + ($0 - Self.c0) * 0.7 }, spacing: 8)
        let (from, to) = try #require(LucasKanade.pairs(LucasKanade.pyramid(a), LucasKanade.pyramid(b), pts))
        #expect(from.count > pts.count * 9 / 10)
        let mean = zip(from, to).map { $1 - $0 }.reduce(Vec2.zero, +) * (1 / Double(from.count))
        #expect((mean - Vec2(3.4, -2.2)).length < 0.1, "mean shift \(mean)")
    }

    @Test func flatAreasAreNotTracked() throws {
        let flat = LucasKanade.Gray(w: 64, h: 64, px: [Float](repeating: 0.5, count: 64 * 64))
        let p = LucasKanade.pyramid(flat)
        #expect(LucasKanade.track(Vec2(32, 32), p, p) == nil)
    }

    /// 30 frames, 2 deg and (2, 1) px per frame: 58 deg and 65 px in all.
    @Test func rotationModeFollowsATurningPatch() throws {
        let r = try Self.measure(mode: .rotation, deg: 2, step: Vec2(2, 1), n: 30)
        print("PERF MaskPointTracker rotation: final \(r.final) worst \(r.worst) px")
        #expect(r.frames == 30)
        #expect(r.worst < 3, "worst corner error \(r.worst) px")
    }

    @Test func perspectiveModeFollowsATiltingPatch() throws {
        let r = try Self.measure(mode: .perspective, deg: 1, step: Vec2(1.5, 0.5), tilt: 0.00012, n: 30)
        let sim = try Self.measure(mode: .rotation, deg: 1, step: Vec2(1.5, 0.5), tilt: 0.00012, n: 30)
        print("PERF MaskPointTracker perspective: final \(r.final) worst \(r.worst) px (rotation mode: \(sim.worst) px)")
        #expect(r.frames == 30)
        #expect(r.worst < 4, "worst corner error \(r.worst) px")
        #expect(sim.worst > r.worst)
    }

    @Test func positionModeCannotTurn() throws {
        let r = try Self.measure(mode: .position, deg: 2, step: Vec2(2, 1), n: 15)
        #expect(r.worst > 10)
    }

    @Test func lostWhenThePatchLeavesTheFrame() throws {
        // 12 px per frame to the right: the patch is out of the 480 px frame after about 32 frames.
        let r = try Self.measure(mode: .rotation, deg: 0, step: Vec2(12, 0), n: 40)
        #expect(r.frames > 15 && r.frames < 40, "tracked \(r.frames) frames")
    }

    /// No template can be cut from an empty region: flagged as degraded, and the old template is never replaced by nil.
    @Test func noTemplateMarksTheTrackDegraded() throws {
        var tracker = MaskPointTracker(region: [], mode: .rotation)
        let frame = try Self.frame(.identity)
        #expect(tracker.step(frame) != nil)
        #expect(tracker.degraded)
        #expect(tracker.step(frame) != nil)
        #expect(tracker.degraded)
        var ok = MaskPointTracker(region: [Vec2(0.3, 0.3), Vec2(0.6, 0.3), Vec2(0.6, 0.7), Vec2(0.3, 0.7)], mode: .rotation)
        _ = ok.step(frame)
        #expect(!ok.degraded)
    }

    // MARK: Re-anchoring, confidence, hold

    /// Slow turn + zoom + drift about the start center: 0.3 deg, x1.002 and (0.3, 0.1) px per frame.
    static func longTruth(_ i: Int) -> MaskMotion {
        let z = pow(1.002, Double(i))
        return MaskMotion(m: [z, 0, c0.x * (1 - z), 0, z, c0.y * (1 - z), 0, 0, 1])
            .then(MaskMotion(rotation: 0.3 * Double(i) * .pi / 180, about: c0))
            .then(MaskMotion(translation: Vec2(0.3, 0.1) * Double(i)))
    }

    /// An unrelated textured frame (an occluder filling the picture).
    static func blank(_ seed: UInt64) throws -> CVPixelBuffer {
        let t = Texture(w: w, h: h, seed: seed, cell: 4)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        let b = try #require(pb)
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(b))
        let row = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h {
            let r = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let u = UInt8(t.at(Double(x), Double(y)) * 255)
                r[x * 4] = u; r[x * 4 + 1] = u; r[x * 4 + 2] = u; r[x * 4 + 3] = 255
            }
        }
        return b
    }

    static func error(_ f: MaskMotion, _ t: MaskMotion) -> Double {
        let px = f.inPixels(width: Double(w), height: Double(h))
        return corners.map { (px.apply($0) - t.apply($0)).length }.reduce(0, +) / 4
    }

    static var longRegion: [Vec2] {
        corners.map { c0 + ($0 - c0) * ((side / 2 + 6) / (side / 2)) }.map { Vec2($0.x / Double(w), $0.y / Double(h)) }
    }

    /// 300 frames of turn + zoom + drift (90 deg, 1.8x, 90 px): chaining alone drifts, template re-anchoring keeps the
    /// end error small.
    @Test func longTrackStaysAnchored() throws {
        var tracker = MaskPointTracker(region: Self.longRegion, mode: .rotation)
        var final = Double.infinity, worst = 0.0, frames = 0
        for i in 0..<300 {
            let t = Self.longTruth(i)
            guard let f = tracker.step(try Self.frame(t)) else { break }
            final = Self.error(f, t); worst = max(worst, final); frames = i + 1
            #expect(tracker.confidence > 0.5, "confidence \(tracker.confidence) at \(i)")
        }
        print("PERF MaskPointTracker long track: final \(final) worst \(worst) px")
        #expect(frames == 300)
        #expect(final < 2, "end error \(final) px")
    }

    /// Frames 100..<120 show something unrelated: the motion holds, confidence is low, then the track picks the object
    /// up again at the right place.
    @Test func occlusionHoldsAndRecovers() throws {
        var tracker = MaskPointTracker(region: Self.longRegion, mode: .rotation)
        var heldMotion: MaskMotion?
        var final = Double.infinity
        for i in 0..<160 {
            let occluded = (100..<120).contains(i)
            let t = Self.longTruth(i)
            let frame = occluded ? try Self.blank(UInt64(1000 + i)) : try Self.frame(t)
            guard let f = tracker.step(frame) else { Issue.record("lost at \(i)"); return }
            if occluded {
                #expect(tracker.held, "frame \(i) should hold")
                #expect(tracker.confidence < MaskPointTracker.holdConfidence)
                if let h = heldMotion { #expect(f == h, "motion moved during occlusion at \(i)") }
                heldMotion = f
            } else {
                #expect(!tracker.held, "held outside occlusion at \(i)")
                final = Self.error(f, t)
            }
        }
        #expect(final < 2, "error after recovery \(final) px")
    }
}
