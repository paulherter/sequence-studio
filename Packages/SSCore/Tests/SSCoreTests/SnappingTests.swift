import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}
private func pts(_ xs: [Int64], _ k: SnapKind = .clipEdge) -> [SnapPoint] { xs.map { SnapPoint(time: s($0), kind: k) } }
private let fd = Time(1, 30)

@Suite struct SnappingTests {
    @Test func nearestWithinThreshold() {
        let r = snap(Time(49, 10), to: pts([0, 5, 10]), threshold: s(1), frameDuration: nil)
        #expect(r.time == s(5))
        #expect(r.hit?.time == s(5))
    }

    @Test func tiePicksEarlier() {
        let r = snap(s(7), to: pts([5, 9]), threshold: s(3), frameDuration: nil)
        #expect(r.time == s(5))
    }

    @Test func outsideThresholdKeepsTime() {
        let r = snap(s(7), to: pts([0, 20]), threshold: s(2), frameDuration: nil)
        #expect(r.time == s(7))
        #expect(r.hit == nil)
    }

    @Test func frameFallback() {
        let t = Time(1, 30) + Time(1, 100)
        let r = snap(t, to: pts([100]), threshold: s(1), frameDuration: fd)
        #expect(r.time == Time(1, 30))
        #expect(r.hit == nil)
    }

    @Test func pointBeatsFrameFallback() {
        let r = snap(Time(101, 100), to: pts([1]), threshold: Time(1, 2), frameDuration: fd)
        #expect(r.hit?.time == s(1))
    }

    @Test func emptyPoints() {
        let r = snap(s(3), to: [], threshold: s(1), frameDuration: nil)
        #expect(r.time == s(3) && r.hit == nil)
        let f = snap(Time(1, 30) + Time(1, 100), to: [], threshold: s(1), frameDuration: fd)
        #expect(f.time == Time(1, 30))
    }

    @Test func exclusionAndCollection() throws {
        let a = clip(2, 3), b = clip(10, 2)
        var t1 = Track(kind: .video); try t1.overwrite(a); try t1.overwrite(b)
        var t2 = Track(kind: .video); try t2.overwrite(clip(3, 4))
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [t1, t2])
        let all = tl.snapPoints(playhead: s(8), markers: [s(9)])
        #expect(all.map(\.time) == [0, 2, 3, 5, 7, 8, 9, 10, 12].map { s($0) })
        #expect(all.first { $0.time == s(8) }?.kind == .playhead)
        #expect(all.first { $0.time == s(9) }?.kind == .marker)
        let ex = tl.snapPoints(excluding: [a.id])
        #expect(ex.map(\.time) == [0, 3, 7, 10, 12].map { s($0) })
    }

    @Test func dedupePrefersNonFrame() throws {
        var t1 = Track(kind: .video); try t1.overwrite(clip(0, 5))
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [t1])
        let p = tl.snapPoints(playhead: s(5), markers: [s(0)])
        #expect(p.map(\.time) == [s(0), s(5)])
        #expect(p.allSatisfy { $0.kind != .frame })
        let mixed = SnapPoint.normalized([SnapPoint(time: s(1), kind: .frame), SnapPoint(time: s(1), kind: .marker)])
        #expect(mixed.count == 1 && mixed[0].kind == .marker)
    }

    @Test func moveSnapsStart() {
        let r = snapMove(start: Time(49, 10), duration: s(2), to: pts([5]), threshold: s(1), frameDuration: nil)
        #expect(r.delta == Time(1, 10))
        #expect(r.hit?.time == s(5))
    }

    @Test func moveSnapsEnd() {
        // clip 1.0..3.0 moving; end 3.0 is 0.25 from point 3.25, start is far from everything
        let r = snapMove(start: s(1), duration: s(2), to: pts([3]) + [SnapPoint(time: Time(13, 4), kind: .marker)],
                         threshold: s(1), frameDuration: nil)
        #expect(r.delta == Time(0, 1))
        let r2 = snapMove(start: Time(1, 1), duration: Time(9, 4), to: pts([4]), threshold: s(1), frameDuration: nil)
        #expect(r2.delta == Time(3, 4))   // end 3.25 -> 4
        #expect(r2.hit?.time == s(4))
    }

    @Test func moveCloserHitWins() {
        // start 10 -> point 9.5 (0.5), end 12 -> point 12.2 (0.2): end wins
        let r = snapMove(start: s(10), duration: s(2), to: [SnapPoint(time: Time(19, 2), kind: .clipEdge),
                                                          SnapPoint(time: Time(61, 5), kind: .clipEdge)],
                         threshold: s(1), frameDuration: nil)
        #expect(r.delta == Time(1, 5))
    }

    @Test func moveFrameFallbackAndNoHit() {
        let r = snapMove(start: Time(1, 30) + Time(1, 100), duration: s(2), to: [], threshold: s(1), frameDuration: fd)
        #expect(r.delta == Time(-1, 100))
        #expect(r.hit == nil)
        let n = snapMove(start: Time(1, 100), duration: s(2), to: [], threshold: s(1), frameDuration: nil)
        #expect(n.delta == .zero)
    }
}
