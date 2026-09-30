import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start))
}

@Suite struct TrackTests {
    @Test func overwriteIntoEmptyTrack() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(2, 3))
        #expect(t.clips.map(\.start) == [s(2)])
    }

    @Test func overwriteTrimsAndSplitsNeighbours() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(0, 10, src: 100))
        try t.overwrite(clip(4, 2))               // lands in the middle
        #expect(t.clips.count == 3)
        #expect(t.clips[0].timeline == TimeRange(start: s(0), duration: s(4)))
        #expect(t.clips[0].source == TimeRange(start: s(100), duration: s(4)))
        #expect(t.clips[1].timeline == TimeRange(start: s(4), duration: s(2)))
        #expect(t.clips[2].timeline == TimeRange(start: s(6), duration: s(4)))
        #expect(t.clips[2].source == TimeRange(start: s(106), duration: s(4)))   // source offset follows
    }

    @Test func overwriteRemovesCoveredClips() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(0, 2)); try t.overwrite(clip(2, 2)); try t.overwrite(clip(4, 2))
        try t.overwrite(clip(1, 4))
        #expect(t.clips.map(\.timeline) == [
            TimeRange(start: s(0), duration: s(1)),
            TimeRange(start: s(1), duration: s(4)),
            TimeRange(start: s(5), duration: s(1)),
        ])
    }

    @Test func insertPushesLaterClipsAndSplitsAtPoint() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(0, 10, src: 50))
        try t.insert(clip(4, 3))
        #expect(t.clips.map(\.timeline) == [
            TimeRange(start: s(0), duration: s(4)),
            TimeRange(start: s(4), duration: s(3)),
            TimeRange(start: s(7), duration: s(6)),
        ])
        #expect(t.clips[2].source.start == s(54))
    }

    @Test func wrongKindIsRejected() {
        var t = Track(kind: .audio)
        #expect(throws: EditError.self) { try t.overwrite(clip(0, 1, kind: .video)) }
    }

    @Test func splitKeepsSourceContinuous() throws {
        var t = Track(kind: .video)
        let c = clip(0, 10, src: 20)
        try t.overwrite(c)
        try t.split(at: s(3))
        #expect(t.clips.count == 2)
        #expect(t.clips[0].source == TimeRange(start: s(20), duration: s(3)))
        #expect(t.clips[1].source == TimeRange(start: s(23), duration: s(7)))
        #expect(t.clips[0].id == c.id)
        #expect(t.clips[1].id != c.id)
    }

    @Test func splitAtEdgeDoesNothing() throws {
        var t = Track(kind: .video)
        try t.overwrite(clip(0, 10))
        try t.split(at: s(0)); try t.split(at: s(10)); try t.split(at: s(20))
        #expect(t.clips.count == 1)
    }

    @Test func deleteLeavesGapRippleDeleteClosesIt() throws {
        var t = Track(kind: .video)
        let a = clip(0, 2), b = clip(2, 3), c = clip(5, 1)
        for x in [a, b, c] { try t.overwrite(x) }
        var gap = t; gap.remove(b.id)
        #expect(gap.clips.map(\.start) == [s(0), s(5)])
        t.rippleDelete(b.id)
        #expect(t.clips.map(\.start) == [s(0), s(2)])
    }

    @Test func clipsStaySortedAndNonOverlapping() throws {
        var t = Track(kind: .video)
        for (st, d) in [(8, 2), (0, 3), (5, 2), (2, 4)] as [(Int64, Int64)] { try t.overwrite(clip(st, d)) }
        for (a, b) in zip(t.clips, t.clips.dropFirst()) { #expect(a.timeline.end <= b.timeline.start) }
    }
}
