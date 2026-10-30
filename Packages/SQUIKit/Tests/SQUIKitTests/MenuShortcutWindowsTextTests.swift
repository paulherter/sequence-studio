import Testing
@testable import SQUIKit

@Suite struct MenuShortcutWindowsTextTests {
    @Test func windowsTextNamesTheKeys() {
        #expect(SQMenuShortcut.windowsText(key: "v", keyModifiers: [.command, .shift]) == "Ctrl+Shift+V")
        #expect(SQMenuShortcut.windowsText(key: "v", keyModifiers: [.command, .option]) == "Ctrl+Alt+V")
        #expect(SQMenuShortcut.windowsText(key: "g", keyModifiers: []) == "G")
        #expect(SQMenuShortcut.windowsText(key: "\u{8}", keyModifiers: [.command]) == "Ctrl+Backspace")
        #expect(SQMenuShortcut.windowsText(key: "", keyModifiers: [.command]) == "")
    }

    @Test func macTextKeepsTheGlyphs() {
        #expect(SQMenuShortcut.macText(key: "v", keyModifiers: [.command, .shift]) == "\u{21E7}\u{2318}V")
    }
}
