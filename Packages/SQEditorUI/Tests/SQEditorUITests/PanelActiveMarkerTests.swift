import AppKit
import Testing
import SQUIKit
@testable import SQEditorUI

@MainActor @Suite struct PanelActiveMarkerTests {
    @Test func activeLineIsAccentInactiveIsQuiet() {
        #expect(PanelActiveMarker.lineColor(active: true) == Theme.Colors.accent)
        #expect(PanelActiveMarker.lineColor(active: false) == Theme.Colors.label3)
    }

    @Test func lineSitsAtTopWithoutHeaderAndAtHeaderBottomWithOne() {
        let b = CGRect(x: 0, y: 0, width: 400, height: 300)
        let top = PanelActiveMarker.lineFrame(in: b, headerHeight: 0)
        #expect(top.minY == 0 && top.height == PanelActiveMarker.thickness)
        let withHeader = PanelActiveMarker.lineFrame(in: b, headerHeight: 30)
        #expect(withHeader.maxY == 30)
        #expect(withHeader.width == 400 - 2 * Theme.Spacing.sm)
    }
}

@Suite struct PanelFocusRuleTests {
    @Test func stripLessGroupIsAccentOnlyWhileFocused() {
        #expect(PanelFocusRule.line(isFocused: true, stripShown: false) == .accent)
        #expect(PanelFocusRule.line(isFocused: false, stripShown: false) == .quiet)
        #expect(PanelFocusRule.line(isFocused: true, stripShown: true) == .none)
    }

    @Test func sequenceTabUnderlineFollowsPanelFocus() {
        #expect(PanelActiveMarker.lineColor(active: true) == Theme.Colors.accent)
        #expect(PanelActiveMarker.lineColor(active: false) == Theme.Colors.label3)
        // The Timeline group counts as having its strip (the sequence tabs): no extra full-width line.
        #expect(PanelFocusRule.line(isFocused: true, stripShown: true) == .none)
    }

    @Test func timelineLosesFocusWhenAnotherPanelTakesIt() {
        var focused: PanelID? = .timeline
        #expect(PanelFocusRule.isFocused(group: .timeline, focused: focused))
        focused = PanelFocusRule.focus(afterResponderIn: .effectControls, current: focused)
        #expect(!PanelFocusRule.isFocused(group: .timeline, focused: focused))
        #expect(PanelFocusRule.isFocused(group: .effectControls, focused: focused))
        // A responder outside every panel keeps the current panel.
        #expect(PanelFocusRule.focus(afterResponderIn: nil, current: .effectControls) == .effectControls)
    }
}
