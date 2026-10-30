import Testing
import SQEditorSession
@testable import SQEditorUI

@MainActor @Suite struct ImportReportStatusTests {
    @Test func cleanReportIsQuiet() {
        var r = ImportReport(); r.imported = 3
        let s = ProjectPanelView.importReportStatus(r)
        #expect(s.text == "Imported 3 files.")
        #expect(s.isProblem == false)
        #expect(s.detail == nil)
    }

    @Test func skippedFilesAreAProblemWithNamedDetail() {
        var r = ImportReport(); r.imported = 1
        r.alreadyInProject = ["a.mov"]
        r.failed = [.init(file: "b.mov", detail: "Damaged.")]
        r.audioDropped = [.init(file: "c.mkv", detail: "ac-3")]
        let s = ProjectPanelView.importReportStatus(r)
        #expect(s.text == r.summary)
        #expect(s.isProblem)
        let d = s.detail ?? ""
        #expect(d.contains("Already in the project: a.mov"))
        #expect(d.contains("b.mov: Damaged."))
        #expect(d.contains("c.mkv: ac-3"))
    }

    @Test func longListsAreCapped() {
        var r = ImportReport()
        r.duplicates = (1...12).map { "f\($0).wav" }
        let d = ProjectPanelView.importReportStatus(r).detail ?? ""
        #expect(d.contains("f1.wav"))
        #expect(!d.contains("f12.wav"))
        #expect(d.contains("and 7 more"))
    }
}
