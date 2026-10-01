import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, media: UUID, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: media, kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start))
}

@Suite struct MatchFrameTests {
    @Test func matchesTopmostClipAndMapsSourceTime() throws {
        let m1 = UUID(), m2 = UUID()
        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        try v1.overwrite(clip(0, 10, src: 5, media: m1))
        try v2.overwrite(clip(4, 4, src: 1, media: m2))
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v1, v2])
        let top = try #require(tl.matchFrame(at: s(5)))
        #expect(top.media == m2 && top.sourceTime == s(2))
        let low = try #require(tl.matchFrame(at: s(2)))
        #expect(low.media == m1 && low.sourceTime == s(7))
        #expect(tl.matchFrame(at: s(20)) == nil)
    }

    @Test func selectedClipWins() throws {
        let m1 = UUID(), m2 = UUID()
        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        let a = clip(0, 10, media: m1)
        try v1.overwrite(a)
        try v2.overwrite(clip(0, 10, media: m2))
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v1, v2])
        #expect(tl.matchFrame(at: s(3), selected: [a.id])?.media == m1)
    }

    @Test func reverseMatchFindsClipUsingThatFrame() throws {
        let m = UUID()
        var v = Track(kind: .video)
        try v.overwrite(clip(0, 4, src: 0, media: m))
        try v.overwrite(clip(10, 4, src: 2, media: m))
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        // Source second 3 is used by both clips (0..4 and 2..6): the playhead decides.
        #expect(tl.reverseMatchFrame(media: m, sourceTime: s(3), playhead: s(11)) == s(11))
        #expect(tl.reverseMatchFrame(media: m, sourceTime: s(3), playhead: s(1)) == s(3))
        #expect(tl.reverseMatchFrame(media: m, sourceTime: s(9), playhead: s(1)) == nil)
    }
}
