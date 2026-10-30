import Foundation
import Testing
@testable import SQCore

// Magic mask corrections on the synthetic swing shot (`SwingShot`): a remove point cuts a lamp the segmenter merged into
// the person and keeps it out while the shot is tracked; an add point grows a hat the segmenter missed; points act from
// the frame they were made on.

@Suite struct MagicCorrectionTests {
    static let face = Vec2(96.0 / 192, 30.0 / 108)
    static let lampPoint = Vec2(137.0 / 192, 60.0 / 108)
    static let hatPoint = Vec2(96.0 / 192, 12.0 / 108)

    static func pt(_ p: Vec2, _ f: Int, subtract: Bool = false) -> MagicPoint {
        MagicPoint(position: p, subtract: subtract, sourceTime: Time(Int64(f), 24))
    }

    /// Tracks frames 0..<48 and returns per-frame (soft IoU, leak) against `truth`.
    static func track(_ shot: SwingShot, points: [MagicPoint], truth: (Int) -> SubjectMatte = SwingShot.truth,
                      frames: Range<Int> = 0..<48, start: SubjectMatte? = nil) -> [(soft: Double, leak: Double)] {
        var shot = shot
        var follower = MagicFollower(start: start)
        var out: [(Double, Double)] = []
        for f in 0..<frames.upperBound {
            let fr = shot.frame(f)               // every frame drawn, so the wobble matches across runs
            guard f >= frames.lowerBound else { continue }
            guard let m = follower.step(fr, points: points, pts: Double(f) / 24) else { Issue.record("lost at \(f)"); break }
            let s = matteScores(m, truth(f))
            out.append((s.soft, s.leak))
        }
        return out
    }

    static func mean(_ x: [(soft: Double, leak: Double)], _ k: KeyPath<(soft: Double, leak: Double), Double>) -> Double {
        x.isEmpty ? 0 : x.map { $0[keyPath: k] }.reduce(0, +) / Double(x.count)
    }

