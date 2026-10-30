import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Reset Color clears the Pro grade too (the Color Graph effect), not only the Color effects.
@MainActor @Suite struct ResetColorGraphTests {
    private static func proClip(_ contrast: Float) -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        var g = ColorGraph(); g.isActive = true
        g.update(g.steps[0].id) { $0.primaries.contrast = contrast }
        c.colorGraph = g
        return c
    }

    @Test func pasteGroupsCarryOrKeepTheGraph() {
        var source = Self.proClip(1.4)
        var w = ColorEffect(id: 1); w.basic.temperature = 30
        source.effects.insert(ClipEffect.colorGrade(w), at: 0)
        var simple = Clip(name: "s", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        var e = ColorEffect(id: 1); e.basic.temperature = 10
        simple.effects.append(ClipEffect.colorGrade(e))
        let color = simple.pastingAttributes(from: source, groups: [.color])
        #expect(color.activeGrade == .pro && color.colorGraph?.steps[0].primaries.contrast == 1.4)
        #expect(color.effects.filter(\.isColorGraph).count == 1)
        #expect(color.colorGraphIndex! > color.effects.lastIndex(where: \.isColor)!)
        let over = Self.proClip(0.6).pastingAttributes(from: source, groups: [.color])
        #expect(over.effects.filter(\.isColorGraph).count == 1 && over.colorGraph?.steps[0].primaries.contrast == 1.4)
        // Effects group: the target's own Pro grade stays, the source's graph is not added as an effect.
        let fx = Self.proClip(0.6).pastingAttributes(from: source, groups: [.effects])
        #expect(fx.effects.filter(\.isColorGraph).count == 1 && fx.activeGrade == .pro)
        #expect(fx.colorGraph?.steps[0].primaries.contrast == 0.6)
        #expect(simple.pastingAttributes(from: source, groups: [.effects]).colorGraph == nil)
        // Simple source onto a Pro target: Simple renders.
        let off = Self.proClip(1.4).pastingAttributes(from: simple, groups: [.color])
        #expect(off.activeGrade == .simple && off.colorGradeEffects.count == 1)
    }

    @Test func resetRemovesTheGraphOfAProClip() throws {
        var clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        var g = ColorGraph(); g.isActive = true
        g.update(g.steps[0].id) { $0.primaries.contrast = 1.4 }
        clip.colorGraph = g
        var t = Track(kind: .video); try t.overwrite(clip)
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [t])]),
                              engine: StubProgramEngine())
        #expect(s.resetColor(of: clip.id))
        let after = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clip.id })
        #expect(after.colorGraph == nil)
        #expect(after.activeGrade == .simple)
    }
}
