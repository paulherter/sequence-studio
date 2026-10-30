import Testing
import SQCore
@testable import SQAnalysis

struct MaskMetricsTests {
    static func rect(_ w: Int, _ h: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> [Bool] {
        (0..<(w * h)).map { let x = $0 % w, y = $0 / w; return x >= x0 && x < x1 && y >= y0 && y < y1 }
    }

    @Test func jaccardOfKnownOverlaps() {
        let a = Self.rect(10, 10, x0: 0, y0: 0, x1: 4, y1: 10)   // 40 px
        let b = Self.rect(10, 10, x0: 2, y0: 0, x1: 6, y1: 10)   // 40 px, 20 shared
        #expect(MaskMetrics.jaccard(a, a) == 1)
        #expect(abs(MaskMetrics.jaccard(a, b) - 20.0 / 60.0) < 1e-9)
        #expect(MaskMetrics.jaccard(a, Self.rect(10, 10, x0: 6, y0: 0, x1: 10, y1: 10)) == 0)
        #expect(MaskMetrics.jaccard([Bool](repeating: false, count: 4), [Bool](repeating: false, count: 4)) == 1)
    }

    @Test func boundaryOfASquareIsItsRing() {
        let m = Self.rect(10, 10, x0: 2, y0: 2, x1: 8, y1: 8)
        #expect(MaskMetrics.boundary(m, width: 10, height: 10).filter { $0 }.count == 20)
    }

    @Test func boundaryFIsOneForEqualAndDropsWithShift() {
        let a = Self.rect(100, 100, x0: 20, y0: 20, x1: 60, y1: 60)
        let near = Self.rect(100, 100, x0: 21, y0: 20, x1: 61, y1: 60)
        let far = Self.rect(100, 100, x0: 40, y0: 40, x1: 90, y1: 90)
        #expect(MaskMetrics.boundaryF(a, a, width: 100, height: 100) == 1)
        #expect(MaskMetrics.boundaryF(near, a, width: 100, height: 100) > 0.9)
        #expect(MaskMetrics.boundaryF(far, a, width: 100, height: 100) < 0.5)
        #expect(MaskMetrics.boundaryF([Bool](repeating: false, count: 10_000), a, width: 100, height: 100) == 0)
    }

    @Test func aPixelToleranceIsStricterThanTheDiagonalFraction() {
        let a = Self.rect(100, 100, x0: 20, y0: 20, x1: 60, y1: 60)
        let shifted = Self.rect(100, 100, x0: 23, y0: 20, x1: 63, y1: 60)
        let loose = MaskMetrics.boundaryF(shifted, a, width: 100, height: 100, tolerance: 0.03)
        let strict = MaskMetrics.boundaryF(shifted, a, width: 100, height: 100, pixels: 1)
        #expect(strict < loose)
    }

    @Test func bandErrorIsZeroForTheTruthAndGrowsWithABlurredEdge() {
        let w = 60, h = 60
        let truth = Self.rect(w, h, x0: 15, y0: 15, x1: 45, y1: 45).map { $0 ? Float(1) : 0 }
        #expect(MaskMetrics.bandError(alpha: truth, truth: truth, width: w, height: h) == 0)
        let flat = [Float](repeating: 0.5, count: w * h)
        #expect(MaskMetrics.bandError(alpha: flat, truth: truth, width: w, height: h) > 0.4)
    }

    @Test func downscaleKeepsShape() {
        var v = [Float](repeating: 0, count: 960 * 480)
        for y in 100..<300 { for x in 200..<600 { v[y * 960 + x] = 1 } }
        let d = MaskMetrics.downscaled(v, width: 960, height: 480, longSide: 480)
        #expect(d.width == 480 && d.height == 240)
        let area = Double(d.mask.filter { $0 }.count) / Double(d.width * d.height)
        #expect(abs(area - (200.0 * 400.0) / (960.0 * 480.0)) < 0.01)
    }

    @Test func scoreAveragesAndTable() {
        var s = MaskBenchScore()
        s.add(j: 1, f: 0.5); s.add(j: 0.5, f: 0.5)
        #expect(abs(s.j - 0.75) < 1e-9 && abs(s.f - 0.5) < 1e-9 && abs(s.jf - 0.625) < 1e-9)
        #expect(MaskBenchScore.table([("clip", "baseline", s)]).contains("| clip | baseline | 0.750 | 0.500 | 0.625 |"))
    }
}

struct MaskBenchScenarioTests {
    @Test func windowsAndRecovery() {
        let frames = [0, 5, 10, 15, 20, 25].map { MaskFrameScore(frame: $0, j: $0 < 10 || $0 >= 25 ? 0.9 : 0.1, f: 0.5) }
        let before = MaskBenchScenarios.window(frames, 0..<10)
        #expect(before?.count == 2 && abs((before?.j ?? 0) - 0.9) < 1e-9 && abs((before?.jf ?? 0) - 0.7) < 1e-9)
        #expect(MaskBenchScenarios.window(frames, 30..<40) == nil)
        #expect(MaskBenchScenarios.framesToRecover(frames, end: 20) == 5)
        #expect(MaskBenchScenarios.framesToRecover(frames, end: 30) == nil)
    }

