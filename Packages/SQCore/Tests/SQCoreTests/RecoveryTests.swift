import Foundation
import Testing
@testable import SQCore

@Suite struct RecoveryTests {
    let fm = FileManager.default

    func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("sqrec-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + s) }

    // MARK: Policy

    @Test func policyOnlyWhenDirtyAndIntervalElapsed() {
        let p = AutosavePolicy()
        #expect(p.interval == 300 && p.keep == 10)
        #expect(!p.shouldAutosave(isDirty: false, lastAutosave: nil, now: t(0)))
        #expect(p.shouldAutosave(isDirty: true, lastAutosave: nil, now: t(0)))
        #expect(!p.shouldAutosave(isDirty: true, lastAutosave: t(0), now: t(299)))
        #expect(p.shouldAutosave(isDirty: true, lastAutosave: t(0), now: t(300)))
    }

    // MARK: Store

    @Test func writeListAndRead() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try store.write(p, date: t(0))
        try store.write(p, date: t(10))
        let v = store.versions(for: p.id)
        #expect(v.count == 2)
        #expect(v[0].date > v[1].date)   // newest first
        #expect(abs(v[0].date.timeIntervalSince(t(10))) < 0.01)
        #expect(try store.read(v[0]).name == "P")
    }

    @Test func prunesOldestByCount() throws {
        let store = AutosaveStore(base: try tempDir(), policy: AutosavePolicy(keep: 3))
        let p = Project(name: "P")
        for i in 0..<6 { try store.write(p, date: t(Double(i))) }
        let v = store.versions(for: p.id)
        #expect(v.count == 3)
        #expect(abs(v.last!.date.timeIntervalSince(t(3))) < 0.01)
    }

    @Test func namedCheckpointSurvivesPruneAndIsListed() throws {
        let store = AutosaveStore(base: try tempDir(), policy: AutosavePolicy(keep: 2, maxAge: 100))
        let p = Project(name: "P")
        let cp = try store.write(p, date: t(0), name: "Before / the: re~cut")
        #expect(cp.name == "Before the re cut")
        for i in 1...6 { try store.write(p, date: t(Double(i))) }
        try store.prune(p.id, now: t(100_000))
        let v = store.versions(for: p.id)
        #expect(v.filter { $0.name == nil }.count == 1)       // plain ones pruned (newest stays)
        #expect(v.contains { $0.name == "Before the re cut" })  // named one stays, even older than maxAge
        #expect(try store.read(v.first { $0.name != nil }!).name == "P")
    }

    @Test func namedDoesNotCountTowardsKeep() throws {
        let store = AutosaveStore(base: try tempDir(), policy: AutosavePolicy(keep: 3))
        let p = Project(name: "P")
        try store.write(p, date: t(0), name: "A")
        try store.write(p, date: t(1), name: "B")
        for i in 2..<8 { try store.write(p, date: t(Double(i))) }
        let v = store.versions(for: p.id)
        #expect(v.filter { $0.name != nil }.count == 2)
        #expect(v.filter { $0.name == nil }.count == 3)
    }

