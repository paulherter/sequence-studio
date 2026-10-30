import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct SplitPointsTests {
    /// V clip 0...10, linked A clip 2...12 (an L-style offset), plus an aligned pair at 20...30.
    func tl() -> Timeline {
        var t = Timeline(name: "t", frameDuration: Time(1, 30))
        let m = UUID(), l1 = UUID(), l2 = UUID()
        func clip(_ k: TrackKind, _ a: Int64, _ b: Int64, _ l: UUID) -> Clip {
            Clip(name: "c", media: m, kind: k, source: TimeRange(start: .zero, duration: s(b - a)), start: s(a), link: l)
        }
        t.tracks = [Track(kind: .video, clips: [clip(.video, 0, 10, l1), clip(.video, 20, 30, l2)]),
                    Track(kind: .audio, clips: [clip(.audio, 2, 12, l1), clip(.audio, 20, 30, l2)])]
        return t
    }

    @Test func pointsAreOnlyMisalignedEdges() {
        #expect(tl().splitPoints() == [s(0), s(2), s(10), s(12)])
    }

    @Test func nextAndPrevious() {
        let t = tl()
        #expect(t.nextSplitPoint(after: s(2)) == s(10))
        #expect(t.previousSplitPoint(before: s(2)) == s(0))
        #expect(t.nextSplitPoint(after: s(12)) == nil)
        #expect(t.previousSplitPoint(before: s(0)) == nil)
    }

    @Test func markOverhangPicksLeadOrTrail() {
        let t = tl()
        #expect(t.markOverhangRange(at: s(1)) == TimeRange(start: s(0), end: s(2)))
        #expect(t.markOverhangRange(at: s(11)) == TimeRange(start: s(10), end: s(12)))
        #expect(t.markOverhangRange(at: s(5)) == TimeRange(start: s(0), end: s(2)))
        #expect(t.markOverhangRange(at: s(25)) == nil)
    }
}
