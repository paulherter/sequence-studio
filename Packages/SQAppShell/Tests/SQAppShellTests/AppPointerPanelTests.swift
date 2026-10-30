import Foundation
import SQDrawKit
import Testing
@testable import SQAppShell

/// The panel's own cursor request (`HostHover.cursor`) sits under the eyedropper, dividers and text, over the hand rule.
@Suite struct AppPointerPanelTests {
    @Test func panelRequestComesAfterEdgesAndText() {
        #expect(AppPointer.shape(.init(panel: .razor)) == .razor)
        #expect(AppPointer.shape(.init(handOverTimeline: true, panel: .closedHand)) == .closedHand)
        #expect(AppPointer.shape(.init(divider: .vertical, panel: .razor)) == .resizeUpDown)
        #expect(AppPointer.shape(.init(textEditing: true, panel: .trimIn)) == .iBeam)
        #expect(AppPointer.shape(.init(sampling: true, panel: .trimIn)) == .crosshair)
    }
}
