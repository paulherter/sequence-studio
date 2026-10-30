import Foundation
import Testing
@testable import SQCore

// W9.8 SubjectMask: person matte as a mask source, temporal smoothing (pure maths), CPU coverage reference.

/// Deterministic pseudo random numbers (LCG), so the synthetic sequences are the same on every run.
private struct LCG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func symmetric() -> Double { next() * 2 - 1 }
}

/// An anti-aliased disc whose radius wobbles along the contour like a segmentation edge: low angular frequencies with a new
/// random phase/amplitude every frame, peak `jitter` px.
private func noisyDisc(_ w: Int, _ h: Int, center: Vec2, radius: Double, jitter: Double, rng: inout LCG) -> SubjectMatte {
    var harmonics: [(k: Double, a: Double, p: Double)] = []
    for k in [2.0, 3.0, 5.0, 7.0] { harmonics.append((k, rng.symmetric(), rng.next() * 2 * .pi)) }
    let total = harmonics.map { abs($0.a) }.reduce(0, +)
    let scale = total > 0 ? jitter / total : 0
    var v = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let dx = Double(x) + 0.5 - center.x, dy = Double(y) + 0.5 - center.y
            let th = atan2(dy, dx)
            var r = radius
            for hm in harmonics { r += hm.a * scale * sin(hm.k * th + hm.p) }
            let d = (dx * dx + dy * dy).squareRoot() - r
            v[y * w + x] = Float(min(max(0.5 - d, 0), 1))
        }
    }
    return SubjectMatte(width: w, height: h, values: v)
}

@Suite struct SubjectMaskTests {
    // MARK: Model

