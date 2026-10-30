import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct BeatGridSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private func make(speed: ClipSpeed = .normal, sourceStart: Int64 = 0) -> (EditorSession, Clip) {
        var m = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: s(sourceStart), duration: s(10)), start: s(2))
        m.audioTag = .music
        m.speed = speed
        var t = Track(kind: .audio); try! t.overwrite(m)
        let tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [t])
        return (EditorSession(project: Project(name: "P", timelines: [tl])), m)
    }
    private func grid() -> BeatGrid {
        BeatGrid(beats: (0..<20).map { s(Int64($0)) }, downbeatBeatIndices: [0, 4, 8, 12, 16], beatsPerBar: 4, bpm: 60)
    }

    @Test func beatsLandOnTheTimelineThroughSourceOffset() {
        let (_, m) = make(sourceStart: 3)               // plays source 3..<13 at timeline 2..<12
        let t = AudioShortform.beatTimes(of: m, grid: grid())
        #expect(t.first == s(2) && t.last == s(11) && t.count == 10)
    }

    @Test func downbeatsOnlyAndDoubleSpeed() {
        let (_, m) = make(speed: ClipSpeed(num: 2, den: 1))
        let t = AudioShortform.beatTimes(of: m, grid: grid(), downbeatsOnly: true)
        // source 0..<10 at 2x plays in 5 s; downbeats at 0, 4, 8 -> 0, 2, 4 s after the start
        #expect(t == [s(2), s(4), s(6)])
    }

    @Test func markersOnBeatIsOneUndoStepAndRerunReplaces() {
        let (sess, m) = make()
        sess.select(clips: [], captions: [])
        let depth = sess.undoDepth
        #expect(sess.addMarkersOnBeat(grids: [m.id: grid()]) == 10 && sess.undoDepth == depth + 1)
        #expect(sess.activeTimeline!.markers.allSatisfy { $0.name == "Beat" } && sess.hasBeatMarkers)
        #expect(sess.addMarkersOnBeat(grids: [m.id: grid()], downbeatsOnly: true) == 3)
        #expect(sess.activeTimeline!.markers.count == 3)
        sess.undo(); sess.undo()
        #expect(sess.activeTimeline!.markers.isEmpty)
    }

    @Test func noGridMeansNoUndoStep() {
        let (sess, _) = make()
        let depth = sess.undoDepth
        #expect(sess.addMarkersOnBeat(grids: [:]) == 0 && sess.undoDepth == depth)
    }
}
