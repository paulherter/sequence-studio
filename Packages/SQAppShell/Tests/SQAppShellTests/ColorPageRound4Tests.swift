import Foundation
@testable import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import Testing

/// Color page round 4 on the shared UI: the Timeline strip's tools, the Scopes hint and the status bar's grade text.
@MainActor
@Suite struct ColorPageRound4Tests {
    func colorPage() throws -> (EditorSession, ShellHost, ColorPageHost) {
        let (s, shell, host) = try ColorPageHostTests().rig()
        shell.dock.setPage(.color)
        _ = host.monitorCard(shell.dock.cardFrame(.programMonitor))
        shell.dock.layout()
        host.layout()
        return (s, shell, host)
    }

    @Test func theTimelineStripKeepsRoomForTheGradeToolsOnlyOnTheColorPage() throws {
        let (_, shell, host) = try ColorPageHostTests().rig()
        host.layout()
        #expect(shell.dock.stripTools(.timeline) == 0)
        shell.dock.setPage(.color)
        shell.dock.layout()
        host.layout()
        // The Color layout puts the Timeline in a group with Steps and Sources: its strip shows, with Copy / Paste Grade.
        let g = try #require(shell.dock.groups.first { $0.selected == .timeline })
        #expect(g.strip.height > 0)
        #expect(shell.dock.stripTools(.timeline) > 2 * 24)
        // A press on Copy Grade at the right end of the Timeline strip is the tools' (no release: the grade clipboard is
        // shared with the other suites running in parallel).
        let copy = CGPoint(x: g.strip.maxX - 8 - 24 - 2 - 12, y: g.strip.midY)
        #expect(host.handle(.mouseDown(x: Float(copy.x), y: Float(copy.y), modifiers: []), scale: 1))
    }

    @Test func scopesHintAndGradeStatusOnlyOnTheColorPage() throws {
        let (s, shell, host) = try colorPage()
        #expect(host.gradeStatus == host.controller.gradeStatus)
        #expect(!host.gradeStatus.isEmpty)
        // The playhead past the clip: the monitor shows no clip, the Scopes say they measure something else.
        s.seek(to: Time(5, 1))
        host.controller.sync([.playhead])
        #expect(host.scopesHint == host.controller.onScreenHint)
        #expect(host.scopesHint != nil)
        shell.dock.setPage(.edit)
        host.layout()
        #expect(host.scopesHint == nil && host.gradeStatus.isEmpty)
    }
}