    @Test func removePointCutsAMergedLampForTheWholeTrack() {
        var shot = SwingShot(); shot.mergeLamp = true
        let without = Self.track(shot, points: [Self.pt(Self.face, 0)])
        let with = Self.track(shot, points: [Self.pt(Self.face, 0), Self.pt(Self.lampPoint, 0, subtract: true)])
        let line = "[MagicCorrection] merged lamp: leak \(Self.mean(without, \.leak)) -> \(Self.mean(with, \.leak)), soft IoU \(Self.mean(without, \.soft)) -> \(Self.mean(with, \.soft))"
        try? line.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("sq-magic-correction.txt"), atomically: true, encoding: .utf8)
        #expect(with.count == 48)
        #expect(Self.mean(without, \.leak) > 0.4)
        #expect(Self.mean(with, \.leak) < 0.05, "leak \(Self.mean(with, \.leak))")
        #expect(Self.mean(with, \.soft) > 0.9, "soft IoU \(Self.mean(with, \.soft))")
        #expect(with.map(\.leak).max()! < 0.1)
    }

    @Test func addPointGrowsAMissedHatAndKeepsItOnTheMovingHead() {
        var shot = SwingShot(); shot.hat = true
        let without = Self.track(shot, points: [Self.pt(Self.face, 0)], truth: SwingShot.truthWithHat)
        let with = Self.track(shot, points: [Self.pt(Self.face, 0), Self.pt(Self.hatPoint, 0)], truth: SwingShot.truthWithHat)
        let line = "[MagicCorrection] hat: soft IoU \(Self.mean(without, \.soft)) -> \(Self.mean(with, \.soft))"
        try? line.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("sq-magic-correction-hat.txt"), atomically: true, encoding: .utf8)
        #expect(with.count == 48)
        #expect(Self.mean(with, \.soft) > Self.mean(without, \.soft) + 0.03)
        #expect(Self.mean(with, \.soft) > 0.9, "soft IoU \(Self.mean(with, \.soft))")
        #expect(Self.mean(with, \.leak) < 0.05)
    }

    @Test func aCorrectionActsFromTheFrameItWasMadeOn() {
        var shot = SwingShot(); shot.mergeLamp = true
        let r = Self.track(shot, points: [Self.pt(Self.face, 0), Self.pt(Self.lampPoint, 10, subtract: true)])
        #expect(r.count == 48)
        #expect(r[0..<10].allSatisfy { $0.leak > 0.4 })
        #expect(Self.mean(Array(r[12...]), \.leak) < 0.05)
    }

    /// A point is stored at the playhead's rational source time, which can lie inside the decoded frame (other frame rate
    /// than the sequence's); older projects stored the decoded frame's own time. Both belong to that frame only.
    @Test func aPointInsideAFramesSpanBelongsToThatFrame() {
        let fd = 1.0 / 24
        #expect(MagicFollower.belongs(point: 10 * fd, pts: 10 * fd))
        #expect(MagicFollower.belongs(point: 10 * fd + 0.0000005, pts: 10 * fd))             // stored rounded to microseconds
        #expect(!MagicFollower.belongs(point: 10 * fd + 0.03, pts: 10 * fd))                 // span unknown: the frame's own time only
        #expect(MagicFollower.belongs(point: 10 * fd + 0.03, pts: 10 * fd, span: fd))
        #expect(!MagicFollower.belongs(point: 11 * fd, pts: 10 * fd, span: fd))              // the next frame's
        #expect(MagicFollower.belongs(point: 11 * fd, pts: 11 * fd, span: fd))
        #expect(!MagicFollower.belongs(point: 10 * fd - 0.01, pts: 10 * fd, span: fd))
    }

    @Test func aCorrectionStoredInsideAFrameActsFromThatFrame() {
        var shot = SwingShot(); shot.mergeLamp = true
        // Made with the playhead of a 30 fps sequence at 13/30 s: inside the 24 fps frame 10 (10/24 ... 11/24 s).
        let points = [Self.pt(Self.face, 0), MagicPoint(position: Self.lampPoint, subtract: true, sourceTime: Time(13, 30))]
        var follower = MagicFollower()
        var leaks: [Double] = []
        for f in 0..<48 {
            guard let m = follower.step(shot.frame(f), points: points, pts: Double(f) / 24, span: 1.0 / 24) else { Issue.record("lost at \(f)"); return }
            leaks.append(matteScores(m, SwingShot.truth(f)).leak)
        }
        #expect(leaks[0..<10].allSatisfy { $0 > 0.4 })
        #expect(leaks[12...].reduce(0, +) / Double(leaks.count - 12) < 0.05)
    }

    @Test func trackContinuingACorrectedFrameKeepsTheCorrection() throws {
        var shot = SwingShot(); shot.mergeLamp = true
        let points = [Self.pt(Self.face, 0), Self.pt(Self.lampPoint, 0, subtract: true)]
        var follower = MagicFollower()
        for f in 0...20 { _ = follower.step(shot.frame(f), points: points, pts: Double(f) / 24) }
        let stored = try #require(follower.previous)
        // A new Track from frame 20 (stored matte there) onwards, as after a stop or from another session.
        var g = SwingShot(); g.mergeLamp = true
        var cont = MagicFollower(start: stored)
        var leak = 0.0, n = 0.0
        for f in 0..<48 {
            let fr = g.frame(f)
            guard f >= 20 else { continue }
            guard let m = cont.step(fr, points: points, pts: Double(f) / 24) else { Issue.record("lost at \(f)"); return }
            leak += matteScores(m, SwingShot.truth(f)).leak; n += 1
        }
        #expect(leak / n < 0.05, "leak \(leak / n)")
    }

    @Test func removeOnTheSubjectCutsWhileRemoveOnAnotherObjectDropsIt() {
        var l = [UInt8](repeating: 0, count: 32)
        for y in 1...2 { for x in 0..<4 { l[y * 8 + x] = 1 }; for x in 4..<8 { l[y * 8 + x] = 2 } }
        let labels = InstanceLabels(width: 8, height: 4, labels: l)
        let t = Time.zero
        let a = MagicPoint(position: Vec2(0.1, 0.5), subtract: false, sourceTime: t)
        let b = MagicPoint(position: Vec2(0.9, 0.5), subtract: false, sourceTime: t)
        let cutSubject = MagicPick.selection([a, MagicPoint(position: Vec2(0.3, 0.5), subtract: true, sourceTime: t)], in: labels)
        #expect(cutSubject.selected == [1] && cutSubject.cuts.count == 1)
        let dropOther = MagicPick.selection([a, b, MagicPoint(position: Vec2(0.8, 0.5), subtract: true, sourceTime: t)], in: labels)
        #expect(dropOther.selected == [1] && dropOther.cuts.isEmpty)
    }

    @Test func noGuideMeansInstanceLevelOnly() {
        let m = SubjectMatte(width: 4, height: 4, values: [Float](repeating: 1, count: 16))
        var st = MagicCorrection.State()
        let out = MagicCorrection.apply(base: m, guide: nil, add: [], remove: [Vec2(0.5, 0.5)], state: &st)
        #expect(out == m)
    }
}

