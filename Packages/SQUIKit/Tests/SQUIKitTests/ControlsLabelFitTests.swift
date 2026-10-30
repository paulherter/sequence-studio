import AppKit
import Testing
@testable import SQUIKit

/// Long parameter names ("Repeat Edge Pixels") keep the 88 pt label column: cut in the middle with a tooltip, or, in a row
/// without a control, widened into the free room.
@MainActor @Suite struct ControlsLabelFitTests {
    let grid = ControlsGrid(width: 324)

    @Test func longNameIsCutInTheMiddleWithTooltip() {
        let l = makeLabel("Repeat Edge Pixels")
        let f = grid.place(l, height: 24)
        #expect(f.width == Theme.Inspector.nameWidth)
        #expect(l.lineBreakMode == .byTruncatingMiddle)
        #expect(l.sqToolTip == "Repeat Edge Pixels")
    }

    @Test func shortNameHasNoTooltip() {
        let l = makeLabel("Scale")
        grid.place(l, height: 24)
        #expect(l.sqToolTip == nil)
    }

    @Test func rowWithoutControlTakesTheFreeWidth() {
        let l = makeLabel("Repeat Edge Pixels")
        let f = grid.place(l, height: 24, maxX: grid.valueMaxX)
        #expect(f.width > Theme.Inspector.nameWidth)
        #expect(l.sqToolTip == nil)
        #expect(f.maxX <= grid.valueMaxX)
    }

    @Test func truncationRule() {
        #expect(ControlsGrid.truncates(textWidth: 100, frameWidth: 88))
        #expect(!ControlsGrid.truncates(textWidth: 88, frameWidth: 88))
    }
}
