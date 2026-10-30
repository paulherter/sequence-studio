import AppKit
import Testing
import SQCore
import SQUIKit
@testable import SQInspectorUI

/// The Color page of design version 9: clip rows, Steps graph, section headers.
@MainActor @Suite struct ColorPageV9Tests {
    @Test func clipRowSaysWhichGradeIsActiveAndWhichIsKept() {
        var graph = ColorGraph()
        #expect(ColorClipRow.gradeText(hasSimple: false, graph: nil) == "No grade")
        #expect(ColorClipRow.gradeText(hasSimple: true, graph: nil) == "Simple")
        graph.isActive = true
        #expect(ColorClipRow.gradeText(hasSimple: false, graph: graph) == "Pro")
        #expect(ColorClipRow.gradeText(hasSimple: true, graph: graph) == "Pro on, Simple kept")
        graph.isActive = false
        #expect(ColorClipRow.gradeText(hasSimple: true, graph: graph) == "Simple on, Pro kept")
    }

    @Test func draggingAStepStaysInsideTheRow() {
        #expect(ColorStepsGraphView.reorderDelta(dx: 130, pitch: 120, index: 0, count: 3) == 1)
        #expect(ColorStepsGraphView.reorderDelta(dx: 900, pitch: 120, index: 0, count: 3) == 2)
        #expect(ColorStepsGraphView.reorderDelta(dx: -900, pitch: 120, index: 1, count: 3) == -1)
        #expect(ColorStepsGraphView.reorderDelta(dx: 40, pitch: 120, index: 1, count: 3) == 0)
        #expect(ColorStepsGraphView.reorderDelta(dx: 40, pitch: 0, index: 1, count: 3) == 0)
        #expect(ColorStepsGraphView.summary(1) == "1 step, 1 in series")
        #expect(ColorStepsGraphView.summary(3) == "3 steps, 3 in series")
    }

    @Test func foldedSectionShowsItsSummaryAndAnOffSectionSaysOff() {
        let h = ColorSectionHeader(title: "Curves")
        h.setSummary("Luma")
        h.setOpen(true)
        #expect(h.summary.stringValue == "")
        h.setOpen(false)
        #expect(h.summary.stringValue == "Luma")
        h.setOn(false)
        #expect(h.summary.stringValue == "Off")
        h.frame = NSRect(x: 0, y: 0, width: 340, height: ColorSectionHeader.height)
        h.layout()
        #expect(h.toggle.isHidden)                                   // version 9: no enable box in the header
        #expect(h.title.frame.maxX <= h.summary.frame.minX)
        #expect(h.summary.frame.maxX == 340 - ColorGrid.inset)
    }

    @Test func proHasSixTabs() {
        #expect(ColorGraphPage.tabTitles == ["Primaries", "Curves", "Qualifier", "Window", "LUT", "Effects"])
        #expect(ColorGrid.label == 96)
    }

    @Test func valueColumnShowsBareWholeNumbersAndTypingKeepsThePrecision() {
        #expect(ColorGrid.value - ColorGrid.gap == 48)
        #expect(ColorParamRow.shownDecimals(range: -100...100, decimals: 1) == 0)
        #expect(ColorParamRow.shownDecimals(range: -5...5, decimals: 2) == 2)
        #expect(ColorParamRow.text(8.4, decimals: 0) == "8")
        #expect(ColorParamRow.text(-18, decimals: 0) == "-18")
        #expect(ColorParamRow.text(-0.2, decimals: 0) == "0")
        #expect(ColorParamRow.text(100, decimals: 0) == "100")
        #expect(ColorParamRow.editText(8.4, decimals: 1) == "8.4")
        #expect(ColorParamRow.editText(8, decimals: 1) == "8")
        #expect(ColorParamRow.editText(-0.25, decimals: 2) == "-0.25")
        #expect(ColorParamRow.signedText(8, decimals: 0) == "+8")
        #expect(ColorParamRow.signedText(-18, decimals: 0) == "-18")
        #expect(ColorParamRow.signedText(0.2, decimals: 0) == "0")
        #expect(ColorParamRow.number("8.4") == 8.4)
        let row = ColorParamRow(.temperature)
        row.show(8.4)
        #expect((abs(row.field.value - 8.4) < 0.001) && row.field.decimals == 1, "the value keeps its precision; only the text rounds")
    }

    @Test func foldedBasicAndCreativeSayTheirValuesWithASign() {
        var e = ColorEffect(id: 1)
        #expect(ColorInspectorView.summary(.basicCorrection, channel: 0, effect: e) == "Temp 0, Exposure 0.00")
        e.basic.temperature = 8
        e.basic.exposure = -0.25
        e.creative.vibrance = 10
        #expect(ColorInspectorView.summary(.basicCorrection, channel: 0, effect: e) == "Temp +8, Exposure -0.25")
        #expect(ColorInspectorView.summary(.creative, channel: 0, effect: e) == "Vibrance +10, Saturation 100")
        #expect(ColorInspectorView.summary(.vignette, channel: 0, effect: e) == "Off")
        #expect(ColorInspectorView.summary(.curves, channel: 0, effect: e) == "Luma")
    }

    @Test func theMetaFollowsThePageTitleWhileThatTabShows() {
        let h = ColorTabHeaderView(tabs: ["Scopes", "Timeline", "Sources"])
        let plain = h.tabFrames
        h.meta = "Rec. 709"
        let lead = h.tabFrames
        #expect(lead[0] == plain[0] && lead[1].minX > plain[1].minX, "the second tab moves right of the meta")
        h.select(1)
        let other = h.tabFrames
        #expect(other[1].minX == other[0].maxX, "on another tab the meta follows the last tab")
    }

    @Test func stepsPanelOffersBothStartsOnAClipWithoutAGraph() {
        let v = ColorStepsGraphView()
        #expect(!v.emptyState.isHidden && !v.offersStart)
        let m = ColorInspectorModel()
        v.model = m
        #expect(v.offersStart && v.emptyState.isHidden && !v.startEmpty.isHidden && !v.startFromSimple.isHidden)
        #expect(v.startTitle.stringValue == "No Pro grade on this clip yet")
        #expect(v.hit(at: NSPoint(x: 60, y: 90)) == nil)
        m.startEmptyGraph()
        v.refresh()
        #expect(!v.offersStart && v.startEmpty.isHidden && v.nodes.count == 1)
        let tools = ColorGradeTools(addsStep: true)
        tools.setActions(canCopy: true, canPaste: false, canAdd: false)
        #expect(tools.views.count == 3 && tools.add?.isEnabled == false && tools.copy.isEnabled && !tools.paste.isEnabled)
        #expect(ColorGradeTools(addsStep: false).views.count == 2)
    }
}

@Suite("Color page: Timeline panel hint")
@MainActor struct ColorTimelineHintTests {
    @Test func hintShowsOnlyWhenNothingGradableIsPicked() {
        #expect(ColorInspectorPanelView.timelineDetail(for: .message("x")) == ColorInspectorPanelView.timelineHint)
        #expect(ColorInspectorPanelView.timelineDetail(for: .clip(UUID())).isEmpty)
        #expect(ColorInspectorPanelView.timelineDetail(for: .sequence(UUID(), layer: nil)).isEmpty)
    }
}
