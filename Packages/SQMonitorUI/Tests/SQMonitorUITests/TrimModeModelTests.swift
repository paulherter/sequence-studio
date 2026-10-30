import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

@MainActor @Suite struct TrimModeModelTests {
    private func f(_ n: Int64) -> Time { Time(n, 30) }
    private func start(_ s: EditorSession, _ id: Clip.ID) -> Time? {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }?.start
    }

    private func make() -> (EditorSession, TrimModeModel, [Clip]) {
        func c(_ start: Int64) -> Clip {
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
                 mediaDuration: f(300))
        }
        var v = Track(kind: .video, isTargeted: true)
        let a = c(0), b = c(60), d = c(150)
        try! v.overwrite(a); try! v.overwrite(b); try! v.overwrite(d)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])
        let ses = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        return (ses, TrimModeModel(session: ses), [a, b, d])
    }

    @Test func entersOnTheEditNearestThePlayheadAsRoll() {
        let (ses, m, c) = make()
        ses.seek(to: f(58))
        #expect(m.enterNearestPlayhead())
        #expect(m.isActive && m.side == .roll && m.point?.outgoing == c[0].id && m.point?.incoming == c[1].id)
        #expect(m.frames.outgoing == f(59) && m.frames.incoming == f(60))
    }

    @Test func doubleClickPicksTheSideUnderThePointer() {
        let (ses, m, _) = make()
        let p = ses.activeTimeline!.nearestTrimPoint(to: f(60))!
        m.enter(p, pointerBefore: true)
        #expect(m.side == .outgoing)
        m.enter(p, pointerBefore: false)
        #expect(m.side == .incoming)
    }

    @Test func buttonStepsAreOneUndoStepEachAndFollowTheEdit() {
        let (ses, m, c) = make()
        ses.seek(to: f(60))
        m.enterNearestPlayhead()
        #expect(m.step(frames: 5))
        #expect(ses.undoName == "Move Edit")
        #expect(start(ses, c[1].id) == f(65))
        #expect(m.point?.time == f(65) && m.note == "Moved edit +5 frames")
        #expect(m.step(frames: -1))
        #expect(m.point?.time == f(64))
        ses.undo()
        #expect(start(ses, c[1].id) == f(65))
        ses.undo()
        #expect(start(ses, c[1].id) == f(60))
        m.refresh()
        #expect(m.point?.time == f(60))
    }

    @Test func rippleSidesShiftTheRest() {
        let (ses, m, c) = make()
        m.enter(ses.activeTimeline!.nearestTrimPoint(to: f(60))!, side: .outgoing)
        m.step(frames: -5)
        #expect(ses.undoName == "Ripple Trim")
        #expect(start(ses, c[2].id) == f(145))
    }

    @Test func blockedStepRecordsNothingAndSaysWhy() {
        let (ses, m, _) = make()
        m.enter(ses.activeTimeline!.nearestTrimPoint(to: f(60))!, side: .roll)
        m.step(frames: -30)                      // uses the whole 30 frame head handle of the incoming clip
        let name = ses.undoName
        m.step(frames: -1)
        #expect(m.note == "No more footage that way." && ses.undoName == name)
    }

    @Test func cycleAndExit() {
        let (ses, m, _) = make()
        m.enter(ses.activeTimeline!.nearestTrimPoint(to: f(60))!, side: .outgoing)
        m.cycleSide(); #expect(m.side == .incoming)
        m.cycleSide(); #expect(m.side == .roll)
        m.cycleSide(); #expect(m.side == .outgoing)
        m.exit()
        #expect(!m.isActive && !m.step(frames: 1))
    }

    @Test func leavesTrimModeWhenItsClipsAreGone() {
        let (ses, m, c) = make()
        m.enter(ses.activeTimeline!.nearestTrimPoint(to: f(60))!, side: .roll)
        ses.select(clips: [c[0].id, c[1].id])
        ses.deleteSelection(ripple: false)
        m.refresh()
        #expect(!m.isActive)
    }

    @Test func trimModeKeyResolvesInTheTimelineWithoutClashes() {
        let m = CommandMap.premiereDefault
        #expect(m.duplicates.isEmpty)
        #expect(m.command(for: KeyBinding(.char("t"), .shift), focus: .timeline) == .toggleTrimMode)
        #expect(EditorCommand.toggleTrimMode.title == "Trim Mode")
    }
}
