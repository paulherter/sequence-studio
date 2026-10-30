import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// COLOR-GRADE-LINKS in the session: links follow every edit path in the same undo step; range grades from In/Out.
@MainActor @Suite struct ColorGradeLinkSessionTests {
    func rig() throws -> (EditorSession, ColorInspectorPanelView, [Clip]) {
        let fd = Time(1, 30)
        var v = Track(kind: .video)
        var clips: [Clip] = []
        for (n, name) in ["A", "B", "C"].enumerated() {
            let c = Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                         start: Time(Int64(2 * n), 1))
            try v.overwrite(c)
            clips.append(c)
        }
        let t = Timeline(name: "Main", frameDuration: fd, tracks: [v, Track(kind: .audio)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        session.select(clips: [clips[0].id])
        return (session, ColorInspectorPanelView(session: session), clips)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    func exposure(_ s: EditorSession, _ id: Clip.ID) -> Float { current(s, id).color.effects[0].basic.exposure }

    @Test func aPanelEditOnOneLinkedClipUpdatesTheOthersInOneUndoStep() throws {
        let (session, panel, clips) = try rig()
        session.select(clips: [clips[0].id, clips[1].id])
        #expect(session.linkGrades(source: clips[0].id) != nil)
        session.select(clips: [clips[1].id])
        panel.sync([.selection])
        let model = try #require(panel.colorModels[clips[1].id])
        model.gesture { model.set(1, .exposure, 1.5) }
        #expect(exposure(session, clips[0].id) == 1.5)
        #expect(exposure(session, clips[1].id) == 1.5)
        #expect(exposure(session, clips[2].id) == 0)
        session.undo()
        #expect(exposure(session, clips[0].id) == 0)
        #expect(exposure(session, clips[1].id) == 0)
    }

    @Test func pastingOntoALinkedClipUpdatesItsGroupAndUnlinkStopsIt() throws {
        let (session, _, clips) = try rig()
        session.select(clips: [clips[0].id, clips[1].id])
        _ = session.linkGrades(source: clips[0].id)
        var g = ClipColor.default; g.effects[0].basic.exposure = 2
        #expect(session.pasteColor(g, to: [clips[1].id]) == 1)
        #expect(exposure(session, clips[0].id) == 2)
        #expect(session.unlinkGrades([clips[1].id]))
        g.effects[0].basic.exposure = -1
        #expect(session.pasteColor(g, to: [clips[1].id]) == 1)
        #expect(exposure(session, clips[0].id) == 2)
        #expect(current(session, clips[0].id).gradeLink == nil)
    }

    @Test func linkMembersAreReportedForThePanel() throws {
        let (session, _, clips) = try rig()
        session.select(clips: Set(clips.map(\.id)))
        _ = session.linkGrades(source: clips[2].id)
        #expect(session.gradeLinkMembers(of: clips[0].id).count == 3)
        #expect(session.undoName == "Link Grades")
    }

    @Test func aRangeGradeUsesInOutOverTheClipElseThePlayheadToTheClipEnd() throws {
        let (session, _, clips) = try rig()
        // Clip B runs 2...4 s on the timeline.
        try session.performTimeline("Mark") { $0.setMarkedRange(TimeRange(start: Time(5, 2), end: Time(7, 2))) }
        let fx = try #require(session.addRangeGrade(to: clips[1].id))
        var b = current(session, clips[1].id)
        #expect(b.colorGradeEffects.last?.id == fx)
        #expect(b.colorGradeEffects.last?.colorRange == TimeRange(start: Time(1, 2), end: Time(3, 2)))
        #expect(session.undoName == "Add Range Grade")

        session.clearInOut()
        session.seek(to: Time(3, 1))
        let fx2 = try #require(session.addRangeGrade(to: clips[1].id))
        b = current(session, clips[1].id)
        #expect(b.colorGradeEffects.first { $0.id == fx2 }?.colorRange == TimeRange(start: Time(1, 1), end: Time(2, 1)))

        #expect(session.setColorRange(of: fx2, in: clips[1].id, wholeClip: true))
        #expect(current(session, clips[1].id).colorGradeEffects.first { $0.id == fx2 }?.colorRange == nil)
    }

    @Test func copyOfAProClipPastesItsColorGraphAndPro() throws {
        let (session, panel, clips) = try rig()
        panel.sync([.project, .selection])
        let model = try #require(panel.colorModels[clips[0].id])
        model.startEmptyGraph()
        let step = try #require(model.selectedStep)
        model.setStep(step, .contrast, 1.5)
        #expect(current(session, clips[0].id).activeGrade == .pro)
        #expect(panel.copyGrade())
        session.select(clips: [clips[1].id])
        #expect(panel.pasteGrade())
        let b = current(session, clips[1].id)
        #expect(b.activeGrade == .pro && b.colorGraph?.steps.first?.primaries.contrast == 1.5)
        #expect(session.undoName == "Paste Color")
        // A Simple copy onto it turns Pro off again (the graph values stay).
        session.select(clips: [clips[2].id])
        panel.sync([.project, .selection])
        #expect(panel.copyGrade())
        session.select(clips: [clips[1].id])
        #expect(panel.pasteGrade())
        let back = current(session, clips[1].id)
        #expect(back.activeGrade == .simple && back.colorGraph?.steps.first?.primaries.contrast == 1.5)
    }

    @Test func panelCopyPasteGoesToEverySelectedClipAndTitlesShowRangeAndLink() throws {
        let (session, panel, clips) = try rig()
        panel.sync([.project, .selection])
        let model = try #require(panel.colorModels[clips[0].id])
        model.gesture { model.set(1, .exposure, 0.75) }
        #expect(panel.copyGrade())
        session.select(clips: [clips[1].id, clips[2].id])
        #expect(panel.pasteGrade())
        #expect(exposure(session, clips[1].id) == 0.75 && exposure(session, clips[2].id) == 0.75)
        #expect(session.undoName == "Paste Color")

        session.select(clips: [clips[0].id, clips[1].id])
        panel.gradeAction(.linkSelected, clip: clips[0].id)
        session.select(clips: [clips[0].id])
        panel.sync([.project, .selection])
        let shown = try #require(panel.colorModels[clips[0].id])
        #expect(shown.linkedClipCount == 2)
        #expect(shown.effectTitle(1, number: 1).contains("Linked (2)"))
        panel.gradeAction(.addRange, clip: clips[0].id)
        panel.sync([.project])
        #expect(shown.effectRangeLabels[2] != nil)
    }

    @Test func clipListFollowsTimelineOrder() throws {
        let (session, _, clips) = try rig()
        let items = ColorSourceListItem.items(session.activeTimeline)
        #expect(items.flatMap(\.clips) == clips.map(\.id))
    }
}
