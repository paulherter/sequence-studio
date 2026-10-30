import Foundation
import Testing
@testable import SQCore

@Suite struct CutToBeatsTests {
    private let fd = Time(1, 30)
    private func f(_ n: Int64) -> Time { Time(n, 30) }
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private func video(_ start: Int64, _ frames: Int64, src: Int64 = 0) -> Clip {
        Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: f(src), duration: f(frames)), start: f(start), mediaDuration: f(6000))
    }
    private func timeline(_ clips: [Clip], beats: [Time]) -> Timeline {
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: clips)])
        tl.replaceBeatMarkers(in: TimeRange(start: .zero, duration: s(100)), with: beats)
        return tl
    }

    @Test func cutsTheSelectedClipAtEveryBeatInsideIt() throws {
        let c = video(0, 300)       // 0..10 s
        var tl = timeline([c], beats: [s(2), s(4), s(6), s(10), s(12)])
        let n = try tl.cutToBeats(clips: [c.id])
        #expect(n == 3)             // 10 s is the clip's own end, 12 s is outside
        #expect(tl.tracks[0].clips.map(\.start) == [.zero, s(2), s(4), s(6)])
        #expect(tl.tracks[0].isConsistent)
        #expect(tl.tracks[0].clips.last?.timeline.end == s(10))
    }

    @Test func leavesUnselectedClipsAlone() throws {
        let a = video(0, 300), b = video(300, 300)
        var tl = timeline([a, b], beats: [s(5), s(15)])
        let n = try tl.cutToBeats(clips: [a.id])
        #expect(n == 1)
        #expect(tl.tracks[0].clips.count == 3)
        #expect(tl.tracks[0].clips.contains { $0.id == b.id && $0.start == s(10) })
    }

    @Test func linkedAudioIsCutWithTheVideo() throws {
        var v = video(0, 300)
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: f(300)), start: .zero, mediaDuration: f(6000))
        let link = UUID(); v.link = link; a.link = link
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])])
        tl.replaceBeatMarkers(in: TimeRange(start: .zero, duration: s(100)), with: [s(5)])
        _ = try tl.cutToBeats(clips: [v.id])
        #expect(tl.tracks[0].clips.count == 2 && tl.tracks[1].clips.count == 2)
    }

    @Test func noBeatsMeansNoCutsAndNoChange() throws {
        let c = video(0, 300)
        var tl = timeline([c], beats: [])
        let before = tl
        let n = try tl.cutToBeats(clips: [c.id])
        #expect(n == 0)
        #expect(tl == before)
    }

    @Test func snapMovesEachTailToTheNearestBeatAndRipples() throws {
        let a = video(0, 100), b = video(100, 100), c = video(200, 100)      // cuts at 0, 3.33, 6.67, 10 s
        var tl = timeline([a, b, c], beats: [s(3), s(7), s(10)])
        let n = try tl.snapToBeats(clips: [a.id, b.id])
        #expect(n == 2)
        let cl = tl.tracks[0].clips
        #expect(cl[0].timeline.end == s(3))
        #expect(cl[1].start == s(3))
        #expect(cl[1].timeline.end == s(7))
        #expect(cl[2].start == s(7))
        #expect(tl.tracks[0].isConsistent)
        // The beat grid keeps its times: a ripple must not drag it off the music.
        #expect(tl.markers.filter { $0.name == Timeline.beatMarkerName }.map(\.time).sorted() == [s(3), s(7), s(10)])
    }

    @Test func snapNeverEmptiesAClip() throws {
        let a = video(0, 60), b = video(60, 60)
        var tl = timeline([a, b], beats: [f(0), f(1)])            // the only beats sit at the head
        _ = try tl.snapToBeats(clips: [a.id])
        #expect(tl.tracks[0].clips[0].duration >= fd)
    }
}
