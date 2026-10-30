import Testing
@testable import SQUIKit

/// Remove Silences, Remove Filler Words and Punch In Cuts must stay reachable (menus, supported, titled).
@Suite struct ShortformCommandsVisibleTests {
    private let commands: [EditorCommand] = [.removeSilences, .removeFillerWords, .punchInCuts]

    @Test func listedInMenus() {
        let listed = Set(EditorMenus.all.flatMap(\.commands))
        for c in commands { #expect(listed.contains(c), "\(c) missing from the menus") }
    }

    @Test func supportedAndTitled() {
        for c in commands {
            #expect(CommandSupport.isSupported(c))
            #expect(!c.title.isEmpty)
        }
    }
}
