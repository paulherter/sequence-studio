import Testing
@testable import SQUIKit

/// Close Project is a command like any other, so its key can be changed in Keyboard Shortcuts.
@Suite struct CloseProjectCommandTests {
    @Test func isAShellCommandInTheFileMenuWithCommandShiftW() {
        #expect(EditorMenus.file.commands.contains(.closeProject))
        #expect(CommandSupport.isShellCommand(.closeProject))
        let b = CommandMap.premiereDefault.binding(for: .closeProject)
        #expect(b?.modifiers == [.command, .shift])
        #expect(CommandMap.premiereDefault.duplicates.isEmpty)
        #expect(EditorMenus.clip.commands.contains(.setPosterFrame))
        #expect(CommandMap.premiereDefault.binding(for: .setPosterFrame) != nil)
    }
}
