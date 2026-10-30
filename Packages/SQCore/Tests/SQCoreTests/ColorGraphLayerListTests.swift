import Foundation
import Testing
@testable import SQCore

// The Color layer list (Pro page): rows top = last Step, a blend per Step (Series, Parallel or a Layer mix), no file change.

@Suite struct ColorGraphLayerListTests {
    private static func graph(_ n: Int) -> (ColorGraph, [UUID]) {
        var g = ColorGraph()
        for _ in 1..<n { g.addStep(after: g.steps.last?.id) }
        return (g, g.steps.map(\.id))
    }

    @Test func listIsTopmostFirst() {
        let (g, ids) = Self.graph(3)
        #expect(g.listSteps.map(\.id) == ids.reversed())
    }

    @Test func blendReadsKindAndLayerMix() {
        var (g, ids) = Self.graph(4)
        g.setKind(ids[2], .parallel)
        g.setKind(ids[3], .layer)
        g.update(ids[3]) { $0.layerMix = .screen }
        #expect(g.blend(of: ids[0]) == .series)
        #expect(g.blend(of: ids[1]) == .series)
        #expect(g.blend(of: ids[2]) == .parallel)
        #expect(g.blend(of: ids[3]) == .layer(.screen))
        #expect(g.blend(of: UUID()) == nil)
    }

    @Test func setBlendSetsKindAndMode() {
        var (g, ids) = Self.graph(3)
        let r1 = g.setBlend(ids[1], .layer(.multiply))
        #expect(r1)
        #expect(g.steps[1].kind == .layer && g.steps[1].layerMix == .multiply)
        let r2 = g.setBlend(ids[1], .series)
        #expect(r2)
        #expect(g.steps[1].kind == .serial && g.steps[1].layerMix == .normal)
        let r3 = g.setBlend(ids[2], .parallel)
        #expect(r3)
        #expect(g.steps[2].kind == .parallel && g.steps[2].layerMix == .normal)
    }

    @Test func baseRowAndCustomWiringRefuseBlend() {
        var (g, ids) = Self.graph(3)
        let r4 = g.setBlend(ids[0], .layer(.add))
        #expect(!r4)
        #expect(g.steps[0].kind == .serial)
        let r5 = g.setBlend(UUID(), .series)
        #expect(!r5)
        g.disconnect(GraphLink(.step(ids[1]), .step(ids[2])))
        #expect(g.links != nil)
        #expect(!g.allowsListEdit)
        let r6 = g.setBlend(ids[1], .layer(.add))
        #expect(!r6)
        #expect(g.links != nil)
    }

    @Test func moveToListRowCountsFromTop() {
        var (g, ids) = Self.graph(3)
        g.moveStep(ids[0], toListRow: 0)      // base to the top of the list = last Step
        #expect(g.steps.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(g.steps[0].kind == .serial)
        g.moveStep(ids[0], toListRow: 2)      // and back to the bottom
        #expect(g.steps.map(\.id) == ids[0...2].map { $0 })
        g.moveStep(ids[2], toListRow: 99)     // clamped
        #expect(g.steps.first?.id == ids[2])
    }

    @Test func layerFieldsStayInOldFileVersions() {
        // Only fields v79 / v80 already gate are used: no new version for the list.
        var (g, ids) = Self.graph(2)
        _ = g.setBlend(ids[1], .layer(.add))
        #expect(g.steps[1].usesV79Fields && g.steps[1].usesV80Fields)
    }
}
