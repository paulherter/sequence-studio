import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct ProjectNotesDialogTests {
    @Test func viewShowsAndReturnsTheNotes() {
        let ui = ProjectNotesDialog.makeView(text: "Deliver Friday")
        #expect(ui.textView.string == "Deliver Friday")
        ui.textView.string = "Deliver Monday\nsecond line"
        #expect(ProjectNotesDialog.notes(from: ui.textView) == "Deliver Monday\nsecond line")
    }

    @Test func salvageNoticeListsWhatWasDroppedAndSaysTheOriginalIsSafe() {
        let r = ProjectSalvageReport(dropped: ["Clip “B” on “V1” in “Main”: unknown or damaged"])
        let d = ProjectSalvageNotice.detail(fileName: "a.sqproj", report: r)
        #expect(d.contains("Clip “B”"))
        #expect(d.contains("original file was not changed"))
    }

    @Test func aLongListIsCounted() {
        let r = ProjectSalvageReport(dropped: (0..<12).map { "Clip \($0)" })
        let d = ProjectSalvageNotice.detail(fileName: "a.sqproj", report: r)
        #expect(d.contains("and 4 more"))
        #expect(!d.contains("Clip 11"))
    }
}
