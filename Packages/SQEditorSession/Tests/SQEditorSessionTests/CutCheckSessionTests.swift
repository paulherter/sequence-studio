import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct CutCheckSessionTests {
    @Test func checkCutsMarksFindingsAsOneUndoStep() {
        var vt = Track(kind: .video)
        try! vt.overwrite(Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero))
        try! vt.overwrite(Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(5)))
        let tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [vt])
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        let depth = sess.undoDepth
        let report = sess.runCutCheck()
        #expect(report?.count(.gap) == 1)
        #expect(sess.activeTimeline?.markers.count == 1)
        #expect(sess.undoDepth == depth + 1)
        #expect(report?.summary.contains("Gap: 1") == true)
        sess.undo()
        #expect(sess.activeTimeline?.markers.isEmpty == true)
    }

    @Test func platformPickerReRunsIntoTheSameUndoStepAndChecksLandscape() {
        var vt = Track(kind: .video)
        try! vt.overwrite(Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero))
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [vt])
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        #expect(sess.runCutCheck(platform: .reels)?.platform == .reels)
        let depth = sess.undoDepth
        #expect(sess.runCutCheck(platform: .shorts)?.platform == .shorts)
        #expect(sess.undoDepth == depth)
    }

    @Test func punchInCutsIsOneUndoStep() {
        var vt = Track(kind: .video)
        for i in 0..<3 {
            try! vt.overwrite(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(Int64(i) * 2)))
        }
        let sess = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [vt])]))
        let depth = sess.undoDepth
        #expect(sess.punchInCuts(PunchInCutsOptions(scales: [115])))
        #expect(sess.undoDepth == depth + 1)
        let c1 = sess.activeTimeline!.tracks[0].clips[1]
        #expect(sess.activeTimeline!.isPunchedIn(c1))
        sess.undo()
        #expect(!sess.activeTimeline!.isPunchedIn(sess.activeTimeline!.tracks[0].clips[1]))
    }
}
