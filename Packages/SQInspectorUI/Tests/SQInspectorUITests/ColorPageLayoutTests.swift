import AppKit
import Testing
import SQCore
import SQUIKit
@testable import SQInspectorUI

/// Color page layout rules: the row cap of the Color controls and the LUT slots of the Steps graph.
@MainActor
struct ColorPageLayoutTests {
    /// The Color column is 0.236 of the window (`Workspace.color`): 1426, 1920 and 2560 wide windows.
    @Test func rowWidthIsCappedOnWideWindows() {
        for (window, panel) in [(1426.0, 336.5), (1920.0, 453.1), (2560.0, 604.2)] {
            let w = ColorGrid.rowWidth(panelWidth: window * 0.236)
            #expect(abs(w - panel) < 1 || w == Theme.Inspector.maxRowWidth)
            #expect(w <= Theme.Inspector.maxRowWidth)
        }
        #expect(ColorGrid.rowWidth(panelWidth: 336) == 336)
        #expect(ColorGrid.rowWidth(panelWidth: 604) == Theme.Inspector.maxRowWidth)
        #expect(ColorGrid.rowWidth(panelWidth: -4) == 0)
    }

    @Test func slotGrowsToItsLabel() {
        #expect(StepsCanvas.slotWidth(textWidth: 10) == StepsCanvas.slot.width)
        let automatic = ColorStepsGraphView.slotWidth("Automatic")
        #expect(automatic > StepsCanvas.slot.width)
        #expect(automatic >= ceil(("Automatic" as NSString).size(withAttributes: [.font: Theme.Typography.caption]).width))
        #expect(StepsCanvas.slotWidth(textWidth: 4000) == StepsCanvas.slotMax)
        var canvas = StepsCanvas(columns: [])
        canvas.inSlotWidth = automatic
        #expect(canvas.layout().inSlot.width == automatic)
    }

    @Test func sourceTileSaysTheGradeState() {
        #expect(ColorClipRow.gradeText(hasSimple: false, graph: nil) == "No grade")
        #expect(ColorClipRow.gradeText(hasSimple: true, graph: nil) == "Simple")
    }
}
