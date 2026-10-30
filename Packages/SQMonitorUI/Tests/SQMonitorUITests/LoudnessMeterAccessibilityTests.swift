import AppKit
import Testing
@testable import SQMonitorUI

@MainActor
@Suite struct LoudnessMeterAccessibilityTests {
    @Test func labelRoleValueAndHelp() {
        let v = LoudnessMeterView(frame: .zero)
        #expect(v.isAccessibilityElement())
        #expect(v.accessibilityRole() == .levelIndicator)
        #expect(v.accessibilityLabel() == "Loudness meter")
        let value = v.accessibilityValue() as? String ?? ""
        #expect(value.contains("integrated no signal"))
        #expect(value.contains("loudness range needs 60 seconds"))
        #expect(v.accessibilityHelp()?.contains("Click to reset") == true)
    }

    @Test func targetShowsInHelpAndTooltip() {
        let v = LoudnessMeterView(frame: .zero)
        v.target = LoudnessTarget(lufs: -16, truePeakDB: -1.5)
        #expect(v.accessibilityHelp()?.contains("Target -16 LUFS / -1.5 dBTP") == true)
        #expect(v.sqToolTip == "Target -16 LUFS / -1.5 dBTP")
    }

    @Test func clickResetsHoldAndRangeAndNotifiesHost() throws {
        let v = LoudnessMeterView(frame: NSRect(x: 0, y: 0, width: 200, height: 112))
        var resets = 0
        v.onReset = { resets += 1 }
        let e = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        v.mouseDown(with: e)
        #expect(resets == 1)
        #expect(v.range.measuredSeconds == 0)
        #expect(v.peakHold == PeakHold())
    }
}
