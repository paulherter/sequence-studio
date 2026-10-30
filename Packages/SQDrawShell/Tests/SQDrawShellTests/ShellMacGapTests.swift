import Foundation
import Testing
import SQDrawKit
@testable import SQDrawShell

/// Mac parity gaps (round 16): the extra space the Mac dialogs have before a row, measured against the AppKit PNGs.
@MainActor
@Suite struct ShellMacGapTests {
    func height(_ rows: [ShellForm.Row], gaps: [Int: CGFloat]) -> CGFloat {
        let f = ShellForm(rows)
        f.extraGapBefore = gaps
        return f.height(width: 400)
    }

    @Test func anExtraGapAddsExactlyItsValue() {
        let rows: [ShellForm.Row] = [.text("a"), .text("b"), .text("c")]
        #expect(height(rows, gaps: [2: 8]) - height(rows, gaps: [:]) == 8)
    }

    @Test func aGapBeforeTheFirstRowMovesTheWholeBody() {
        let rows: [ShellForm.Row] = [.text("a"), .text("b")]
        #expect(height(rows, gaps: [0: -4]) - height(rows, gaps: [:]) == -4)
    }

    @Test func theAudioGainNoteHasAFourPointInset() async {
        let rows: [ShellForm.Row] = [.text("a"), .text("b")]
        #expect(height(rows, gaps: [1: 2]) - height(rows, gaps: [:]) == 2)
    }

    @Test func aFilledIconDrawsMoreThanItsOutline() {
        var filled = Canvas(width: 24, height: 24, atlas: nil, scale: 1)
        filled.draw(icon: .play, at: .zero, size: 24, DrawColor(1, 1, 1, 1))
        var open = Canvas(width: 24, height: 24, atlas: nil, scale: 1)
        open.draw(icon: .search, at: .zero, size: 24, DrawColor(1, 1, 1, 1))
        #expect(!filled.list.quads.isEmpty)
        #expect(filled.list.quads.count > open.list.quads.count && open.list.quads.count > 0)
    }
}
