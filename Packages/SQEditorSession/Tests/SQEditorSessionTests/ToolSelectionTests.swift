import Foundation
import Testing
import SQUIKit
@testable import SQEditorSession

/// Tools menu and tool keys: one mapping from the key-map tool to the timeline's tool state, for the AppKit app and the shell.
struct ToolSelectionTests {
    @Test func everyEditorToolMapsToATimelineTool() {
        for t in EditorTool.allCases {
            var s = ToolState()
            let ok = s.select(t)
            #expect(ok, "\(t)")
        }
    }

    @Test func trackSelectKeepsItsDirection() {
        var s = ToolState()
        #expect(s.select(.trackBackward) && s.tool == .trackSelectForward && s.selectBackward)
        #expect(s.select(.trackForward) && !s.selectBackward)
    }

    @Test func plainSlipClearsTheKeyframesStayVariant() {
        var s = ToolState()
        s.slipKeyframesStay = true
        #expect(s.select(.slip) && s.tool == .slip && !s.slipKeyframesStay)
        #expect(s.selectSlipKeyframesStay() && s.tool == .slip && s.slipKeyframesStay)
    }

    @Test func createToolsPickTheirMode() {
        var s = ToolState()
        #expect(s.select(.ellipse) && s.tool == .type && s.createMode == .ellipse)
        #expect(s.select(.type) && s.createMode == .text)
    }

    @Test func maskAndRateStretchAndPositionMap() {
        var s = ToolState()
        #expect(s.select(.mask) && s.tool == .mask)
        #expect(s.select(.rateStretch) && s.tool == .rateStretch)
        #expect(s.select(.position) && s.tool == .position)
    }
}
