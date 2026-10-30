import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

// Fast Cut chrome: the header switch and the Shift+G command. The edit mapping is in FastCutInteractionTests,
// the session commands in FastCutSessionTests.

@MainActor
struct MagneticEditTests {
    @Test func headerModeSwitchSitsLeftOfSnap() throws {
        let f = TimelineHeaderBar.frames(width: 900, showsEditMode: true)
        #expect(f.editMode.maxX <= f.snap.minX && f.editMode.minX >= f.tabs.maxX)
    }
}

@MainActor
struct MagneticCommandTests {
    @Test func toggleMagneticHasAKeyAndMenuItem() {
        #expect(CommandSupport.isSupported(.toggleMagnetic))
        #expect(EditorMenus.sequence.commands.contains(.toggleMagnetic))
        #expect(CommandMap.premiereDefault.binding(for: .toggleMagnetic) != nil)
        #expect(EditorCommand.toggleMagnetic.title == "Fast Cut")
    }
}
