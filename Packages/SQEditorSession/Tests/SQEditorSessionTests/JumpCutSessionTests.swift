import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct JumpCutSessionTests {
    private func makeSession() -> EditorSession {
        let link = UUID(), media = UUID(), src = TimeRange(start: Time(5, 1), duration: Time(10, 1))
        let v = Clip(name: "take", media: media, kind: .video, source: src, start: .zero, link: link, mediaDuration: Time(60, 1))
        let a = Clip(name: "take", media: media, kind: .audio, source: src, start: .zero, link: link, mediaDuration: Time(60, 1))
        var v1 = Track(kind: .video, isTargeted: true), a1 = Track(kind: .audio, isTargeted: true)
        try! v1.overwrite(v); try! a1.overwrite(a)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: [v1, Track(kind: .video), a1, Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
    }

    @Test func jumpCutIsOneUndoStepAndSelectsTheMovedHalves() {
        let ses = makeSession()
        let before = ses.activeTimeline!
        ses.seek(to: Time(4, 1))
        #expect(ses.jumpCutEnabled)
        #expect(ses.jumpCutAlternate(overlapFrames: 9))
        #expect(ses.undoName == "Jump Cut")
        let t = ses.activeTimeline!
        let v2 = t.tracks.filter { $0.kind == .video }[1]
        #expect(v2.clips.count == 1)
        #expect(v2.clips[0].start == Time(4, 1) - Time(9, 30))
        #expect(ses.selection.count == 2)
        #expect(ses.selection.contains(v2.clips[0].id))
        ses.undo()
        #expect(ses.activeTimeline! == before)
    }

    @Test func doublePressIsANoOpWithAMessage() {
        let ses = makeSession()
        ses.seek(to: Time(4, 1))
        #expect(ses.jumpCutAlternate(overlapFrames: 9))
        let after = ses.activeTimeline!
        #expect(ses.jumpCutRefusal == "Already jump cut at the playhead. Move the playhead first.")
        #expect(!ses.jumpCutEnabled)
        #expect(!ses.jumpCutAlternate(overlapFrames: 9))
        #expect(ses.activeTimeline! == after)
        #expect(ses.undoName == "Jump Cut")
    }

    @Test func afterDeselectTheTakeOnV2IsCutBackDown() {
        let ses = makeSession()
        ses.seek(to: Time(4, 1))
        #expect(ses.jumpCutAlternate(overlapFrames: 9))
        ses.select(clips: [])
        ses.seek(to: Time(7, 1))
        #expect(ses.jumpCutRefusal == nil)
        #expect(ses.jumpCutAlternate(overlapFrames: 9))
        #expect(ses.activeTimeline!.tracks.filter { $0.kind == .video }[0].clips.count == 2)
    }

    @Test func defaultOverlapIsPointThreeSeconds() {
        let ses = makeSession()
        UserDefaults.standard.removeObject(forKey: "sq.jumpCut.overlapFrames")
        #expect(ses.jumpCutOverlapFrames == 9)
    }

    @Test func nothingUnderPlayheadIsRefused() {
        let ses = makeSession()
        ses.seek(to: Time(20, 1))
        #expect(!ses.jumpCutEnabled)
        #expect(!ses.jumpCutAlternate())
    }
}
