import AppKit
import Testing
import SQUIKit
@testable import SQInspectorUI

/// Color inspector rows follow the design board "Color" (build.py `colorinsp`).
@MainActor @Suite struct ColorBoardLayoutTests {
    @Test func popupRowsAre28AndIconButtons24Wide() {
        #expect(ColorGrid.popupRow == 28)
        #expect(ColorActionRow.height == 28)
        let picker = InputPickerView(label: "Interpret As", automaticTitle: { "Automatic" })
        #expect(picker.row.intrinsicContentSize.height == 28)

        let popup = SQPopup(frame: .zero, pullsDown: false)
        let star = SQButton(symbol: .star, label: "Favorite", target: nil, action: nil)
        let row = ColorControlRow(title: "Source LUT", controls: [popup, star], height: ColorGrid.popupRow)
        row.frame = NSRect(x: 0, y: 0, width: 322, height: ColorGrid.popupRow)
        row.layout()
        #expect(star.frame.width == 24)
        #expect(star.frame.maxX == 322 - ColorGrid.inset)
        #expect(popup.frame.maxX == star.frame.minX - ColorGrid.gap)
    }

    @Test func labelsCompensateTheTextFieldInset() {
        let row = ColorControlRow(title: "White Balance", controls: [], height: ColorGrid.row)
        row.frame = NSRect(x: 0, y: 0, width: 322, height: ColorGrid.row)
        row.layout()
        #expect(row.intrinsicContentSize.height == 24)
        #expect(row.label.frame.minX == ColorGrid.labelX - ColorGrid.textInset)
    }
}
