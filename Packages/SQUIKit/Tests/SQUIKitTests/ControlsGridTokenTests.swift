#if canImport(AppKit)
import Foundation
import Testing
@testable import SQUIKit

/// The grid's portable literals (used off the Mac) must stay the Mac `Theme` tokens at UI scale 1.
@MainActor @Suite struct ControlsGridTokenTests {
    @Test func portableTokensMatchTheme() {
        typealias P = ControlsGrid.Tokens
        typealias I = Theme.Inspector
        #expect(P.ringX == I.ringX && P.toggleWidth == I.toggleWidth && P.columnGap == I.columnGap)
        #expect(P.nameWidth == I.nameWidth && P.nameX == I.nameX && P.controlX == I.controlX)
        #expect(P.rowIndent == I.rowIndent && P.valueWidth == I.valueWidth && P.trailing == I.trailing)
        #expect(P.resetWidth == I.resetWidth && P.navigationWidth == I.navigationWidth && P.labelHeight == I.labelHeight)
        #expect(P.rowHeight == I.rowHeight && P.rowHeight == I.headerHeight && P.sectionGap == I.sectionGap)
        #expect(P.controlColumnWidth == I.controlColumnWidth && P.controlHeight == Theme.Row.control)
    }
}
#endif
