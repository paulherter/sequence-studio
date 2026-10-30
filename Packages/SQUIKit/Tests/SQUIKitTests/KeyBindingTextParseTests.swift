import Testing
@testable import SQUIKit

/// The Mac system menu bar mirrors the shared menus, whose rows carry only the shortcut text: it is read back into a
/// binding for the NSMenuItem key equivalent.
@Suite struct KeyBindingTextParseTests {
    @Test func macTextRoundTrips() {
        let samples: [KeyBinding] = [
            KeyBinding(.char("s"), .command), KeyBinding(.char("v"), [.shift, .command]), KeyBinding(.char("c")),
            KeyBinding(.char("k"), [.control, .option, .shift, .command]), KeyBinding(.space), KeyBinding(.left, .option),
            KeyBinding(.delete, .command), KeyBinding(.returnKey), KeyBinding(.forwardDelete), KeyBinding(.function(5)),
            KeyBinding(.function(12), .shift), KeyBinding(.home), KeyBinding(.pageDown, .shift), KeyBinding(.char("=")),
            KeyBinding(.char(","), .command),
        ]
        for b in samples { #expect(KeyBindingText.parseMac(KeyBindingText.mac(b)) == b, "\(KeyBindingText.mac(b))") }
    }

    @Test func emptyOrUnknownTextIsNil() {
        #expect(KeyBindingText.parseMac("") == nil)
        #expect(KeyBindingText.parseMac("⌘") == nil)
        #expect(KeyBindingText.parseMac("Ctrl+S") == nil)
    }
}