    @Test func pathMaskEncodesWithoutSourceKey() throws {
        let m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!json.contains("source"))
        #expect(try JSONDecoder().decode(ClipMask.self, from: Data(json.utf8)).source == .path)
    }

    @Test func subjectMaskRoundTrips() throws {
        let m = ClipMask.makeSubject(name: "Subject")
        #expect(m.source == .subject)
        let back = try JSONDecoder().decode(ClipMask.self, from: try JSONEncoder().encode(m))
        #expect(back == m)
        #expect(back.source == .subject)
        // Older builds read it as a full-frame rectangle: nothing is cut.
        #expect(back.path.value == MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1)))
    }

    @Test func unknownOrPathSourceDecodesAsAPlainPathMask() throws {
        let m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        for raw in ["depth", "path"] {
            var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(m)) as! [String: Any]
            obj["source"] = raw
            let back = try JSONDecoder().decode(ClipMask.self, from: try JSONSerialization.data(withJSONObject: obj))
            #expect(back.source == .path)
            // Normalized: equal to the plain mask and re-encodes without the key.
            #expect(back == m, "\(raw)")
            #expect(!String(decoding: try JSONEncoder().encode(back), as: UTF8.self).contains("source"))
        }
    }

    @Test func subjectMaskReachesTheRendererWithoutPolygon() {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var m = ClipMask.makeSubject(name: "Subject")
        m.path.value = MaskPath(vertices: [])
        c.masks = [m]
        let shapes = c.maskShapes(atLocal: .zero)
        #expect(shapes.count == 1)
        #expect(shapes.first?.source == .subject)
    }

    // MARK: Coverage reference

    @Test func subjectCoverageSamplesTheMatte() {
        let matte = SubjectMatte(width: 2, height: 1, values: [0, 1])
        let s = MaskShape(polygon: [], source: .subject)
        let frame = Vec2(20, 10)
        // Texel centers at x = 5 and 15 (frame px): left 0, right 1, linear in between, clamped at the edges.
        #expect(abs(MaskCoverage.coverage(at: Vec2(5, 5), masks: [s], frame: frame, pixel: 1, matte: matte)) < 1e-9)
        #expect(abs(MaskCoverage.coverage(at: Vec2(10, 5), masks: [s], frame: frame, pixel: 1, matte: matte) - 0.5) < 1e-9)
        #expect(abs(MaskCoverage.coverage(at: Vec2(19, 5), masks: [s], frame: frame, pixel: 1, matte: matte) - 1) < 1e-9)
        var inv = s; inv.inverted = true; inv.opacity = 0.5
        #expect(abs(MaskCoverage.coverage(at: Vec2(5, 5), masks: [inv], frame: frame, pixel: 1, matte: matte) - 0.5) < 1e-9)
    }

    @Test func subjectWithoutMatteShowsNoPerson() {
        // Late or failed segmentation must not flash the whole clip: no matte = matte 0 everywhere.
        let s = MaskShape(polygon: [], source: .subject)
        #expect(MaskCoverage.coverage(at: Vec2(3, 3), masks: [s], frame: Vec2(10, 10), pixel: 1, matte: nil) == 0)
        var inv = s; inv.inverted = true; inv.opacity = 0.5
        #expect(MaskCoverage.coverage(at: Vec2(3, 3), masks: [inv], frame: Vec2(10, 10), pixel: 1, matte: nil) == 0.5)
        // Subtracting a missing person leaves the path mask as it is.
        let rect = MaskShape(polygon: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)])
        var sub = s; sub.mode = .subtract
        #expect(MaskCoverage.coverage(at: Vec2(3, 3), masks: [rect, sub], frame: Vec2(10, 10), pixel: 1, matte: nil) == 1)
    }

    @Test func matteOutsideTheFrameIsEmpty() {
        // A blur-padded layer samples beyond the clip's frame: no person there, even where the person touches the edge.
        let matte = SubjectMatte(width: 2, height: 2, values: [1, 1, 1, 1])
        let s = MaskShape(polygon: [], source: .subject)
        let frame = Vec2(20, 10)
        #expect(MaskCoverage.coverage(at: Vec2(19.5, 5), masks: [s], frame: frame, pixel: 1, matte: matte) == 1)
        for p in [Vec2(-0.5, 5), Vec2(20.5, 5), Vec2(10, -0.5), Vec2(10, 10.5)] {
            #expect(MaskCoverage.coverage(at: p, masks: [s], frame: frame, pixel: 1, matte: matte) == 0, "\(p)")
        }
        var inv = s; inv.inverted = true
        #expect(MaskCoverage.coverage(at: Vec2(-3, 5), masks: [inv], frame: frame, pixel: 1, matte: matte) == 1)
    }

    // MARK: Matte helpers

    @Test func resampledKeepsTheShape() {
        let a = SubjectMatte(width: 4, height: 2, values: [0, 0, 1, 1, 0, 0, 1, 1])
        let b = a.resampled(width: 8, height: 4)
        #expect(b.width == 8 && b.height == 4)
        #expect(b[0, 0] == 0 && b[7, 3] == 1)
        #expect(abs(b.area - a.area * 4) < 0.5)
    }

    @Test func translatedMovesTheCentroid() throws {
        var rng = LCG(s: 1)
        let a = noisyDisc(64, 64, center: Vec2(32, 32), radius: 10, jitter: 0, rng: &rng)
        let b = a.translated(by: Vec2(3.5, -2))
        let ca = try #require(a.centroid), cb = try #require(b.centroid)
        #expect(abs(cb.x - ca.x - 3.5) < 0.05 && abs(cb.y - ca.y + 2) < 0.05)
    }

    // MARK: Temporal smoothing

    @Test func staticSubjectEdgesStopFlickering() {
        var rng = LCG(s: 42)
        var smoother = SubjectMatteSmoother()
        var rawPrev: SubjectMatte?, outPrev: SubjectMatte?
        var rawWorst = 0.0, outWorst = 0.0, outMean = 0.0, n = 0
        for f in 0..<60 {
            let raw = noisyDisc(160, 160, center: Vec2(80, 80), radius: 45, jitter: 3, rng: &rng)
            let out = smoother.push(raw, frameIndex: f)
            if let rp = rawPrev, let op = outPrev, f >= 8 {
                rawWorst = max(rawWorst, SubjectMatte.edgeDelta(rp, raw).max)
                let d = SubjectMatte.edgeDelta(op, out)
                outWorst = max(outWorst, d.max); outMean += d.mean; n += 1
            }
            rawPrev = raw; outPrev = out
        }
        #expect(rawWorst > 3, "the test sequence must flicker: \(rawWorst)")
        #expect(outWorst < 2, "smoothed edge delta \(outWorst) px")
        #expect(outMean / Double(n) < 0.8, "mean \(outMean / Double(n)) px")
    }

    @Test func movingSubjectIsFollowedWithoutLag() throws {
        var rng = LCG(s: 7)
        var smoother = SubjectMatteSmoother()
        let speed = Vec2(3, 1)
        var outPrev: SubjectMatte?
        var jitterWorst = 0.0, lagWorst = 0.0
        for f in 0..<40 {
            let c = Vec2(50, 70) + speed * Double(f)
            let raw = noisyDisc(220, 160, center: c, radius: 30, jitter: 3, rng: &rng)
            let out = smoother.push(raw, frameIndex: f)
            if f >= 8 {
                let truth = noisyDisc(220, 160, center: c, radius: 30, jitter: 0, rng: &rng)
                lagWorst = max(lagWorst, SubjectMatte.edgeDelta(truth, out).max)
                if let op = outPrev {
                    // Frame-to-frame edge change once the true motion is taken out.
                    jitterWorst = max(jitterWorst, SubjectMatte.edgeDelta(op.translated(by: speed), out).max)
                }
            }
            outPrev = out
        }
        #expect(jitterWorst < 2, "jitter \(jitterWorst) px")
        #expect(lagWorst < 3, "distance to the true edge \(lagWorst) px")
    }

    @Test func sceneCutAndFrameJumpReset() {
        var rng = LCG(s: 3)
        var smoother = SubjectMatteSmoother()
        for f in 0..<10 { _ = smoother.push(noisyDisc(120, 80, center: Vec2(30, 40), radius: 15, jitter: 2, rng: &rng), frameIndex: f) }
        // A different shot: the person stands elsewhere and is much larger. No ghost of the old matte.
        let cut = noisyDisc(120, 80, center: Vec2(90, 40), radius: 35, jitter: 0, rng: &rng)
        #expect(smoother.push(cut, frameIndex: 10) == cut)
        // A scrub jump (not the next frame) starts over too.
        let jump = noisyDisc(120, 80, center: Vec2(88, 40), radius: 33, jitter: 1, rng: &rng)
        #expect(smoother.push(jump, frameIndex: 50) == jump)
    }

    @Test func sameFrameAgainReturnsTheCachedResult() {
        var rng = LCG(s: 11)
        var smoother = SubjectMatteSmoother()
        var last = SubjectMatte(width: 1, height: 1, values: [0])
        for f in 0..<5 { last = smoother.push(noisyDisc(80, 80, center: Vec2(40, 40), radius: 20, jitter: 2, rng: &rng), frameIndex: f) }
        // A paused redraw of frame 4 (even with a fresh segmentation) shows the same matte, and does not advance the history.
        #expect(smoother.cached(frameIndex: 4) == last)
        #expect(smoother.push(noisyDisc(80, 80, center: Vec2(40, 40), radius: 20, jitter: 2, rng: &rng), frameIndex: 4) == last)
        #expect(smoother.cached(frameIndex: 99) == nil)
    }

    @Test func reversePlaybackIsSmoothedToo() {
        var rng = LCG(s: 5)
        var smoother = SubjectMatteSmoother()
        var outPrev: SubjectMatte?
        var worst = 0.0
        for (n, f) in (0..<40).reversed().enumerated() {
            let out = smoother.push(noisyDisc(120, 120, center: Vec2(60, 60), radius: 30, jitter: 3, rng: &rng), frameIndex: f)
            if let op = outPrev, n >= 8 { worst = max(worst, SubjectMatte.edgeDelta(op, out).max) }
            outPrev = out
        }
        #expect(worst < 2, "J-K reverse edge delta \(worst) px")
    }

    @Test func outOfOrderFramesFindTheirNeighbour() {
        var rng = LCG(s: 13)
        var smoother = SubjectMatteSmoother()
        func disc() -> SubjectMatte { noisyDisc(80, 80, center: Vec2(40, 40), radius: 20, jitter: 3, rng: &rng) }
        for f in 0..<6 { _ = smoother.push(disc(), frameIndex: f) }
        // Parallel prefetch: 7 arrives before 6. 7 has no neighbor yet (starts fresh), 6 and 8 have one each.
        let r7 = disc(); #expect(smoother.push(r7, frameIndex: 7) == r7)
        let r6 = disc(); #expect(smoother.push(r6, frameIndex: 6) != r6)
        let r8 = disc(); #expect(smoother.push(r8, frameIndex: 8) != r8)
    }

    @Test func differentSizeResets() {
        var smoother = SubjectMatteSmoother()
        _ = smoother.push(SubjectMatte(width: 4, height: 4, values: .init(repeating: 1, count: 16)), frameIndex: 0)
        let b = SubjectMatte(width: 2, height: 2, values: [1, 0, 0, 1])
        #expect(smoother.push(b, frameIndex: 1) == b)
    }

    @Test func edgeDeltaMeasuresAShift() {
        var rng = LCG(s: 9)
        let a = noisyDisc(100, 100, center: Vec2(50, 50), radius: 20, jitter: 0, rng: &rng)
        let b = noisyDisc(100, 100, center: Vec2(51.5, 50), radius: 20, jitter: 0, rng: &rng)
        let d = SubjectMatte.edgeDelta(a, b)
        #expect(d.max > 1.3 && d.max < 1.7, "\(d.max)")
        #expect(SubjectMatte.edgeDelta(a, a).max < 1e-9)
    }
}
