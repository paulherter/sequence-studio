import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Color Pro entry point in Controls: a Color Graph section only while Pro is active, with its Step count and Adjust.
@MainActor @Suite struct EffectControlsColorGraphRowTests {
    func clipWith(_ graph: ColorGraph?) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        if let graph { c.colorGraph = graph }
        return c
    }

    func graphSections(_ m: EffectControlsModel) -> [EffectSection] {
        m.visibleSections.filter { $0.effectKind == ClipEffect.colorGraphKind }
    }

    @Test func noGraphOrInactiveGraphShowsNoSection() {
        let m = EffectControlsModel()
        m.setClip(clipWith(nil))
        #expect(graphSections(m).isEmpty)
        var g = ColorGraph()
        g.isActive = false
        m.setClip(clipWith(g))
        #expect(graphSections(m).isEmpty, "an inactive graph stays out of Controls (no empty section)")
    }

    @Test func activeGraphShowsOneSummaryRowWithItsStepCount() throws {
        var g = ColorGraph()
        g.isActive = true
        g.addStep(after: nil)
        let m = EffectControlsModel()
        m.setClip(clipWith(g))
        let sections = graphSections(m)
        #expect(sections.count == 1)
        let id = try #require(sections[0].effectID)
        #expect(m.colorGraphStepCount(id) == 2)
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [])
        #expect(rows.filter { if case .colorGraph(id) = $0.kind { true } else { false } }.count == 1)
        #expect(!rows.contains { if case .placeholder(let s) = $0.kind { s.effectKind == ClipEffect.colorGraphKind } else { false } })
    }
}
