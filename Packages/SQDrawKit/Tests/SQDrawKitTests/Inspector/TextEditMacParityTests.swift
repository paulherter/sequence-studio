import Testing
@testable import SQDrawKit

/// The Mac field editor's text handling in the drawn fields: words, clipboard, undo.
@Suite(.serialized) struct TextEditMacParityTests {
    private func typed(_ s: String) -> TextEditState {
        var e = TextEditState("", selectAll: false)
        for c in s { e.handle(c == " " ? .space : .character(c)) }
        return e
    }

    @Test func doubleClickSelectsTheWordUnderThePointer() {
        var e = TextEditState("hello big-world", selectAll: false)
        e.selectWord(at: 7)
        #expect(e.string[e.selection] == "big")
        e.selectWord(at: 5)
        #expect(e.string[e.selection] == " ")
        e.selectWord(at: 15)       // past the end: the last word
        #expect(e.string[e.selection] == "world")
    }

    @Test func optionArrowsJumpWordsAndOptionBackspaceDeletesOne() {
        var e = TextEditState("one two  three", selectAll: false)
        e.handle(.left, modifiers: .option)
        #expect(e.caret == 9)
        e.handle(.left, modifiers: .option)
        #expect(e.caret == 4)
        e.handle(.right, modifiers: .option)
        #expect(e.caret == 7)
        e.handle(.backspace, modifiers: .option)
        #expect(e.string == "one   three" && e.caret == 4)
        e.handle(.delete, modifiers: .option)
        #expect(e.string == "one " )
    }

    @Test func shiftOptionLeftExtendsTheSelectionByAWord() {
        var e = TextEditState("one two", selectAll: false)
        e.handle(.left, modifiers: [.option, .shift])
        #expect(e.string[e.selection] == "two")
    }

    @Test func copyCutAndPasteUseTheClipboard() {
        TextClipboard.shared.writeSystem = nil; TextClipboard.shared.readSystem = nil
        var e = TextEditState("hello world", selectAll: false)
        e.selectWord(at: 1)
        #expect(e.handle(.character("c"), modifiers: .command) == .moved)
        #expect(TextClipboard.shared.read() == "hello")
        #expect(e.handle(.character("x"), modifiers: .command) == .edited)
        #expect(e.string == " world")
        e.place(e.text.count)
        #expect(e.handle(.character("v"), modifiers: .command) == .edited)
        #expect(e.string == " worldhello")
    }

    @Test func pasteReplacesTheSelectionAndSystemClipboardWins() {
        var written: [String] = []
        TextClipboard.shared.writeSystem = { written.append($0) }
        TextClipboard.shared.readSystem = { "SYS" }
        defer { TextClipboard.shared.writeSystem = nil; TextClipboard.shared.readSystem = nil }
        var e = TextEditState("abc")                // all selected
        e.handle(.character("v"), modifiers: .command)
        #expect(e.string == "SYS")
        e.selectAll(); e.handle(.character("c"), modifiers: .command)
        #expect(written == ["SYS"])
    }

    @Test func aWindowsClipboardPasteUsesLFLineEnds() {
        TextClipboard.shared.readSystem = { "a\r\nb\rc" }
        defer { TextClipboard.shared.readSystem = nil }
        #expect(TextClipboard.shared.read() == "a\nb\nc")
        TextClipboard.shared.readSystem = { nil }
        TextClipboard.shared.write("local")
        #expect(TextClipboard.shared.read() == "local", "no system text: the last copy")
    }

    @Test func commandZUndoesTypingRunsAndShiftCommandZRedoes() {
        var e = typed("abc")
        e.handle(.backspace)
        #expect(e.string == "ab")
        #expect(e.handle(.character("z"), modifiers: .command) == .edited)
        #expect(e.string == "abc")
        e.handle(.character("z"), modifiers: .command)          // the whole typed run is one step
        #expect(e.string == "")
        #expect(e.handle(.character("z"), modifiers: .command) == .moved)    // nothing left: stays in the field
        e.handle(.character("z"), modifiers: [.command, .shift])
        #expect(e.string == "abc")
    }

    @Test func undoRestoresACutSelection() {
        var e = TextEditState("keep this", selectAll: false)
        e.selectWord(at: 6)
        e.handle(.character("x"), modifiers: .command)
        #expect(e.string == "keep ")
        e.handle(.character("z"), modifiers: .command)
        #expect(e.string == "keep this" && e.string[e.selection] == "this")
    }
}

private extension String {
    subscript(r: Range<Int>) -> String { String(Array(self)[r]) }
}

@Suite struct TextFieldDoubleClickTests {
    @Test func doubleClickInTheOpenFieldSelectsAWordTripleEverything() {
        var f = TextFieldControl(text: "alpha beta")
        f.mouseDown()                                   // opens, all selected
        f.mouseDown(caret: 7, clickCount: 1)
        #expect(f.editor?.caret == 7 && f.editor?.hasSelection == false)
        f.mouseDown(caret: 7, clickCount: 2)
        #expect(f.editor?.selectedText == "beta")
        f.mouseDown(caret: 7, clickCount: 3)
        #expect(f.editor?.selectedText == "alpha beta")
    }
}
