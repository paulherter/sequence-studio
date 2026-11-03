import Testing
import SQDrawKit

/// The Mac host's text rules: the layout's text reaches text fields, Option+Space stays a shortcut.
@Suite struct MacTypedTextTests {
    @Test func optionSpaceStaysAShortcutNotANonBreakingSpace() {
        #expect(MacKeys.events(key: .space, modifiers: .option, committed: "\u{A0}", composing: false)
                == [.keyDown(.space, modifiers: .option)])
        #expect(MacKeys.typedText(key: .space, modifiers: .option, committed: "\u{A0}", composing: false) == nil)
    }

    @Test func textFieldsTypeTheLayoutsText() {
        // German cap Y sits at the US Z position: the key is Y, and Shift types a capital.
        let key = MacKeys.key(code: 6, base: "y")
        #expect(key == .character("y"))
        #expect(MacKeys.typedText(key: key, modifiers: .shift, committed: "Y", composing: false) == "Y")
        #expect(MacKeys.typedText(key: .character("l"), modifiers: .option, committed: "@", composing: false) == "@")
        #expect(MacKeys.typedText(key: .character("c"), modifiers: .command, committed: "c", composing: false) == nil)
        var t = TextEditState("", selectAll: false)
        HostTypedText.shared.with("Y") { _ = t.handle(.character("z"), modifiers: .shift) }
        HostTypedText.shared.with("@") { _ = t.handle(.character("l"), modifiers: .option) }
        #expect(t.string == "Y@")
    }
}
