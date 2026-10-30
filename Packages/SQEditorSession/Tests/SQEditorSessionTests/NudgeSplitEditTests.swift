import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct NudgeSplitEditTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let frame = Time(1, 30)

    private func makeSession() -> EditorSession {
        func c(_ start: Int64, _ kind: TrackKind) -> Clip {
            Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: Time(5, 1), duration: Time(10, 1)), start: Time(start, 1),
                 mediaDuration: Time(60, 1))
        }
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        try! v.overwrite(c(0, .video)); try! v.overwrite(c(10, .video))
        try! a.overwrite(c(0, .audio)); try! a.overwrite(c(10, .audio))
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v, a])
        return EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
    }

    @Test func nudgeMovesOnlyTheAudioEditByOneFrame() {
        let ses = makeSession()
        ses.seek(to: s(10))
        #expect(ses.nudgeSplitEdit(.audio, frames: -1))
        #expect(ses.undoName == "Nudge Audio Edit")
        var t = ses.activeTimeline!
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(10)])
        #expect(t.tracks[1].clips[1].start == s(10) - frame)
        // The same key again keeps working on the same cut (playhead did not move).
        #expect(ses.nudgeSplitEdit(.audio, frames: -10))
        t = ses.activeTimeline!
        #expect(t.tracks[1].clips[1].start == s(10) - frame * 11)
        #expect(ses.nudgeSplitEdit(.audio, frames: 1))
        #expect(ses.activeTimeline!.tracks[1].clips[1].start == s(10) - frame * 10)
        #expect(ses.playhead == s(10))
    }

    @Test func nudgeVideoSideLeavesAudio() {
        let ses = makeSession()
        ses.seek(to: s(10))
        #expect(ses.nudgeSplitEdit(.video, frames: 5))
        let t = ses.activeTimeline!
        #expect(t.tracks[0].clips[1].start == s(10) + frame * 5)
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(10)])
    }

    @Test func undoRestoresAndNoHandleIsRefused() {
        let ses = makeSession()
        let before = ses.activeTimeline!
        ses.seek(to: s(10))
        #expect(ses.nudgeSplitEdit(.audio, frames: 3))
        ses.undo()
        #expect(ses.activeTimeline! == before)
        // 5 s of head handle on the right clip: asking for 10 s clamps to the handle, then nothing is left.
        #expect(ses.nudgeSplitEdit(.audio, frames: -300))
        #expect(ses.activeTimeline!.tracks[1].clips[1].start == s(5))
        #expect(!ses.nudgeSplitEdit(.audio, frames: -1))
    }

    @Test func jCutOffsetMovesTheAudioEditEarlierByTheDefaultQuarterSecond() {
        let ses = makeSession()
        ses.seek(to: s(10))
        #expect(ses.offsetSplitEdit(.jCut))
        let t = ses.activeTimeline!
        #expect(t.tracks[0].clips[1].start == s(10))                       // picture stays
        #expect(t.tracks[1].clips[1].start == s(10) - frame * 8)           // 0.25 s = 7.5 frames, rounded to 8
        #expect(ses.undoName == "Nudge Audio Edit")
        #expect(ses.offsetSplitEdit(.jCut, by: Time(1, 3)))                // 10 frames more
        #expect(ses.activeTimeline!.tracks[1].clips[1].start == s(10) - frame * 18)
        #expect(ses.playhead == s(10))
    }

    @Test func lCutOffsetMovesTheAudioEditLater() {
        let ses = makeSession()
        ses.seek(to: s(10))
        #expect(ses.offsetSplitEdit(.lCut, by: Time(1, 6)))                // 5 frames
        #expect(ses.activeTimeline!.tracks[1].clips[1].start == s(10) + frame * 5)
    }

    @Test func offsetWithoutACutReportsIt() {
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                              start: .zero, mediaDuration: Time(60, 1)))
        let ses = EditorSession(project: Project(name: "P", timelines: [
            Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])]),
            engine: StubProgramEngine())
        #expect(!ses.offsetSplitEdit(.jCut))
        #expect(ses.lastError == "No cut on audio tracks to nudge.")
        #expect(!ses.splitEditToPlayhead(.audio))
        #expect(ses.lastError == "No cut on audio tracks to split.")
    }
}
