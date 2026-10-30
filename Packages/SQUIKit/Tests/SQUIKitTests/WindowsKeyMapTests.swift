import Foundation
import Testing
@testable import SQUIKit

@Suite("WindowsKeyMap")
struct WindowsKeyMapTests {
    let map = CommandMap.premiereDefault

    @Test func windowsTextUsesCtrlAltShiftOrder() {
        #expect(KeyBindingText.windows(KeyBinding(.char("s"), .command)) == "Ctrl+S")
        #expect(KeyBindingText.windows(KeyBinding(.char("k"), [.command, .shift])) == "Ctrl+Shift+K")
        #expect(KeyBindingText.windows(KeyBinding(.char("m"), [.control, .option])) == "Ctrl+Alt+M")
        #expect(KeyBindingText.windows(KeyBinding(.delete, [])) == "Backspace")
        #expect(KeyBindingText.windows(KeyBinding(.forwardDelete, [])) == "Del")
        #expect(KeyBindingText.windows(KeyBinding(.pageDown, .shift)) == "Shift+PgDn")
        #expect(KeyBindingText.windows(KeyBinding(.function(5), [])) == "F5")
    }

    @Test func macTextKeepsTheMenuGlyphs() {
        #expect(KeyBindingText.mac(KeyBinding(.char("k"), [.command, .shift])) == "⇧⌘K")
        #expect(KeyBindingText.mac(KeyBinding(.delete, .control)) == "⌃⌫")
    }

    @Test func ctrlReachesCommandFirstThenControl() {
        #expect(WindowsKeyRoute.command(.char("s"), ctrl: true, alt: false, shift: false, focus: nil, map: map) == .save)
        // No Cmd+Space binding: Ctrl+Space falls through to the Mac Control binding.
        #expect(WindowsKeyRoute.command(.space, ctrl: true, alt: false, shift: false, focus: nil, map: map) == .playToOut)
        #expect(WindowsKeyRoute.command(.char("k"), ctrl: true, alt: false, shift: false, focus: .timeline, map: map) == .addEdit)
        #expect(WindowsKeyRoute.command(.space, ctrl: false, alt: false, shift: false, focus: nil, map: map) == .playPause)
    }

    @Test func candidatesOrder() {
        let c = WindowsKeyRoute.candidates(.char("a"), ctrl: true, alt: true, shift: false)
        #expect(c.map(\.modifiers) == [[.command, .option], [.control, .option], [.command, .control, .option]])
        #expect(WindowsKeyRoute.candidates(.char("a"), ctrl: false, alt: false, shift: true).map(\.modifiers) == [.shift])
    }

    @Test func shadowedListsControlBindingsWithACtrlTwin() {
        let s = WindowsKeyRoute.shadowed(map)
        #expect(s.contains { $0.command == .jumpCutAlternate })     // Ctrl+K is Add Edit
        #expect(!s.contains { $0.command == .playToOut })           // Ctrl+Space is free
        #expect(s.allSatisfy { $0.binding.modifiers.contains(.control) })
    }

    @Test func portableMenuGlyphsMatchTheModifierOrder() {
        #expect(SQMenuShortcut.glyphs(key: "k", keyModifiers: [.command, .shift]) == "⇧⌘K")
    }
}
