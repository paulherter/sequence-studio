import Testing
import SQDrawKit
@testable import SQDrawShell

/// WM_CHAR text on Windows: IME results, layout letters and dead keys reach text fields once.
@Suite struct ShellTextInputTests {
    @Test func asciiStaysWithTheKeyMap() {
        var t = ShellTextInput()
        t.keyDown(.character("a"))
        #expect(t.char(UInt16(UInt8(ascii: "a"))) == .none)
        t.keyDown(.character("a"))                               // Ctrl+A: a control unit
        #expect(t.char(1) == .none)
    }

    @Test func layoutLetterReplacesTheKeyMapGuess() {
        var t = ShellTextInput()
        t.keyDown(.character("`"))                               // German ö key = VK_OEM_3
        #expect(t.char(0x00F6) == .replace("ö"))
        t.keyDown(nil)                                           // AltGr letters without a key-map entry
        #expect(t.char(0x00DF) == .type("ß"))
    }

    @Test func deadKeyDropsTheAccentGuessAndTheLetterIsReplaced() {
        var t = ShellTextInput()
        t.keyDown(.character("\\"))                              // German ^ dead key
        #expect(t.deadChar() == .drop)
        t.keyDown(.character("e"))
        #expect(t.char(0x00EA) == .replace("ê"))
    }

    @Test func imeResultIsTypedAndSurrogatePairsJoin() {
        var t = ShellTextInput()
        t.keyDown(nil)                                           // VK_PROCESSKEY while composing
        #expect(t.char(0x65E5) == .type("日"))
        #expect(t.char(0x672C) == .type("本"))
        #expect(t.char(0xD83D) == .none)
        #expect(t.char(0xDE00) == .type("😀"))
        #expect(t.char(0xDE00) == .none)                         // a lone trail unit is dropped
    }
}
