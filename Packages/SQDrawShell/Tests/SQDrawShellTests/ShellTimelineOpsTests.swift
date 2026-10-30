import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

/// The Mac `executeTimelineOp` rows the shell runs on the session alone (menu rows and keys on Windows).
@MainActor
struct ShellTimelineOpsTests {
    func session() -> (EditorSession, Clip) {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                          tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        return (EditorSession(project: Project(name: "P", timelines: [tl])), clip)
    }

    func clipCount(_ s: EditorSession) -> Int { s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0 }

    @Test func clipboardRowsCopyAndPasteAndSayWhatIsMissing() {
        let (s, clip) = session()
        #expect(ShellCommands.run(.copy, session: s) == "Select clips to copy.")
        #expect(ShellCommands.run(.paste, session: s) == "Nothing to paste. Copy clips first.")
        s.select(clips: [clip.id])
        #expect(ShellCommands.run(.copy, session: s) == "")
        s.seek(to: Time(2, 1))
        #expect(ShellCommands.run(.paste, session: s) == "")
        #expect(clipCount(s) == 2)
        #expect(ShellCommands.run(.duplicate, session: s) == "")
        #expect(clipCount(s) == 3)
    }

    @Test func nudgeSlideAndSlipSayTheSteps() {
        let (s, clip) = session()
        #expect(ShellCommands.run(.slideLeft, session: s) == "Select clips to slide.")
        s.select(clips: [clip.id])
        s.seek(to: .zero)
        #expect(ShellCommands.run(.nudgeRight, session: s) == StepStatus.line("Nudge", frames: StepStatus.small))
        #expect(s.activeTimeline?.tracks[0].clips[0].timeline.start == Time(1, 25))
        #expect(ShellCommands.run(.nudgeLeft5, session: s) == StepStatus.line("Nudge", frames: -StepStatus.large))
    }

    @Test func tracksMarkersAndFastCutRows() {
        let (s, _) = session()
        #expect(ShellCommands.run(.addVideoTrack, session: s) == "")
        #expect(s.activeTimeline?.tracks.filter { $0.kind == .video }.count == 2)
        #expect(ShellCommands.run(.clearAllMarkers, session: s) == "There are no markers to clear.")
        #expect(ShellCommands.run(.addMarker, session: s) == "")
        #expect(s.activeTimeline?.markers.count == 1)
        #expect(ShellCommands.run(.moveClipLeft, session: s) == "Switch the sequence to Fast Cut first (Shift+G).")
        #expect(ShellCommands.run(.trimToRange, session: s) == "Mark In and Out first.")
    }

    @Test func viewRowsStayWithTheHost() {
        let (s, _) = session()
        #expect(ShellCommands.run(.trimForward, session: s) == nil)
        #expect(ShellCommands.run(.toggleSnapping, session: s) == nil)
    }
}
