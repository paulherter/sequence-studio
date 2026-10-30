import Foundation
import Testing
@testable import SQCore

@Suite struct SplitSourceEditTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
    }

    @Test func audioStartsEarlierAndBothEndTogetherLinked() throws {
        let m = UUID()
        var v = Track(kind: .video), a = Track(kind: .audio)
        try v.overwrite(clip(0, 20, kind: .video)); try a.overwrite(clip(0, 20, kind: .audio))
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v, a])
        let vid = tl.tracks[0].id, aid = tl.tracks[1].id
        try tl.splitSourceEdit(media: m, videoIn: s(12), audioIn: s(10), out: s(16), mediaDuration: s(60),
                               videoTracks: [vid], audioTracks: [aid], at: s(5), mode: .overwrite)
        let nv = tl.tracks[0].clips.first { $0.media == m }!, na = tl.tracks[1].clips.first { $0.media == m }!
        #expect(nv.start == s(5) && nv.timeline.end == s(9))
        #expect(na.start == s(3) && na.timeline.end == s(9))
        #expect(nv.source.start == s(12) && na.source.start == s(10))
        #expect(nv.link != nil && nv.link == na.link)
    }

    @Test func soundBeforeSequenceStartIsTrimmed() throws {
        let m = UUID()
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let vid = tl.tracks[0].id, aid = tl.tracks[1].id
        try tl.splitSourceEdit(media: m, videoIn: s(10), audioIn: s(5), out: s(14), videoTracks: [vid], audioTracks: [aid],
                               at: s(2), mode: .insert)
        let na = tl.tracks[1].clips[0]
        #expect(na.start == .zero && na.source.start == s(8) && na.timeline.end == s(6))
    }
}
