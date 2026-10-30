import Foundation
import Testing
import SQDrawKit

@Suite("Multi-line text editing")
struct TextEditLinesTests {
    @Test func returnBreaksTheLineAndReplacesTheSelection() {
        var e = TextEditState("ab", selectAll: false)
        e.place(1)
        #expect(e.handleLines(.enter) == .edited)
        #expect(e.string == "a\nb" && e.caret == 2)
        e.selectAll()
        e.handleLines(.enter)
        #expect(e.string == "\n" && e.caret == 1)
    }

    @Test func upAndDownKeepTheColumnAndClampToShortLines() {
        var e = TextEditState("hello\nab\nworld", selectAll: false)
        e.place(4)                                   // "hell|o"
        e.handleLines(.down)
        #expect(e.position(of: e.caret) == (1, 2))   // clamped to the end of "ab"
        e.handleLines(.down)
        #expect(e.position(of: e.caret) == (2, 2))   // the column the caret has now
        e.handleLines(.down)
        #expect(e.caret == e.text.count)             // past the last line: the end
        e.place(1)
        e.handleLines(.up)
        #expect(e.caret == 0)
        e.handleLines(.down, modifiers: .shift)
        #expect(e.selection == 0..<6)
    }

    @Test func homeAndEndStayOnTheLineCommandGoesToTheEnds() {
        var e = TextEditState("one\ntwo", selectAll: false)
        e.place(5)
        e.handleLines(.home)
        #expect(e.caret == 4)
        e.handleLines(.end)
        #expect(e.caret == 7)
        e.place(1)
        e.handleLines(.end)
        #expect(e.caret == 3)
        e.handleLines(.home, modifiers: .command)
        #expect(e.caret == 0)
        e.handleLines(.right, modifiers: .command)
        #expect(e.caret == 3)
    }

    @Test func typingStillGoesThroughTheSingleLineKeys() {
        var e = TextEditState("a\nb", selectAll: false)
        #expect(e.handleLines(.character("c")) == .edited)
        #expect(e.string == "a\nbc")
        e.handleLines(.backspace); e.handleLines(.backspace); e.handleLines(.backspace)
        #expect(e.string == "a")
    }

    @Test func clickPicksTheLineUnderThePointer() {
        let e = TextEditState("ab\ncd\nef", selectAll: false)
        let c = Canvas(width: 100, height: 100, atlas: nil, scale: 1)
        let r = CGRect(x: 0, y: 10, width: 100, height: 60)
        // Without a glyph atlas a character is 0.55 em wide (6.6 pt here).
        #expect(InspectorDraw.caretIndex(c, e, at: CGPoint(x: 1, y: 12), in: r, lineHeight: 16, fontSize: 12) == 0)
        #expect(InspectorDraw.caretIndex(c, e, at: CGPoint(x: 8, y: 30), in: r, lineHeight: 16, fontSize: 12) == 4)
        #expect(InspectorDraw.caretIndex(c, e, at: CGPoint(x: 99, y: 500), in: r, lineHeight: 16, fontSize: 12) == 8)
        #expect(InspectorDraw.caretIndex(c, e, at: CGPoint(x: 1, y: -50), in: r, lineHeight: 16, fontSize: 12) == 0)
    }

    @Test func drawsSelectionAcrossLinesWithoutTraps() {
        var e = TextEditState("ab\n\ncd", selectAll: true)
        var c = Canvas(width: 100, height: 100, atlas: nil, scale: 1)
        InspectorDraw.editLines(&c, e, in: CGRect(x: 0, y: 0, width: 100, height: 60), lineHeight: 16, fontSize: 12, color: .white, DrawTheme())
        e.place(3)
        InspectorDraw.editLines(&c, e, in: CGRect(x: 0, y: 0, width: 100, height: 60), lineHeight: 16, fontSize: 12, color: .white, DrawTheme())
    }
}
