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

    @Test func reverseMatchPicksNearestClipAcrossTimescales() throws {
        let m = UUID()
        var v = Track(kind: .video)
        // Candidate A maps source 0 to 3 s, candidate B to 2.5 s (timescale 2). Playhead 0: B is nearer.
        try v.overwrite(clip(3, 1, src: 0, media: m))
        var b = clip(0, 1, src: 0, media: m)
        b.start = Time(5, 2)
        var v2 = Track(kind: .video)
        try v2.overwrite(b)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v, v2])
        #expect(tl.reverseMatchFrame(media: m, sourceTime: .zero, playhead: .zero) == Time(5, 2))
    }

    @Test func clearWithEmptyHoleLeavesClipsAlone() throws {
        var v = Track(kind: .video)
        let c = clip(0, 10, media: UUID())
        try v.overwrite(c)
        v.clear(TimeRange(start: s(4), duration: .zero))
        #expect(v.clips.count == 1 && v.clips[0].id == c.id && v.clips[0].timeline == c.timeline)
    }
}
