import Testing
import Foundation
import AppKit
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct EffectsGridModelTests {
    @Test func modePersistsUnderOwnKey() {
        let d = UserDefaults(suiteName: "sq.test.effectsgrid.\(UUID().uuidString)")!
        #expect(EffectsViewMode.load(from: d) == .list)
        EffectsViewMode.grid.save(to: d)
        #expect(d.string(forKey: "EffectsPanel.viewMode") == "grid")
        #expect(EffectsViewMode.load(from: d) == .grid)
        d.set("junk", forKey: "EffectsPanel.viewMode")
        #expect(EffectsViewMode.load(from: d) == .list)
    }

    /// Board: no List / Grid toggle in the Effects panel body; the header menu switches the mode and remembers it.
    @Test func headerMenuModeSwitchPersists() {
        let d = UserDefaults(suiteName: "sq.test.effectsgrid.\(UUID().uuidString)")!
        let panel = EffectsPanelView(defaults: d)
        #expect(panel.viewMode == .list)
        panel.setViewMode(.grid)
        #expect(panel.viewMode == .grid)
        #expect(EffectsViewMode.load(from: d) == .grid)
        #expect(!panel.subviews.contains { $0 is NSSegmentedControl })
    }

    @Test func transitionLoopHoldsThenMixesThenHolds() {
        let loop = EffectPreviewPlan.transitionLoop
        #expect(loop.count == EffectPreviewPlan.loopFrames)
        #expect(Double(loop.count) / EffectPreviewPlan.fps == 1.0)
        #expect(loop.first == 0 && loop.last == 1)
        #expect(loop.allSatisfy { (0...1).contains($0) })
        #expect(zip(loop, loop.dropFirst()).allSatisfy { $0 <= $1 })     // never goes backwards
        #expect(loop.contains { $0 > 0 && $0 < 1 })
    }

    @Test func transitionWeightsComeFromTheRenderMix() {
        let n = EffectPreviewPlan.mixFrames
        #expect(EffectPreviewPlan.transitionLoop.contains(TransitionMix.videoWeight(frameIndex: n / 2, frames: n)))
    }

    @Test func blendMatchesMixMaths() {
        let a: [UInt8] = [200, 100, 0, 255], b: [UInt8] = [0, 100, 200, 255]
        #expect(EffectPreviewPlan.blend(a, b, kind: .crossDissolve, weight: 0) == a)
        #expect(EffectPreviewPlan.blend(a, b, kind: .crossDissolve, weight: 1) == b)
        #expect(EffectPreviewPlan.blend(a, b, kind: .crossDissolve, weight: 0.5) == [100, 100, 100, 255])
        #expect(EffectPreviewPlan.blend(a, b, kind: .dipToBlack, weight: 0.5) == [0, 0, 0, 255])
        #expect(EffectPreviewPlan.blend(a, b, kind: .dipToWhite, weight: 0.5) == [255, 255, 255, 255])
    }

    @Test func sampleImagesAreDistinctAndSized() {
        let (a, b) = EffectPreviewPlan.sampleImages(width: 32, height: 18)
        #expect(a.count == 32 * 18 * 4 && b.count == a.count)
        #expect(a != b)
        #expect(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 255 && b[$0] == 255 })
    }

    @Test func gridLayoutFlowsTilesUnderHeaders() {
        let rows: [TemplateListPanelView.Row] = [
            .init(id: "h1", title: "A", symbol: .unknown, isHeader: true),
            .init(id: "1", title: "x", symbol: .unknown), .init(id: "2", title: "y", symbol: .unknown), .init(id: "3", title: "z", symbol: .unknown),
            .init(id: "h2", title: "B", symbol: .unknown, isHeader: true),
            .init(id: "4", title: "w", symbol: .unknown),
        ]
        let l = EffectsGridLayout(rows: rows, width: 320, tileWidth: 96)
        #expect(l.columns == 3)
        #expect(l.items.map(\.id) == ["h1", "1", "2", "3", "h2", "4"])
        let t = l.items.filter { !$0.isHeader }
        #expect(t[0].frame.minY == t[1].frame.minY && t[1].frame.minY == t[2].frame.minY)
        #expect(t[3].frame.minY > t[0].frame.minY)                       // second category starts a new line
        #expect(l.items[4].frame.minY >= t[0].frame.maxY)
        #expect(l.hit(CGPoint(x: t[1].frame.midX, y: t[1].frame.midY)) == "2")
        #expect(l.hit(CGPoint(x: 1, y: l.items[0].frame.midY)) == nil)   // headers are not hit targets
        #expect(l.contentHeight >= t[3].frame.maxY)
    }

    @Test func narrowWidthStillGetsOneColumn() {
        let l = EffectsGridLayout(rows: [.init(id: "1", title: "x", symbol: .unknown)], width: 20, tileWidth: 96)
        #expect(l.columns == 1)
    }

    @Test func everyCatalogEntryHasAPreviewStyle() {
        // Ready-made preset stacks (film looks, Voice) have no single-effect preview: their tile shows the symbol.
        let stacks = Set(EffectStackPresets.all.map(\.rowID))
        for e in EffectsPanelView.catalog where !stacks.contains(e.id) { #expect(EffectPreviewPlan.style(forID: e.id) != nil, "\(e.id)") }
    }

    /// Cost guard (not pixels): building every hover loop stays far below a frame budget per frame.
    @Test func previewBuildCostStaysSmall() {
        let (w, h) = (EffectPreviewPlan.sampleWidth, EffectPreviewPlan.sampleHeight)
        let clock = ContinuousClock()
        let (a, b) = EffectPreviewPlan.sampleImages(width: w, height: h)
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let mix = ms(clock.measure { for wgt in EffectPreviewPlan.transitionLoop { _ = EffectPreviewPlan.blend(a, b, kind: .crossDissolve, weight: wgt) } })
        let fx = ms(clock.measure { for e in EffectsPanelView.catalog { if case .effect(let id)? = EffectPreviewPlan.style(forID: e.id) { _ = EffectPreviewPlan.effectAfter(id, source: a, width: w, height: h) } } })
        #expect(mix < 4000 && fx < 4000, "loop of 30 blended frames \(mix) ms; all effect afters \(fx) ms")
    }
}
