import Foundation
import Testing
import SQExport
import SQUIKit
@testable import SQDrawShell

@MainActor
@Suite struct ShellExportQueueMenuTests {
    @Test func theRingMenuListsEachJobWithItsStateAndAction() throws {
        let (h, _, _) = ShellImportTests().host()
        var revealed: URL?
        h.revealFile = { revealed = $0 }
        #expect(h.exportQueueItems([]).map { $0.title } == ["Export Queue", "No exports yet"])
        let out = URL(fileURLWithPath: "/tmp/a.mp4")
        let jobs: [ShellHost.ExportQueueJob] = [
            (UUID(), "Cut A", .running, 0.424),
            (UUID(), "Cut B", .done(out), 1),
            (UUID(), "Cut C", .cancelled, 0),
        ]
        let rows = h.exportQueueItems(jobs)
        #expect(rows.map { $0.title } == ["Export Queue", "Cut A — 42 %", "Cut B — Done", "Cut C — Canceled"])
        #expect(rows[1].submenu?.map { $0.title } == ["Cancel"])
        #expect(rows[3].submenu == nil && !rows[3].isEnabled)
        let show = try #require(rows[2].submenu?.first)
        show.action?()
        #expect(revealed == out)
    }
}
