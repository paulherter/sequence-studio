import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct ColorMattePreviewTests {
    private func graded() -> (Clip, ColorGraph, UUID, UUID) {
        var c = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                     start: .zero, mediaDuration: Time(60, 1))
        var g = ColorGraph()
        let first = g.steps[0].id
        g.update(first) { $0.primaries.gain = ColorTriple(all: 1.2) }
        let second = g.addStep(after: first)
        g.update(second) {
            $0.primaries.saturation = 2
            $0.qualifier = ColorQualifier()
            $0.window = StepWindow(shape: .rectangle)
            $0.curves.master = [CurvePoint(0, 0), CurvePoint(1, 0.5)]
        }
        let third = g.addStep(after: second)
        g.update(third) { $0.primaries.gain = ColorTriple(all: 0.5) }
        g.outputLUT = .file("/tmp/x.cube")
        g.isActive = true
        c.colorGraph = g
        return (c, g, second, third)
    }

    @Test func matteViewKeepsEarlierStepsAndWhitensTheStep() throws {
        let (_, g, second, _) = graded()
        let v = try #require(g.matteView(of: second))
        #expect(v.steps.count == 2 && v.isActive && v.outputLUT == nil)
        #expect(v.steps[0] == g.steps[0])
        let s = v.steps[1]
        #expect(s.qualifier == g.step(second)?.qualifier && s.window == g.step(second)?.window)
        #expect(s.curves.isNeutral && s.lut == nil)
        let w = s.primaries.apply((0.2, 0.5, 0.9))
        #expect(w.0 == 1 && w.1 == 1 && w.2 == 1)
        #expect(g.matteView(of: UUID()) == nil)
    }

    @Test func theEngineGetsTheMatteViewAndTheProjectKeepsTheGrade() throws {
        let (c, g, second, _) = graded()
        var t = Track(kind: .video)
        try t.overwrite(c)
        let engine = StubProgramEngine()
        let ses = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "M", frameDuration: Time(1, 25),
                                                                                  tracks: [t])]), engine: engine)
        func engineGraph() -> ColorGraph? { engine.timeline?.tracks.first?.clips.first?.colorGraph }
        #expect(engineGraph() == g)
        ses.colorMattePreview = ColorMattePreview(clip: c.id, step: second)
        #expect(engineGraph() == g.matteView(of: second))
        #expect(ses.activeTimeline?.tracks.first?.clips.first?.colorGraph == g)
        #expect(ses.undoDepth == 0)
        ses.colorMattePreview = nil
        #expect(engineGraph() == g)
    }
}
