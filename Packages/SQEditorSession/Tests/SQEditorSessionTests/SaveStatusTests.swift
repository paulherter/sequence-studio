import Foundation
import Testing
@testable import SQEditorSession

@Suite struct SaveStatusTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    private func make(dirty: Bool, file: Bool = true, edit: Date? = nil, backup: Date? = nil) -> SaveStatus {
        SaveStatus.make(isDirty: dirty, hasFile: file, lastEdit: edit, lastBackup: backup, timeZone: utc)
    }

    @Test func cleanProjectWithFileIsSaved() {
        #expect(make(dirty: false).text == "Saved")
        // A backup never turns a clean project into anything else, and "Autosaved" is never claimed.
        #expect(make(dirty: false, backup: t0).text == "Saved")
    }

    @Test func editWithoutBackupSaysEdited() {
        #expect(make(dirty: true, edit: t0).text == "Edited")
        #expect(make(dirty: true).text == "Edited")
        #expect(make(dirty: true, edit: t0).kind == .edited)
    }

    @Test func backupNewerThanEditIsListed() {
        let b = t0.addingTimeInterval(60)
        #expect(make(dirty: true, edit: t0, backup: b).text == "Edited · Backup 08:01")
        #expect(make(dirty: true, edit: t0, backup: t0).text == "Edited · Backup 08:00")
    }

    @Test func backupOlderThanEditIsNotListed() {
        #expect(make(dirty: true, edit: t0.addingTimeInterval(5), backup: t0).text == "Edited")
    }

    @Test func clockUsesEnglishTwentyFourHour() {
        let b = t0.addingTimeInterval(6 * 3600 + 32 * 60)
        #expect(make(dirty: true, edit: t0, backup: b).text == "Edited · Backup 14:32")
    }

    @Test func neverSavedProject() {
        #expect(make(dirty: false, file: false).text == "No changes")
        #expect(make(dirty: true, file: false, edit: t0).text == "Not saved")
        #expect(make(dirty: true, file: false, edit: t0, backup: t0).text == "Not saved · Backup 08:00")
    }
}
