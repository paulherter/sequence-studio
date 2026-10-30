import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// A matte file whose removal was decided is deleted even when the app ended before the store's queue got to it,
/// and nothing else in or outside the matte folder is touched (`MatteRemovalJournal`).
@Suite struct MatteRemovalJournalTests {
    static let matte = SubjectMatte(width: 1, height: 1, values: [1])

    private func folder() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sq-journal-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("MagicMattes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func list(_ dir: URL) -> URL { dir.appendingPathComponent(MatteRemovalJournal.fileName) }
    /// A journal line for `key`, listed a minute after now (its file is older) or an hour ago (its file is newer).
    private func line(_ key: String, fileIsNewer: Bool = false) -> String {
        "\(key)\t\(Date().timeIntervalSince1970 + (fileIsNewer ? -3600 : 60))"
    }

    /// A store with the files of `keys` written.
    private func store(_ dir: URL, keys: [String]) -> MagicMatteStore {
        let store = MagicMatteStore(directory: dir)
        for k in keys { store.put(Self.matte, key: k, pts: 0); store.save(key: k) }
        store.waitForSaves()
        return store
    }

    @Test func aSweepThatGoesThroughLeavesNoList() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = store(dir, keys: ["kept", "gone"])
        let journal = MatteRemovalJournal(directory: dir)
        #expect(journal.sweep(store, keeping: ["kept"]) == ["gone"])
        journal.waitForSettle()
        #expect(!exists(dir.appendingPathComponent("gone.sqmatte")) && exists(dir.appendingPathComponent("kept.sqmatte")))
        #expect(!exists(list(dir)))
        #expect(MatteRemovalJournal(directory: dir).leftover.isEmpty)
    }