    @Test func blankNameIsPlainAutosave() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        let v = try store.write(p, date: t(0), name: "  / : ")
        #expect(v.name == nil)
    }

    @Test func prunesByAgeButKeepsNewest() throws {
        let store = AutosaveStore(base: try tempDir(), policy: AutosavePolicy(keep: 10, maxAge: 100))
        let p = Project(name: "P")
        try store.write(p, date: t(0))
        try store.write(p, date: t(50))
        try store.write(p, date: t(1000))   // others are now older than 100 s
        #expect(store.versions(for: p.id).count == 1)
        // Newest survives even when itself too old.
        try store.prune(p.id, now: t(100_000))
        #expect(store.versions(for: p.id).count == 1)
    }

    @Test func failedWriteLeavesNoPartialFile() throws {
        struct Boom: Error {}
        let base = try tempDir()
        let p = Project(name: "P")
        let good = AutosaveStore(base: base)
        try good.write(p, date: t(0))
        let bad = AutosaveStore(base: base, writer: { project, url in
            try ProjectFile.write(project, to: url)
            throw Boom()   // fails after data reached the temp location
        })
        #expect(throws: Boom.self) { try bad.write(p, date: t(5)) }
        #expect(bad.versions(for: p.id).count == 1)
        let items = try fm.contentsOfDirectory(atPath: base.appendingPathComponent(p.id.uuidString).path)
        #expect(items.allSatisfy { !$0.hasSuffix(".tmp") })
        #expect(items.filter { $0.hasSuffix(".sqproj") }.count == 1)
    }

    // MARK: Crash detection

    @Test func cleanCloseLeavesNoCandidate() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        let marker = SessionMarker(store: store)
        try marker.begin(projectID: p.id, projectURL: nil, projectName: p.name, pid: 1, date: t(0))
        try store.write(p, date: t(10))
        marker.end(projectID: p.id, pid: 1)
        #expect(RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan().isEmpty)
    }

    @Test func markerLeftAfterCrashGivesCandidate() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(10))
        let found = RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan()
        #expect(found.count == 1)
        #expect(found[0].projectID == p.id)
        #expect(found[0].projectName == "P")
    }

    @Test func liveProcessIsNotACrash() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 42, date: t(0))
        try store.write(p, date: t(10))
        #expect(RecoveryScanner(store: store, isProcessAlive: { $0 == 42 }).scan().isEmpty)
    }

    @Test func autosaveOlderThanSavedFileIsNotCandidate() throws {
        let base = try tempDir()
        let store = AutosaveStore(base: base)
        let p = Project(name: "P")
        let proj = base.appendingPathComponent("P.sqproj")
        try ProjectFile.write(p, to: proj)
        try fm.setAttributes([.modificationDate: t(100)],
                             ofItemAtPath: proj.appendingPathComponent("project.json").path)
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: proj, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(50))
        let scanner = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        #expect(scanner.scan().isEmpty)
        // The first scan consumed the dead marker (it was reported once); a later crash writes a new one.
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: proj, projectName: "P", pid: 2, date: t(120))
        try store.write(p, date: t(150))
        #expect(scanner.scan().count == 1)
    }

    @Test func markerLifecycleReportsACrashOnlyOnce() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        let dead = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        // start -> clean quit -> next start: no crash.
        let m = SessionMarker(store: store)
        try m.begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(10))
        m.end(projectID: p.id, pid: 1)
        #expect(dead.scanSessions().crashed.isEmpty)
        // start -> no clean quit -> next start reports the crash, the one after does not.
        try m.begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 2, date: t(20))
        let first = dead.scanSessions()
        #expect(first.crashed.count == 1)
        dead.markReported(first.crashed)
        #expect(dead.scanSessions().crashed.isEmpty)
        #expect(dead.scan().count == 1)   // still offered for recovery until dismissed
    }

    @Test func crashWithSavedFileIsReportedOnceAndMarkerRemoved() throws {
        let base = try tempDir()
        let store = AutosaveStore(base: base)
        let p = Project(name: "P")
        let proj = base.appendingPathComponent("P.sqproj")
        try ProjectFile.write(p, to: proj)
        try fm.setAttributes([.modificationDate: t(100)], ofItemAtPath: proj.appendingPathComponent("project.json").path)
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: proj, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(50))
        let scanner = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        #expect(scanner.scanSessions().crashed.count == 1)
        #expect(scanner.scanSessions().crashed.isEmpty)   // not reported again at every launch
    }

    @Test func candidatesOrderedNewestFirst() throws {
        let store = AutosaveStore(base: try tempDir())
        let a = Project(name: "A"), b = Project(name: "B")
        for (p, d) in [(a, 10.0), (b, 20.0)] {
            try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: p.name, pid: 1, date: t(0))
            try store.write(p, date: t(d))
        }
        let found = RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan()
        #expect(found.map(\.projectName) == ["B", "A"])
    }

    @Test func recoverKeepsIDAndName() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(10))
        let scanner = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        let copy = try scanner.recover(scanner.scan()[0])
        #expect(copy.id == p.id)
        #expect(copy.name == "P")
    }

    @Test func markerWithoutAutosaveIsNoCandidate() throws {
        let store = AutosaveStore(base: try tempDir())
        try SessionMarker(store: store).begin(projectID: UUID(), projectURL: nil, projectName: "P", pid: 1, date: t(0))
        #expect(RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan().isEmpty)
    }

    // MARK: Review fixes

    @Test func markersPerPidCoexistAndEndRemovesOnlyOwn() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        let m = SessionMarker(store: store)
        try m.begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try m.begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 2, date: t(0))
        #expect(m.infos(projectID: p.id).count == 2)
        m.end(projectID: p.id, pid: 1)
        #expect(m.infos(projectID: p.id).map(\.pid) == [2])
    }

    @Test func liveSessionBlocksCrashOfOtherSession() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        let m = SessionMarker(store: store)
        try m.begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try m.begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 2, date: t(0))
        try store.write(p, date: t(10))
        // pid 1 dead, pid 2 alive and open: not a crash yet.
        #expect(RecoveryScanner(store: store, isProcessAlive: { $0 == 2 }).scan().isEmpty)
        // pid 2 closes cleanly; pid 1's stale marker remains -> candidate.
        m.end(projectID: p.id, pid: 2)
        #expect(RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan().count == 1)
    }

    @Test func reusedPidWithDifferentStartTimeIsDead() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P",
                                              pid: 42, date: t(0), processStart: t(0))
        try store.write(p, date: t(10))
        let other = t(5000), same = t(0)
        let reused = RecoveryScanner(store: store, isProcessAlive: { _ in true }, processStart: { _ in other })
        #expect(reused.scan().count == 1)
        let alive = RecoveryScanner(store: store, isProcessAlive: { _ in true }, processStart: { _ in same })
        #expect(alive.scan().isEmpty)
    }

    @Test func systemStartTimeOfOwnProcessIsStable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(SessionMarker.startTime(of: pid) != nil)
        #expect(SessionMarker.startTime(of: pid) == SessionMarker.startTime(of: pid))
    }

    @Test func writingOlderDateNeverPrunesJustWrittenVersion() throws {
        let store = AutosaveStore(base: try tempDir(), policy: AutosavePolicy(keep: 2))
        let p = Project(name: "P")
        try store.write(p, date: t(100))
        try store.write(p, date: t(200))
        let v = try store.write(p, date: t(0))   // older than everything
        #expect(fm.fileExists(atPath: v.url.path))
        #expect(store.versions(for: p.id).contains { $0.url.lastPathComponent == v.url.lastPathComponent })
    }

    @Test func pruneRemovesOrphanedTmpDirsOlderThanOneHour() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try store.write(p, date: t(0))
        let dir = store.folder(for: p.id)
        let old = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fresh = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        for u in [old, fresh] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        try TestFileSystem.setModificationDate(t(0), of: old.path)
        try TestFileSystem.setModificationDate(t(7000), of: fresh.path)
        try store.prune(p.id, now: t(7200))
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    // MARK: Launch scan cost (stale markers piled up to 60k folders and blocked launch for 8 s)

    @Test func scanRemovesFoldersHoldingOnlyDeadMarkers() throws {
        let store = AutosaveStore(base: try tempDir())
        let marker = SessionMarker(store: store)
        let dead = UUID(), alive = UUID(), withVersion = UUID(), foreign = UUID()
        try marker.begin(projectID: dead, projectURL: nil, projectName: "Dead", pid: 1, date: t(0))
        try marker.begin(projectID: alive, projectURL: nil, projectName: "Alive", pid: 2, date: t(0))
        var p = Project(name: "Crashed"); p.id = withVersion
        try marker.begin(projectID: withVersion, projectURL: nil, projectName: "Crashed", pid: 1, date: t(0))
        try store.write(p, date: t(10))
        try marker.begin(projectID: foreign, projectURL: nil, projectName: "Other", pid: 1, date: t(0))
        try Data("x".utf8).write(to: store.folder(for: foreign).appendingPathComponent("notes.txt"))
        let found = RecoveryScanner(store: store, isProcessAlive: { $0 == 2 }).scan()
        #expect(found.map(\.projectID) == [withVersion])
        #expect(!fm.fileExists(atPath: store.folder(for: dead).path))                  // nothing to recover: gone
        #expect(marker.infos(projectID: alive).count == 1)                             // a running session keeps its marker
        #expect(marker.infos(projectID: withVersion).count == 1)                       // a candidate is never touched
        #expect(marker.infos(projectID: foreign).isEmpty)                              // dead marker dropped ...
        #expect(fm.fileExists(atPath: store.folder(for: foreign).appendingPathComponent("notes.txt").path))  // ... other files stay
    }

    @Test func cleanEndRemovesTheEmptyProjectFolder() throws {
        let store = AutosaveStore(base: try tempDir())
        let marker = SessionMarker(store: store)
        let id = UUID()
        try marker.begin(projectID: id, projectURL: nil, projectName: "U", pid: 1, date: t(0))
        try marker.begin(projectID: id, projectURL: nil, projectName: "U", pid: 2, date: t(0))
        marker.end(projectID: id, pid: 1)
        #expect(fm.fileExists(atPath: store.folder(for: id).path))     // another session's marker is still there
        marker.end(projectID: id, pid: 2)
        #expect(!fm.fileExists(atPath: store.folder(for: id).path))
    }

    @Test func scanRemovesOnlyOldEmptyFolders() throws {
        let store = AutosaveStore(base: try tempDir())
        let old = store.folder(for: UUID()), fresh = store.folder(for: UUID())
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try TestFileSystem.setModificationDate(Date().addingTimeInterval(-7200), of: old.path)
        #expect(RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan().isEmpty)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))      // may be a session that is just writing its marker
    }

    @Test func scanOfManyStaleFoldersIsFastAndLeavesNothing() throws {
        let store = AutosaveStore(base: try tempDir())
        let marker = SessionMarker(store: store)
        for _ in 0..<2000 { try marker.begin(projectID: UUID(), projectURL: nil, projectName: "U", pid: 1, date: t(0)) }
        let scanner = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        #expect(scanner.scan().isEmpty)
        #expect(((try? fm.contentsOfDirectory(atPath: store.base.path)) ?? []).isEmpty)
        let best = SQTiming.bestMs(runs: 5) { _ = scanner.scan() }
        #expect(scanner.scan().isEmpty)
        #expect(best < SQTiming.budget(50), "best scan \(best) ms")
    }

    @Test func testProcessesNeverWriteIntoTheUsersAutosaveFolder() {
        // Test runs create thousands of sessions; their crash markers must not land in ~/Library/Application Support.
        #expect(!AutosaveStore.defaultBase.path.contains("/Library/Application Support/"))
    }
}
