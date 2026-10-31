import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

@Suite("ShellKeys")
struct ShellKeysTests {
    let map = CommandMap.premiereDefault

    @Test func ctrlSSavesAndPlainKeysReachTheTimelineMap() {
        #expect(ShellKeys.command(.character("S"), .command, focus: nil, map: map) == .save)
        #expect(ShellKeys.command(.space, [], focus: nil, map: map) == .playPause)
        #expect(ShellKeys.command(.plus, [], focus: .timeline, map: map) == .zoomIn)
        #expect(ShellKeys.command(.minus, .command, focus: .timeline, map: map) == .videoTracksShorter)
    }

    @Test func macForwardDeleteFallsBackToDelete() {
        let del = ShellKeys.command(.backspace, [], focus: .timeline, map: map, mac: true)
        #expect(del != nil)
        #expect(ShellKeys.command(.delete, [], focus: .timeline, map: map, mac: true) == del)
    }

    @Test func altAloneIsATapButAltWithAKeyOrClickIsNot() {
        var t = AltTap()
        var taps: [Bool] = []
        t.altDown(); t.altDown()          // key repeat
        taps.append(t.altUp())
        t.altDown(); t.other(); t.altDown()
        taps.append(t.altUp())            // Alt+F: a shortcut
        taps.append(t.altUp())            // a lone key-up (Alt went down before the window had focus)
        t.altDown()
        taps.append(t.altUp())
        #expect(taps == [true, false, false, true])
    }

    @Test @MainActor func altTapOpensTheFirstMenuAndASecondTapClosesIt() {
        let bar = MenuBar()
        bar.menus = [ShellMenu(title: "File", items: [SQMenuItem(title: "Open", action: {})])]
        bar.altTapped()
        #expect(bar.open == 0)
        bar.altTapped()
        #expect(bar.open == nil)
    }

    @Test func backspaceIsTheMacDeleteAndEscapeStaysWithTheHost() {
        #expect(ShellKeys.key(.backspace) == .delete)
        #expect(ShellKeys.key(.delete) == .forwardDelete)
        #expect(ShellKeys.key(.escape) == nil)
    }

    @Test func pageAndFunctionKeysReachTheMap() {
        #expect(ShellKeys.key(.pageUp) == .pageUp)
        #expect(ShellKeys.key(.pageDown) == .pageDown)
        #expect(ShellKeys.key(.function(5)) == .function(5))
        #expect(ShellKeys.key(.character("\t")) == .char("\t"))
    }

    @Test func windowTitleMarksUnsavedChanges() {
        #expect(ShellWindowTitle.text(projectName: "Film", dirty: true) == "*Film - Sequence Studio")
        #expect(ShellWindowTitle.text(projectName: "Film", dirty: false) == "Film - Sequence Studio")
        #expect(ShellWindowTitle.text(projectName: nil, dirty: false) == "Sequence Studio")
    }
}
