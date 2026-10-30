import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct CutKeysSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func makeSession(_ spans: [(Int64, Int64)]) -> EditorSession {
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        for (st, len) in spans {
            let l = UUID(), m = UUID(), src = TimeRange(start: s(5), duration: s(len))
            try! v.overwrite(Clip(name: "c", media: m, kind: .video, source: src, start: s(st), link: l, mediaDuration: s(60)))
            try! a.overwrite(Clip(name: "c", media: m, kind: .audio, source: src, start: s(st), link: l, mediaDuration: s(60)))
        }
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v, a])
        let ses = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        ses.setSelectionFollowsPlayhead(false)
        return ses
    }

    @Test func cutOutTwoPressesIsOneUndoStepAndLandsOnTheJoin() {
        let ses = makeSession([(0, 10)])
        let before = ses.activeTimeline!
        ses.seek(to: s(3)); ses.cutOut()
        #expect(ses.activeTimeline!.inOut?.start == s(3))
        ses.seek(to: s(5)); ses.cutOut()
        let t = ses.activeTimeline!
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(3)])
        #expect(t.tracks[0].clips.map { $0.timeline.end } == [s(3), s(8)])
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(3)])
        #expect(t.inOut == nil)
        #expect(ses.playhead == s(3))
        #expect(ses.undoName == "Cut Out")
        ses.undo()
        #expect(ses.activeTimeline!.tracks == before.tracks)   // the Start mark is a separate step before it
    }

    @Test func clearingTheMarkCancelsAPendingCutOut() {
        let ses = makeSession([(0, 10)])
        ses.seek(to: s(3)); ses.cutOut()
        ses.clearInOut()
        ses.seek(to: s(5)); ses.cutOut()   // starts a new span instead of extracting
        #expect(ses.activeTimeline!.tracks[0].clips.count == 1)
        #expect(ses.activeTimeline!.inOut?.start == s(5))
    }

    @Test func secondCmdKSelectsThePieceBetweenTheTwoEdits() {
        let ses = makeSession([(0, 10)])
        ses.seek(to: s(3)); ses.addEditAtPlayhead()
        ses.seek(to: s(7)); ses.addEditAtPlayhead()
        let t = ses.activeTimeline!
        let picked = t.tracks.flatMap(\.clips).filter { ses.selection.contains($0.id) }
        #expect(picked.count == 2)
        #expect(picked.allSatisfy { $0.start == s(3) && $0.timeline.end == s(7) })
        ses.deleteSelection(ripple: true)
        #expect(ses.activeTimeline!.tracks[0].clips.map { $0.timeline.end } == [s(3), s(6)])
    }

    @Test func firstCmdKLeavesTheSelectionAlone() {
        let ses = makeSession([(0, 10)])
        ses.seek(to: s(3)); ses.addEditAtPlayhead()
        #expect(ses.selection.isEmpty)
    }

    @Test func closeGapAtPlayheadIsOneUndoStep() {
        let ses = makeSession([(0, 4), (6, 4)])
        let before = ses.activeTimeline!
        ses.seek(to: s(5))
        #expect(ses.closeGapAtPlayhead())
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(4)])
        #expect(ses.undoName == "Close Gap")
        ses.undo()
        #expect(ses.activeTimeline! == before)
    }

    @Test func closeGapWithoutGapReportsIt() {
        let ses = makeSession([(0, 4), (6, 4)])
        ses.seek(to: s(2))
        #expect(!ses.closeGapAtPlayhead())
        #expect(ses.lastError == "No gap at the playhead.")
    }

    @Test func jAndLCutMoveOnlyAudioInOneStep() {
        let ses = makeSession([(0, 10), (10, 10)])
        let before = ses.activeTimeline!
        ses.seek(to: s(8))
        #expect(ses.jlCutToPlayhead(.jCut))
        #expect(ses.undoName == "J Cut")
        #expect(ses.activeTimeline!.tracks[1].clips.map(\.start) == [s(0), s(8)])
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(10)])
        ses.undo()
        #expect(ses.activeTimeline! == before)
        ses.seek(to: s(8))
        #expect(!ses.jlCutToPlayhead(.lCut))   // no cut behind the playhead
        #expect(ses.lastError == "No audio cut behind the playhead.")
    }

    @Test func keymapHasNoCollisionsForTheNewCommands() {
        let map = CommandMap.sqDefault
        for c in [EditorCommand.cutOut, .closeGapAtPlayhead, .jCut, .lCut] {
            #expect(map.entries.contains { $0.command == c }, "\(c) has a default key")
        }
        var seen = Set<String>()
        for e in map.entries { #expect(seen.insert("\(e.scope)-\(e.binding)").inserted, "duplicate \(e.binding)") }
    }
}
