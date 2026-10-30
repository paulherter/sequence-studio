import Testing
@testable import SQDrawKit

/// The Mac key route of the shared UI host: key positions to portable keys, and the typed-text rules that mirror the
/// Windows `ShellTextInput` bridge.
@Suite struct MacKeysTests {
    @Test func keyPositionsFollowTheUSCaps() {
        #expect(MacKeys.key(code: 0) == .character("a"))
        #expect(MacKeys.key(code: 6) == .character("z"))      // US Z position (Y on a German layout): same as Windows VK
        #expect(MacKeys.key(code: 29) == .character("0"))
        #expect(MacKeys.key(code: 83) == .character("1"))     // keypad
        #expect(MacKeys.key(code: 51) == .backspace)
        #expect(MacKeys.key(code: 117) == .delete)
        #expect(MacKeys.key(code: 36) == .enter)
        #expect(MacKeys.key(code: 24) == .plus)
        #expect(MacKeys.key(code: 27) == .minus)
        #expect(MacKeys.key(code: 42) == .character("\\"))
        #expect(MacKeys.key(code: 122) == .function(1))
        #expect(MacKeys.key(code: 111) == .function(12))
        #expect(MacKeys.key(code: 123) == .left)
        #expect(MacKeys.key(code: 48) == .character("\t"))
        #expect(MacKeys.key(code: 56) == nil)                 // Shift alone
    }

    @Test func modifierFlags() {
        let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
        #expect(MacKeys.modifiers(flags: command | shift) == [.command, .shift])
        #expect(MacKeys.modifiers(flags: option) == [.option])
        #expect(MacKeys.modifiers(flags: control) == [])
        #expect(MacKeys.secondaryClick(flags: control))
        #expect(!MacKeys.secondaryClick(flags: command))
    }

    @Test func asciiTypingAndShortcutsUseTheKeyMap() {
        #expect(MacKeys.events(key: .character("c"), modifiers: [], committed: "c", composing: false)
                == [.keyDown(.character("c"), modifiers: [])])
        #expect(MacKeys.events(key: .character("a"), modifiers: .shift, committed: "A", composing: false)
                == [.keyDown(.character("a"), modifiers: .shift)])
        #expect(MacKeys.events(key: .character("z"), modifiers: .command, committed: "", composing: false)
                == [.keyDown(.character("z"), modifiers: .command)])
        #expect(MacKeys.events(key: .left, modifiers: [], committed: "", composing: false) == [.keyDown(.left, modifiers: [])])
        // Return's committed "\r" is a key, not text.
        #expect(MacKeys.events(key: .enter, modifiers: [], committed: "\r", composing: false) == [.keyDown(.enter, modifiers: [])])
    }

    @Test func layoutLettersReplaceTheKeyMapGuess() {
        // German ö sits on the US ";" position.
        #expect(MacKeys.events(key: .character(";"), modifiers: [], committed: "ö", composing: false)
                == [.keyDown(.character("ö"), modifiers: [])])
        #expect(MacKeys.events(key: .character("s"), modifiers: .option, committed: "ß", composing: false)
                == [.keyDown(.character("ß"), modifiers: [])])
    }

    @Test func compositionsTypeOnlyCommittedText() {
        // Dead key (Option-E): marked text, nothing typed.
        #expect(MacKeys.events(key: .character("e"), modifiers: .option, committed: "", composing: true).isEmpty)
        // The next letter commits "é".
        #expect(MacKeys.events(key: .character("e"), modifiers: [], committed: "é", composing: true)
                == [.keyDown(.character("é"), modifiers: [])])
        // An IME commits several characters, ASCII included.
        #expect(MacKeys.events(key: .enter, modifiers: [], committed: "日本a", composing: true)
                == [.keyDown(.character("日"), modifiers: []), .keyDown(.character("本"), modifiers: []),
                    .keyDown(.character("a"), modifiers: [])])
        // Command shortcuts never go through the input method.
        #expect(MacKeys.events(key: .character("s"), modifiers: .command, committed: "x", composing: true)
                == [.keyDown(.character("s"), modifiers: .command)])
    }

    @Test func unknownKeysTypeTheirText() {
        #expect(MacKeys.events(key: nil, modifiers: [], committed: "<", composing: false)
                == [.keyDown(.character("<"), modifiers: [])])
        #expect(MacKeys.events(key: nil, modifiers: [], committed: "\u{F700}", composing: false).isEmpty)
    }
}
