import Foundation
import Testing
import SQUIKit
@testable import SQInspectorUI

/// The Windows Controls panel lays out with literal row heights (SQUIKit's Theme is AppKit): they must stay the Mac ones.
@MainActor @Suite struct ControlsMetricsPortableTests {
    @Test func portableHeightsMatchTheMacTheme() {
        #expect(ControlsMetrics.Portable.clipLine == ControlsMetrics.clipLine)
        #expect(ControlsMetrics.Portable.header == ControlsMetrics.header)
        #expect(ControlsMetrics.Portable.group == ControlsMetrics.group)
        #expect(ControlsMetrics.Portable.section == ControlsMetrics.section)
        #expect(ControlsMetrics.Portable.parameter == ControlsMetrics.parameter)
        #expect(ControlsMetrics.Portable.parameter == ControlsMetrics.tallParameter)
        #expect(ControlsMetrics.Portable.graph == ControlsMetrics.graph)
        #expect(ControlsMetrics.Portable.popupWidth == ControlsMetrics.popupWidth)
        #expect(CaptionListDraw.rowHeight == Theme.Row.list)
        #expect(CaptionListDraw.nameWidth == Theme.Inspector.nameWidth)
        #expect(CaptionListDraw.timeWidth == Theme.Inspector.nameWidth + Theme.Inspector.columnGap)
    }
}
