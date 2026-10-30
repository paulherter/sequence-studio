import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct MusicFitSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    /// 20 s music at timeline 0, a 4 s bar grid (bars at 0,4,8,12,16), sequence marked 0..<12.
    private func make(inOut: TimeRange? = nil, blocker: Bool = false) -> (EditorSession, Clip) {
        var m = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(20)), start: .zero)
        m.audioTag = .music
        m.mediaDuration = s(20)
        var t = Track(kind: .audio); try! t.overwrite(m)
        if blocker {
            var o = Clip(name: "o", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: s(22))
            o.mediaDuration = s(5)
            try! t.overwrite(o)
        }
        var tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [t])
        tl.inOut = inOut
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        sess.select(clips: [m.id], captions: [])
        return (sess, m)
    }
    private func grid() -> BeatGrid {
        BeatGrid(beats: (0..<20).map { s(Int64($0)) }, downbeatBeatIndices: [0, 4, 8, 12, 16], beatsPerBar: 4, bpm: 60)
    }

    @Test func versionsFitTheMarkedRange() {
        let (sess, _) = make(inOut: TimeRange(start: .zero, duration: s(12)))
        let v = sess.musicFitVersions(grid: grid())
        #expect(!v.isEmpty && v.count <= 3)
        #expect(v[0].length == s(12) && v[0].lengthError == .zero)
    }

    @Test func applyIsOneUndoStepWithCrossfade() {
        let (sess, m) = make(inOut: TimeRange(start: .zero, duration: s(12)))
        let v = sess.musicFitVersions(grid: grid())[0]
        let depth = sess.undoDepth
        let ok = sess.applyMusicFit(v, to: m.id)
        #expect(ok && sess.undoDepth == depth + 1)
        let track = sess.activeTimeline!.tracks[0]
        let n = v.segments.filter { $0.source.duration > .zero }.count
        #expect(track.clips.count == n)
        #expect(track.clips.first?.id == m.id && track.end == s(12))
        #expect(track.transitions.count == n - 1)
        sess.undo()
        #expect(sess.activeTimeline!.tracks[0].clips.count == 1 && sess.activeTimeline!.tracks[0].end == s(20))
    }

    @Test func longerVersionRefusedWhenItHitsTheNextClip() {
        let (sess, m) = make(inOut: TimeRange(start: .zero, duration: s(26)), blocker: true)
        let vs = sess.musicFitVersions(grid: grid())
        #expect(!vs.isEmpty)
        let depth = sess.undoDepth
        #expect(!sess.applyMusicFit(vs[0], to: m.id) && sess.undoDepth == depth)
    }

    @Test func noClipNoVersions() {
        let (sess, _) = make(inOut: TimeRange(start: .zero, duration: s(12)))
        sess.select(clips: [], captions: [])
        #expect(!sess.canFitMusic && sess.musicFitVersions(grid: grid()).isEmpty)
    }
}