    @Test func interiorClickIsDeepInsideTheSubject() {
        // A 20x20 square plus a thin 1 px tail: the click must be in the square's middle, not on the tail.
        var m = MaskMetricsTests.rect(60, 40, x0: 10, y0: 10, x1: 30, y1: 30)
        for x in 30..<55 { m[20 * 60 + x] = true }
        let c = MaskBenchScenarios.interiorClick(m, width: 60, height: 40)
        #expect(c != nil && abs(c!.x - 19.5) <= 2.5 && abs(c!.y - 19.5) <= 2.5)
        #expect(m[Int(c!.y) * 60 + Int(c!.x)])
        #expect(MaskBenchScenarios.interiorClick([Bool](repeating: false, count: 12), width: 4, height: 3) == nil)
    }

    @Test func grownBoxStaysInTheFrame() {
        let m = MaskMetricsTests.rect(100, 100, x0: 40, y0: 40, x1: 60, y1: 60)
        let b = MaskBenchScenarios.grownBox(m, width: 100, height: 100, margin: 0.25)
        #expect(b?.x0 == 35 && b?.x1 == 65 && b?.y0 == 35 && b?.y1 == 65)
        let edge = MaskBenchScenarios.grownBox(MaskMetricsTests.rect(100, 100, x0: 0, y0: 0, x1: 20, y1: 20), width: 100, height: 100, margin: 0.5)
        #expect(edge?.x0 == 0 && edge?.x1 == 30)
    }

    @Test func exitPushesTheSubjectOutThroughTheNearerSide() {
        // A subject left of the middle leaves left (its right edge past 0), one right of it leaves right.
        #expect(abs(MaskBenchScenarios.exitDistance(x0: 0.1, x1: 0.4) - -0.42) < 1e-9)
        #expect(abs(MaskBenchScenarios.exitDistance(x0: 0.6, x1: 0.8) - 0.42) < 1e-9)
    }

    @Test func exitShiftRampsOutHoldsAndComesBack() {
        let shifts = (0..<20).map { MaskBenchScenarios.exitShift(frame: $0, start: 5, length: 15, distance: -0.6) }
        #expect(shifts[0..<5].allSatisfy { $0 == 0 })                  // before
        #expect(abs(shifts[5] - -0.12) < 1e-9 && abs(shifts[9] - -0.6) < 1e-9)   // out over 5 frames
        #expect(shifts[10..<15].allSatisfy { abs($0 - -0.6) < 1e-9 })   // gone
        #expect(abs(shifts[15] - -0.5) < 1e-9 && abs(shifts[19] - -0.1) < 1e-9)  // back over 5 frames
        #expect(MaskBenchScenarios.exitShift(frame: 20, start: 5, length: 15, distance: -0.6) == 0)
        // Monotonic out, then back.
        #expect(zip(shifts[5..<10], shifts[6..<11]).allSatisfy { $0 >= $1 })
        #expect(zip(shifts[15..<19], shifts[16..<20]).allSatisfy { $0 <= $1 })
        #expect(MaskBenchScenarios.exitReturn(start: 5, length: 15) == 15)
    }

    @Test func movedShiftGoesToTheRoomierSideAndKeepsTheSubjectInside() {
        #expect(abs(MaskBenchScenarios.moveDistance(x0: 0.1, x1: 0.4) - 0.3) < 1e-9)
        #expect(abs(MaskBenchScenarios.moveDistance(x0: 0.5, x1: 0.9) - -0.3) < 1e-9)
        // A wide subject: only the room there is.
        #expect(abs(MaskBenchScenarios.moveDistance(x0: 0.05, x1: 0.85) - 0.15) < 1e-9)
    }

    @Test func shiftedMovesPixelsAndFillsTheGap() {
        let m: [Float] = [1, 2, 3, 4,
                          5, 6, 7, 8]
        #expect(MaskBenchScenarios.shifted(m, width: 4, height: 2, by: 1, fill: 0) == [0, 1, 2, 3, 0, 5, 6, 7])
        #expect(MaskBenchScenarios.shifted(m, width: 4, height: 2, by: -2, fill: 9) == [3, 4, 9, 9, 7, 8, 9, 9])
        #expect(MaskBenchScenarios.shifted(m, width: 4, height: 2, by: 5, fill: 0) == [Float](repeating: 0, count: 8))
        #expect(MaskBenchScenarios.shifted(m, width: 4, height: 2, by: 0, fill: 0) == m)
    }

