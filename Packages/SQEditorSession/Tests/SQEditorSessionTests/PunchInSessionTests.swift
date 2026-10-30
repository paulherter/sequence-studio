import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct PunchInSessionTests {
    private func makeSession() -> (EditorSession, Clip) {
        let c = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(c)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: [v])
        return (EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine()), c)
    }

    private func live(_ s: EditorSession, _ c: Clip) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == c.id }! }

    @Test func toggleIsOneUndoStepEachWay() {
        let (ses, c) = makeSession()
        ses.select(clips: [c.id])
        #expect(ses.punchInEnabled)
        #expect(ses.togglePunchIn())
        #expect(ses.undoName == "Punch In")
        #expect(ses.activeTimeline!.isPunchedIn(live(ses, c)))
        #expect(ses.togglePunchIn())
        #expect(ses.undoName == "Punch Out")
        #expect(live(ses, c).effects.isEmpty)
        ses.undo()
        #expect(ses.activeTimeline!.isPunchedIn(live(ses, c)))
    }
}
