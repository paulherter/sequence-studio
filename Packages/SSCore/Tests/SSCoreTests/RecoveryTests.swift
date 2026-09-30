import Foundation
import Testing
@testable import SSCore

@Suite struct RecoveryTests {
    let fm = FileManager.default

    func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("ssrec-\(UUID().uuidString)")
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
        #expect(items.filter { $0.hasSuffix(".ssproj") }.count == 1)
    }

    // MARK: Crash detection

    @Test func cleanCloseLeavesNoCandidate() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        let marker = SessionMarker(store: store)
        try marker.begin(projectID: p.id, projectURL: nil, projectName: p.name, pid: 1, date: t(0))
        try store.write(p, date: t(10))
        marker.end(projectID: p.id)
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
        let proj = base.appendingPathComponent("P.ssproj")
        try ProjectFile.write(p, to: proj)
        try fm.setAttributes([.modificationDate: t(100)],
                             ofItemAtPath: proj.appendingPathComponent("project.json").path)
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: proj, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(50))
        let scanner = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        #expect(scanner.scan().isEmpty)
        try store.write(p, date: t(150))
        #expect(scanner.scan().count == 1)
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

    @Test func recoverYieldsUntitledCopyWithNewID() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(10))
        let scanner = RecoveryScanner(store: store, isProcessAlive: { _ in false })
        let copy = try scanner.recover(scanner.scan()[0])
        #expect(copy.id != p.id)
        #expect(copy.name == "P (Recovered)")
    }

    @Test func markerWithoutAutosaveIsNoCandidate() throws {
        let store = AutosaveStore(base: try tempDir())
        try SessionMarker(store: store).begin(projectID: UUID(), projectURL: nil, projectName: "P", pid: 1, date: t(0))
        #expect(RecoveryScanner(store: store, isProcessAlive: { _ in false }).scan().isEmpty)
    }
}
