import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// The Steps graph end to end: the Color panel model writes through the panel into the clip, the session undoes it.
@MainActor @Suite struct StepsGraphFlowTests {
    func rig() throws -> (EditorSession, ColorInspectorPanelView, [Clip]) {
        let media = UUID()
        let a = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(2, 1))
        var v = Track(kind: .video)
        try v.overwrite(a)
        try v.overwrite(b)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(4, 1)))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [a.id])
        return (session, ColorInspectorPanelView(session: session), [a, b])
    }

    func graph(_ s: EditorSession, _ c: Clip) -> ColorGraph? {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == c.id }!.colorGraph
    }

    @Test func everyStepKindCanBeAddedAndGetsItsOwnPosition() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let first = try #require(m.graph?.steps.first?.id)
        for kind in StepKind.allCases { m.addStep(after: m.selectedStep, kind: kind) }
        let g = try #require(graph(session, clips[0]))
        #expect(g.steps.count == 4)
        #expect(g.steps.map(\.kind) == [.serial, .serial, .parallel, .layer], "the first is serial; a serial add is serial")
        let cols = g.columns.map { $0.map(\.id) }
        let pos = Dictionary(uniqueKeysWithValues: g.steps.compactMap { s in s.position.map { (s.id, $0) } })
        let canvas = StepsCanvas(columns: cols, positions: pos)
        let rects = canvas.layout().rects
        #expect(g.steps.dropFirst().allSatisfy { $0.position != nil } && g.steps[0].id == first)
        let all = g.steps.compactMap { rects[$0.id] }
        for (i, r) in all.enumerated() { for o in all.dropFirst(i + 1) { #expect(!r.intersects(o), "no box on another") } }
        #expect(m.selectedStep == g.steps.last?.id)
    }

    @Test func aNewStepAvoidsABoxThatSitsWhereItWouldGo() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let first = try #require(m.graph?.steps.first?.id)
        m.addStep(after: first)
        let second = try #require(m.graph?.steps.last?.id)
        // Park the second Step where the next Step would land, then add one more behind the first.
        let spot = try #require(m.graph?.step(second)?.position)
        m.addStep(after: first)
        let g = try #require(graph(session, clips[0]))
        let new = try #require(g.steps.first { $0.id == m.selectedStep })
        let rect = CGRect(origin: CGPoint(x: new.position!.x, y: new.position!.y), size: StepsCanvas.node)
        let other = CGRect(origin: CGPoint(x: spot.x, y: spot.y), size: StepsCanvas.node)
        #expect(!rect.intersects(other))
    }

    @Test func deletingTheLastStepKeepsAnEmptyGraphAndUndoBringsBackWhatWasThere() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let only = try #require(m.graph?.steps.first?.id)
        m.setStep(only, .contrast, 1.5)
        m.removeStep(only)
        let g = try #require(graph(session, clips[0]))
        #expect(g.steps.count == 1 && g.steps[0].isNeutral && g.steps[0].id == only, "the last Step is reset, never removed")
        session.undo()
        panel.sync([.project])
        #expect(graph(session, clips[0])?.steps[0].primaries.contrast == 1.5)
    }

    @Test func undoAndRedoOfAddMoveDeleteRenameAndMix() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let a = try #require(m.graph?.steps.first?.id)
        func snap() -> ColorGraph? { graph(session, clips[0]) }
        func undo() { session.undo(); panel.sync([.project]) }
        func redo() { session.redo(); panel.sync([.project]) }

        m.addStep(after: a)
        let b = try #require(m.selectedStep)
        let afterAdd = snap()
        m.renameStep(b, to: "Sky")
        let afterRename = snap()
        m.setStep(b, .mix, 40)
        let afterMix = snap()
        m.setStepPosition(b, StepPosition(x: 300, y: 80))
        let afterMove = snap()
        m.removeStep(b)
        #expect(snap()?.steps.count == 1)

        undo(); #expect(snap() == afterMove)
        undo(); #expect(snap() == afterMix)
        undo(); #expect(snap() == afterRename)
        undo(); #expect(snap() == afterAdd)
        undo(); #expect(snap()?.steps.count == 1)
        redo(); #expect(snap() == afterAdd)
        redo(); redo(); redo()
        #expect(snap() == afterMove)
        #expect(snap()?.step(b)?.label == "Sky" && snap()?.step(b)?.mix == 40 && snap()?.step(b)?.position == StepPosition(x: 300, y: 80))
        redo(); #expect(snap()?.steps.count == 1)
    }

    @Test func copyingAGradeKeepsKindsPositionsAndMix() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let a = try #require(m.graph?.steps.first?.id)
        m.addStep(after: a, kind: .parallel)
        let p = try #require(m.selectedStep)
        m.setStep(p, .mix, 55)
        m.addStep(after: p, kind: .layer)
        m.setMixerPosition(a, StepPosition(x: 222, y: 11))
        let src = try #require(graph(session, clips[0]))
        #expect(session.pasteColor(effects: [], graph: .some(src), to: [clips[1].id]) == 1)
        let dst = try #require(graph(session, clips[1]))
        #expect(dst.steps.map(\.kind) == src.steps.map(\.kind))
        #expect(dst.steps.map(\.position) == src.steps.map(\.position))
        #expect(dst.steps.map(\.mix) == src.steps.map(\.mix))
        #expect(dst.steps[0].mixerPosition == StepPosition(x: 222, y: 11))
    }

    @Test func simpleProSwitchStartEmptyAndStartFromSimple() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.set(m.effects[0].id, .contrast, 30)
        m.setActiveGrade(.pro)
        #expect(m.shownGrade == .pro && graph(session, clips[0]) == nil, "Pro alone writes nothing")
        m.startFromSimple()
        let g = try #require(graph(session, clips[0]))
        #expect(g.isActive && !g.steps[0].isNeutral && g.steps[0].label == "From Simple")
        m.setActiveGrade(.simple)
        #expect(graph(session, clips[0])?.isActive == false && graph(session, clips[0])?.steps[0].label == "From Simple")
        m.setActiveGrade(.pro)
        #expect(graph(session, clips[0])?.isActive == true)
        // The second clip: Start empty.
        session.select(clips: [clips[1].id])
        panel.sync([.selection])
        let m2 = try #require(panel.colorModels[clips[1].id])
        m2.setActiveGrade(.pro)
        m2.startEmptyGraph()
        let e = try #require(graph(session, clips[1]))
        #expect(e.isActive && e.steps.count == 1 && e.steps[0].isNeutral)
    }

    @Test func aStepTurnedOffPassesThroughAndKeepsItsValues() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let a = try #require(m.graph?.steps.first?.id)
        m.setStep(a, .contrast, 1.3)
        m.setStepEnabled(a, false)
        var g = try #require(graph(session, clips[0]))
        #expect(!g.steps[0].enabled && g.steps[0].primaries.contrast == 1.3)
        #expect(g.isNeutral, "an off Step changes nothing")
        m.setStepEnabled(a, true)
        g = try #require(graph(session, clips[0]))
        #expect(g.steps[0].enabled && !g.isNeutral)
    }

    @Test func mixerDeleteAndWireDropsAreOneUndoStepEach() throws {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let a = try #require(m.graph?.steps.first?.id)
        m.addStep(after: a, kind: .parallel)
        let p = try #require(m.selectedStep)
        m.addStep(after: p, kind: .serial)
        let c = try #require(m.selectedStep)
        // c is fed by the mixer: wiring c back into that mixer would be a loop and is refused.
        #expect(m.connect(.step(c), to: .mixer(a)) == .cycle)
        #expect(graph(session, clips[0])?.steps.map(\.kind) == [.serial, .parallel, .serial])
        // An output onto its own box is refused: nothing changes.
        let before = graph(session, clips[0])
        #expect(m.connect(.mixer(a), to: .mixer(a)) == .sameBox)
        #expect(m.connect(.mixer(a), to: .step(a)) == .cycle)
        #expect(graph(session, clips[0]) == before)
        m.selectedMixer = a
        m.removeMixer(a)
        #expect(m.selectedMixer == nil)
        #expect(graph(session, clips[0])?.steps.map(\.kind) == [.serial, .serial, .serial])
        session.undo()
        panel.sync([.project])
        #expect(graph(session, clips[0])?.steps.map(\.kind) == [.serial, .parallel, .serial])
    }

    // MARK: Wiring, selection and commands

    /// Three serial Steps a -> b -> c in an open graph.
    private func chain() throws -> (EditorSession, ColorInspectorPanelView, [Clip], ColorInspectorModel, UUID, UUID, UUID) {
        let (session, panel, clips) = try rig()
        let m = try #require(panel.colorModels[clips[0].id])
        m.startEmptyGraph()
        let a = try #require(m.graph?.steps.first?.id)
        m.addStep(after: a, kind: .serial)
        let b = try #require(m.selectedStep)
        m.addStep(after: b, kind: .serial)
        let c = try #require(m.selectedStep)
        return (session, panel, clips, m, a, b, c)
    }

    @Test func aRefusedWireChangesNothingAndAKeyWireIsStoredAndUndone() throws {
        let (session, _, clips, m, a, _, c) = try chain()
        let before = graph(session, clips[0])
        #expect(m.connect(.step(c), to: .step(a)) == .cycle)
        #expect(m.connect(.sink, to: .step(a)) == .notAnOutput)
        #expect(graph(session, clips[0]) == before)
        #expect(m.connectKey(from: a, to: .step(c)) == nil)
        #expect(graph(session, clips[0])?.keyLinks == [GraphLink(.step(a), .step(c))])
        #expect(graph(session, clips[0])?.isWiringApplied == true)
        session.undo()
        #expect(graph(session, clips[0])?.keyLinks.isEmpty == true)
    }

    @Test func removingAWireAndDroppingAStepOnAWireAreOneUndoStepEach() throws {
        let (session, panel, clips, m, a, b, c) = try chain()
        m.disconnect(GraphLink(.step(a), .step(b)))
        #expect(graph(session, clips[0])?.hasCustomWiring == true)
        session.undo()
        panel.sync([.project])
        #expect(graph(session, clips[0])?.hasCustomWiring == false)
        #expect(m.insertStep(a, onto: GraphLink(.step(b), .step(c))))
        #expect(graph(session, clips[0])?.steps.map(\.id) == [b, a, c])
        session.undo()
        #expect(graph(session, clips[0])?.steps.map(\.id) == [a, b, c])
    }

    @Test func extractingAStepClosesTheGapAndSitsWhereItWasLetGo() throws {
        let (session, _, clips, m, a, b, c) = try chain()
        m.extractStep(b, at: StepPosition(x: 40, y: 120))
        let g = try #require(graph(session, clips[0]))
        #expect(g.imageLinks.contains(GraphLink(.step(a), .step(c))))
        #expect(!g.imageLinks.contains { $0.from == .step(b) || $0.to == .step(b) })
        #expect(g.step(b)?.position == StepPosition(x: 40, y: 120))
    }

    @Test func multiSelectionDeletesAndTurnsOffTogether() throws {
        let (session, _, clips, m, a, b, c) = try chain()
        m.selectStep(a)
        m.selectStep(c, extend: true)
        #expect(m.selectedSteps == [a, c])
        m.toggleSelectedSteps()
        #expect(graph(session, clips[0])?.steps.map(\.enabled) == [false, true, false])
        m.toggleSelectedSteps()
        #expect(graph(session, clips[0])?.steps.map(\.enabled) == [true, true, true])
        m.removeSelectedSteps()
        #expect(graph(session, clips[0])?.steps.map(\.id) == [b])
        session.undo()
        #expect(graph(session, clips[0])?.steps.map(\.id) == [a, b, c], "deleting several Steps is one undo step")
    }

    @Test func addStepBeforeGoesInFrontAndTheRectangleSelectsTouchedSteps() throws {
        let (session, _, clips, m, a, _, _) = try chain()
        m.addStepBefore(a)
        let g = try #require(graph(session, clips[0]))
        #expect(g.steps.count == 4 && g.steps[1].id == a && g.steps[0].kind == .serial)
        let c = StepsCanvas(columns: g.columns.map { $0.map(\.id) }, positions: [:])
        let l = c.layout()
        let box = c.viewRect(l.rects[g.steps[0].id]!).insetBy(dx: -2, dy: -2)
        #expect(c.steps(in: box) == [g.steps[0].id])
        #expect(c.steps(in: CGRect(x: -1000, y: -1000, width: 5000, height: 5000)).count == 4)
    }
}