    @Test func framesToReacquireCountsFromTheReturn() {
        // Lost 10...17: found again at 18, three frames after the return at 15.
        #expect(MaskBenchScenarios.framesToReacquire(lost: Array(10...17), from: 15, last: 30) == 3)
        #expect(MaskBenchScenarios.framesToReacquire(lost: Array(10...14), from: 15, last: 30) == 0)
        #expect(MaskBenchScenarios.framesToReacquire(lost: Array(10...30), from: 15, last: 30) == nil)
    }
}

struct MaskLagTests {
    /// A subject moving 4 px per frame to the right, labeled every 5 frames; the mask sits `behind` frames back.
    static func samples(behind: Double, every: Int = 5, count: Int = 12, speed: Double = 4, width: Double = 40) -> [MaskLagSample] {
        (0..<count).map { k in
            let f = k * every
            let truth = Vec2(100 + speed * Double(f), 50)
            return MaskLagSample(frame: f, predicted: truth - Vec2(speed * behind, 0), truth: truth, truthWidth: width)
        }
    }

    @Test func centroidAndBoxWidthOfARect() {
        let m = MaskMetricsTests.rect(20, 10, x0: 4, y0: 2, x1: 10, y1: 6)
        let c = MaskLag.centroid(m, width: 20)
        #expect(c == Vec2(7, 4))
        #expect(MaskLag.boxWidth(m, width: 20) == 6)
        #expect(MaskLag.centroid([false, false], width: 2) == nil && MaskLag.boxWidth([false], width: 1) == 0)
    }

    @Test func aTrailingMaskGivesAPositiveLagInFrames() throws {
        let r = try #require(MaskLag.report(Self.samples(behind: 2), fps: 30))
        #expect(abs(r.lagFrames - 2) < 1e-9)
        #expect(abs(r.alongError - -8) < 1e-9 && abs(r.meanError - 8) < 1e-9)
        #expect(abs(r.meanSpeed - 4) < 1e-9 && abs(r.widthsPerSecond - 3) < 1e-9)   // 4 px * 30 fps / 40 px
        #expect(r.count == 12)
    }

    @Test func aLeadingMaskIsNegativeAndAnExactOneIsZero() throws {
        #expect(abs(try #require(MaskLag.report(Self.samples(behind: -1), fps: 30)).lagFrames - -1) < 1e-9)
        let exact = try #require(MaskLag.report(Self.samples(behind: 0), fps: 30))
        #expect(exact.lagFrames == 0 && exact.meanError == 0)
    }

    @Test func lostFramesAreLeftOutButStillGiveTheVelocity() throws {
        var s = Self.samples(behind: 1)
        s[3].predicted = nil; s[4].predicted = nil
        let r = try #require(MaskLag.report(s, fps: 30))
        #expect(r.count == 10 && abs(r.lagFrames - 1) < 1e-9)
        #expect(MaskLag.report(s.map { var x = $0; x.predicted = nil; return x }, fps: 30) == nil)
    }

    @Test func aStillSubjectHasNoLagAndASpeedRangeFilters() throws {
        let still = Self.samples(behind: 0, speed: 0).map { var x = $0; x.predicted = x.truth + Vec2(3, 0); return x }
        let r = try #require(MaskLag.report(still, fps: 30))
        #expect(r.lagFrames == 0 && abs(r.meanError - 3) < 1e-9)
        #expect(MaskLag.report(Self.samples(behind: 1), fps: 30, widthsPerSecond: 0.5...1.5) == nil)
        #expect(MaskLag.report(Self.samples(behind: 1), fps: 30, widthsPerSecond: 1.5...3.5) != nil)
    }

    @Test func shapeLagFindsWhichPictureTheMaskFits() throws {
        #expect(MaskLag.shapeLag(previous: 0.5, own: 0.9, next: 0.5) == 0)
        #expect(try #require(MaskLag.shapeLag(previous: 0.8, own: 0.8, next: 0.4)) > 0.4)      // between own and before
        #expect(try #require(MaskLag.shapeLag(previous: 0.4, own: 0.8, next: 0.8)) < -0.4)
        #expect(MaskLag.shapeLag(previous: 0.9, own: 0.6, next: 0.3) == 1)                       // fits the one before
        #expect(MaskLag.shapeLag(previous: 0.7, own: 0.7, next: 0.7) == nil)
        var s = Self.samples(behind: 0)
        for k in s.indices { s[k].shapeLag = k < 6 ? 0.5 : 0.1 }
        let r = try #require(MaskLag.report(s, fps: 30))
        #expect(abs(try #require(r.shapeLag) - 0.3) < 1e-9 && r.shapeCount == 12)
    }

    @Test func lagThatGrowsWithSpeedCorrelatesNegatively() throws {
        // Speed rises frame to frame; the mask trails a fixed 2 frames, so the along error falls with speed.
        var s: [MaskLagSample] = []
        var x = 0.0
        for k in 0..<10 {
            let v = Double(k + 1)
            x += v * 5
            s.append(MaskLagSample(frame: k * 5, predicted: Vec2(x - 2 * v, 0), truth: Vec2(x, 0), truthWidth: 50))
        }
        let r = try #require(MaskLag.report(s, fps: 25))
        #expect(r.correlation < -0.9 && r.lagFrames > 1)
    }
}
