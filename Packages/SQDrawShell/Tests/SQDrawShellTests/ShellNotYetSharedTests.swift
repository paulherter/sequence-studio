import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellNotYetSharedTests {
    @Test func autoCaptionsIsNoLongerOnTheList() {
        #expect(!ShellHost.notYetShared.contains(.autoCaptions))
    }

    @Test func aMenuItemNothingHandlesSaysSoInsteadOfDoingNothing() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        // Only commands the shell offers (enabled) can reach the flash.
        // Walks the list itself: a command leaves it as soon as a shared flow runs it (no handler is installed here, so
        // a command that still flashes must say so; one that a flow took over simply is not in the list).
        for c in ShellHost.notYetShared {
            lines = []
            if h.enabled(c) {
                #expect(h.execute(c))
                #expect(lines.last?.hasSuffix("is not available in this window yet.") == true)
            } else {
                #expect(!h.execute(c))
            }
        }
    }
}
