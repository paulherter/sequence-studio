import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

@MainActor @Suite struct FastCutChromeTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func makeSession() -> EditorSession {
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        for st in [Int64(0), 10] {
            let l = UUID(), m = UUID(), src = TimeRange(start: s(5), duration: s(10))
            try! v.overwrite(Clip(name: "c", media: m, kind: .video, source: src, start: s(st), link: l, mediaDuration: s(60)))
            try! a.overwrite(Clip(name: "c", media: m, kind: .audio, source: src, start: s(st), link: l, mediaDuration: s(60)))
        }
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v, a])
        return EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
    }

    private func positions(_ t: Timeline) -> [[Time]] { t.tracks.map { $0.clips.map(\.start) } }

    @Test func modeSwitchIsOneUndoStepAndMovesNoClip() {
        let ses = makeSession()
        let before = positions(ses.activeTimeline!)
        let depth = ses.history.undoDepth
        #expect(ses.setTimelineEditMode(.magnetic))
        #expect(ses.activeTimeline!.editMode == .magnetic)
        #expect(ses.history.undoDepth == depth + 1)
        #expect(positions(ses.activeTimeline!) == before)
        ses.undo()
        #expect(ses.activeTimeline!.editMode == .normal)
        ses.redo()
        #expect(ses.activeTimeline!.editMode == .magnetic)
    }

    @Test func switchingToTheCurrentModeIsNoStep() {
        let ses = makeSession()
        let depth = ses.history.undoDepth
        #expect(!ses.setTimelineEditMode(.normal))
        #expect(ses.history.undoDepth == depth)
    }

    @Test func feelFollowsTheMode() {
        #expect(TimelineFeel.forMagnetic(ses(.magnetic)) == .fastCut)
        #expect(TimelineFeel.forMagnetic(ses(.normal)) == .normal)
    }
    private func ses(_ m: TimelineEditMode) -> Bool { m == .magnetic }

    @Test func fastCutCommandsWithNothingToDoAddNoStep() {
        let ses = makeSession()
        _ = ses.setTimelineEditMode(.magnetic)
        let depth = ses.history.undoDepth
        #expect(ses.appendToMainTrack(media: []).hasPrefix("Open a clip"))
        #expect(ses.history.undoDepth == depth)
    }

    @Test func fastCutCommandsOnlyEnabledInFastCut() {
        let ses = makeSession()
        for c in EditorCommand.fastCutCommands { #expect(!ses.fastCutCommandEnabled(c)) }
        _ = ses.setTimelineEditMode(.magnetic)
        #expect(ses.fastCutCommandEnabled(.insertSpacer))
        #expect(ses.fastCutCommandEnabled(.appendToMainTrack))
        #expect(!ses.fastCutCommandEnabled(.liftOffMainTrack))          // nothing selected
        #expect(!ses.fastCutCommandEnabled(.putOnMainTrack))
        let main = ses.activeTimeline!.tracks[0].clips[0].id, other = ses.activeTimeline!.tracks[1].clips[0].id
        ses.select(clips: [main], captions: [])
        #expect(ses.fastCutCommandEnabled(.liftOffMainTrack) && !ses.fastCutCommandEnabled(.putOnMainTrack))
        ses.select(clips: [other], captions: [])
        #expect(ses.fastCutCommandEnabled(.putOnMainTrack) && !ses.fastCutCommandEnabled(.liftOffMainTrack))
    }

    @Test func newSequencesUseTheStartMode() {
        let ses = makeSession()
        ses.newSequenceEditMode = .magnetic
        let id = ses.addSequence()
        #expect(ses.project.timeline(id)?.editMode == .magnetic)
        ses.newSequenceEditMode = .normal
        let second = ses.addSequence()
        #expect(ses.project.timeline(second)?.editMode == .normal)
    }

    @Test func settingRoundTrips() {
        let d = UserDefaults(suiteName: "fcchrome-\(UUID())")!
        #expect(AppSettings.load(from: d).newSequenceEditMode == .normal)
        var st = AppSettings.load(from: d); st.newSequenceEditMode = .magnetic; st.save(to: d)
        #expect(d.string(forKey: "sq.newSequenceEditMode") == "magnetic")
        #expect(AppSettings.load(from: d).newSequenceEditMode == .magnetic)
    }

    @Test func attachThreadRunsFromTheClipToTheHostRow() throws {
        let above = try #require(ClipDrawing.attachThreadGeometry(clipRect: CGRect(x: 10, y: 0, width: 50, height: 20), x: 30, hostMinY: 24, hostMaxY: 60))
        #expect(above.from == CGPoint(x: 30, y: 20) && above.to == CGPoint(x: 30, y: 24))
        #expect(above.triangle[0].y > 24)                               // points into the host
        let below = try #require(ClipDrawing.attachThreadGeometry(clipRect: CGRect(x: 10, y: 100, width: 50, height: 20), x: 30, hostMinY: 24, hostMaxY: 60))
        #expect(below.from.y == 100 && below.to.y == 60 && below.triangle[0].y < 60)
        #expect(ClipDrawing.attachThreadGeometry(clipRect: CGRect(x: 0, y: 0, width: 5, height: 24), x: 2, hostMinY: 24, hostMaxY: 60) == nil)
    }

    @Test func cmdOptClickSetsTheAttachPointOnlyOnTheClipBody() {
        let host = Clip(name: "h", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero,
                        mediaDuration: s(60))
        var att = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(5),
                       mediaDuration: s(60))
        att.attachment = ClipAttachment(host: host.id, point: .zero)
        var t = Timeline(name: "S", frameDuration: Time(1, 30),
                         tracks: [Track(kind: .video, clips: [host]), Track(kind: .video, clips: [att])])
        t.setEditMode(.magnetic)
        let v = TimelineView()
        v.frame = CGRect(x: 0, y: 0, width: 1600, height: 400)
        v.setTimeline(t)
        let row = v.geometry.rows(for: v.timeline).first { $0.track == t.tracks[1].id }!
        let y = row.y + row.height / 2
        let x0 = v.geometry.x(for: s(5)), x1 = v.geometry.x(for: s(15))
        #expect(v.attachPointClick(at: CGPoint(x: (x0 + x1) / 2, y: y), modifiers: [.command, .option]) == att.id)
        #expect(v.attachPointClick(at: CGPoint(x: x0 + 1, y: y), modifiers: [.command, .option]) == nil)   // head edge
        #expect(v.attachPointClick(at: CGPoint(x: x1 - 1, y: y), modifiers: [.command, .option]) == nil)   // tail edge
    }

    @Test func headerSwitchFollowsTheModeAndReportsRequests() {
        let bar = TimelineHeaderBar()
        bar.frame = CGRect(x: 0, y: 0, width: 900, height: TimelineHeaderBar.height)
        var asked: TimelineEditMode?
        bar.onEditModeRequest = { asked = $0 }
        bar.editMode = .magnetic
        #expect(bar.modeControl.mode == .magnetic)
        bar.modePicked(.magnetic)                                       // already current: no request
        #expect(asked == nil)
        bar.modePicked(.normal)
        #expect(asked == .normal)
        #expect(bar.modeControl.mode == .magnetic)                      // the sequence decides, the capsule follows
        let rows = bar.modeControl.menuItems
        #expect(rows.map(\.title) == ["Normal", "Fast Cut"] && rows.map(\.isChecked) == [false, true])
        #expect(TimelineModeMenu.chipLabel(.magnetic) == "Fast")
        let f = TimelineHeaderBar.frames(width: 900, showsEditMode: true)
        #expect(f.editMode.width == TimelineHeaderBar.modeWidth && f.editMode.maxX < f.snap.minX)
    }

    @Test func keysAreBoundWithoutCollisions() {
        let map = CommandMap.sqDefault
        for c in EditorCommand.fastCutCommands where c != .setAttachPoint {
            #expect(map.entries.contains { $0.command == c }, "\(c) has a default key")
        }
        var seen = Set<String>()
        for e in map.entries { #expect(seen.insert("\(e.scope)-\(e.binding)").inserted, "duplicate \(e.binding)") }
    }
}