    @Test func aRemovedKeyIsStruckOutOnceItsFileIsGone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = store(dir, keys: ["a"])
        let journal = MatteRemovalJournal(directory: dir)
        journal.remove("a", from: store)
        journal.waitForSettle()
        #expect(!exists(dir.appendingPathComponent("a.sqmatte")) && !exists(list(dir)))
    }

    /// The app ended between the removal and the queued delete: the list names the key, its file is still there.
    @Test func theNextProjectOpenDeletesWhatAnEarlyEndLeft() throws {
        let dir = try folder()
        let base = dir.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = store(dir, keys: ["orphan", "inProject", "unlisted"])
        // Listed lines that must never delete anything: a path, a name with a dot, a key without a file.
        let outside = base.appendingPathComponent("outside.sqmatte")
        try Data([1]).write(to: outside)
        let nested = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("deep.sqmatte"))
        try Data([1]).write(to: dir.appendingPathComponent("notes.txt"))
        try Data((["orphan", "inProject", "../outside", "sub/deep", "notes.txt", "noFile"].map { line($0) } + ["unlisted", ""])
            .joined(separator: "\n").utf8).write(to: list(dir))

        let journal = MatteRemovalJournal(directory: dir)
        #expect(journal.leftover == ["orphan", "inProject", "noFile"])
        #expect(journal.sweepLeftover(keeping: ["inProject"]) == ["orphan"])
        #expect(!exists(dir.appendingPathComponent("orphan.sqmatte")))
        #expect(exists(dir.appendingPathComponent("inProject.sqmatte")) && exists(dir.appendingPathComponent("unlisted.sqmatte")))
        #expect(exists(outside) && exists(nested.appendingPathComponent("deep.sqmatte")) && exists(dir.appendingPathComponent("notes.txt")))
        #expect(!exists(list(dir)) && journal.leftover.isEmpty)
        // Once per process: a second open sweeps nothing.
        #expect(journal.sweepLeftover(keeping: []).isEmpty && exists(dir.appendingPathComponent("unlisted.sqmatte")))
    }

    /// A list of a process that still runs (a second app instance) is not adopted; a dead process's is.
    @Test func aRunningInstancesListIsNotAdopted() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        _ = store(dir, keys: ["live", "dead"])
        let liveList = dir.appendingPathComponent("\(MatteRemovalJournal.fileName).\(getppid())")
        let deadList = dir.appendingPathComponent("\(MatteRemovalJournal.fileName).2000000000")
        try Data(line("live").utf8).write(to: liveList)
        try Data(line("dead").utf8).write(to: deadList)
        let journal = MatteRemovalJournal(directory: dir)
        #expect(journal.leftover == ["dead"])
        #expect(exists(liveList) && !exists(deadList))
        #expect(journal.sweepLeftover(keeping: []) == ["dead"])
        #expect(exists(dir.appendingPathComponent("live.sqmatte")) && exists(liveList))
    }

    /// Keys listed by the last process stay listed while this one notes its own, until the sweep.
    @Test func leftoverKeysSurviveLaterNotes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = store(dir, keys: ["old", "new"])
        try Data(line("old").utf8).write(to: list(dir))
        let journal = MatteRemovalJournal(directory: dir)
        journal.remove("new", from: store)
        journal.waitForSettle()
        #expect(MatteRemovalJournal(directory: dir).leftover == ["old"])
        #expect(journal.sweepLeftover(keeping: []) == ["old"])
        #expect(!exists(list(dir)))
    }

    /// A key listed for removal whose pick was made again: the store wrote its frames after the listing, the app
    /// ended before the key was struck out. The next launch drops the key and leaves the file, whatever project opens.
    @Test func aFileWrittenAfterItsKeyWasListedStays() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = store(dir, keys: ["again"])
        let crashed = MatteRemovalJournal(directory: dir)
        crashed.note(["again"])
        store.put(Self.matte, key: "again", pts: 1)
        store.save(key: "again")
        store.waitForSaves()
        let next = MatteRemovalJournal(directory: dir)
        #expect(next.leftover == ["again"])
        #expect(next.sweepLeftover(keeping: []).isEmpty)
        #expect(exists(dir.appendingPathComponent("again.sqmatte")) && !exists(list(dir)))
        // The same from a written list: only the file older than its listing goes; a line without a time lists nothing.
        _ = self.store(dir, keys: ["old", "bare"])
        try Data([line("again", fileIsNewer: true), line("old"), "bare"].joined(separator: "\n").utf8).write(to: list(dir))
        let third = MatteRemovalJournal(directory: dir)
        #expect(third.leftover == ["again", "old"])
        #expect(third.sweepLeftover(keeping: []) == ["old"])
        #expect(exists(dir.appendingPathComponent("again.sqmatte")) && exists(dir.appendingPathComponent("bare.sqmatte")))
    }

    /// Removed and made again within one session: once the store's queue is through, nothing is listed.
    @Test func aKeyMadeAgainIsStruckOutWithItsFileKept() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = store(dir, keys: ["a"])
        let journal = MatteRemovalJournal(directory: dir)
        journal.remove("a", from: store)
        store.put(Self.matte, key: "a", pts: 2)
        store.save(key: "a")
        journal.waitForSettle()
        store.waitForSaves()
        journal.waitForSettle()
        #expect(exists(dir.appendingPathComponent("a.sqmatte")) && !exists(list(dir)))
    }

    @Test func aMemoryOnlyStoreWritesNothing() {
        let journal = MatteRemovalJournal(directory: nil)
        let store = MagicMatteStore(directory: nil)
        store.put(Self.matte, key: "a", pts: 0)
        journal.remove("a", from: store)
        journal.waitForSettle()
        #expect(store.times(key: "a").isEmpty && journal.sweepLeftover(keeping: []).isEmpty)
    }

    @Test func onlyStoreKeysCount() {
        #expect(MatteRemovalJournal.isKey("3fa9-b_C") && !MatteRemovalJournal.isKey("../a") && !MatteRemovalJournal.isKey("a.b")
                && !MatteRemovalJournal.isKey("") && !MatteRemovalJournal.isKey("a/b"))
    }
}
