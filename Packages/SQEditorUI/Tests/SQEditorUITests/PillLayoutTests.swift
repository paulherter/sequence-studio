import AppKit
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// Pills that sit side by side in a manually laid out row must never overlap: a stack view of pills has no intrinsic size,
/// so layouts read `sqLayoutSize` (falls back to the fitting size).
@MainActor @Suite struct PillLayoutTests {
    private func pillPair() -> NSStackView {
        let a = SQButton(title: "Fit", target: nil, action: nil), b = SQButton(title: "Full", target: nil, action: nil)
        let s = NSStackView(views: [a, b]); s.spacing = Theme.Spacing.sm
        return s
    }

    @Test func stackOfPillsGetsItsFittingWidth() {
        let s = pillPair()
        #expect(s.sqLayoutSize.width > 0)
        #expect(s.sqLayoutSize.width >= s.arrangedSubviews.reduce(0) { $0 + $1.fittingSize.width } + s.spacing)
    }

    @Test func plainControlKeepsIntrinsicSize() {
        let b = SQButton(title: "Fit", target: nil, action: nil)
        #expect(b.sqLayoutSize == b.intrinsicContentSize)
    }

    @Test func colourRowDoesNotCollapseAStackOfPills() {
        let pair = pillPair(), first = SQButton(title: "Set", target: nil, action: nil)
        let row = ColorControlRow(title: "Mode", controls: [first, pair], stretchFirst: true)
        row.frame = NSRect(x: 0, y: 0, width: 360, height: ColorGrid.controlRow)
        row.layout()
        #expect(pair.frame.width > 1)
        #expect(first.frame.maxX + ColorGrid.gap <= pair.frame.minX + 0.5)
    }
}
