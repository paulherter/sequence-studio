import Foundation
import Testing
@testable import SQCore

@Suite struct CrashReportTests {
    let fm = FileManager.default
    func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("sqcrash-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + s) }

    @Test func crashedSessionIsFoundEvenWithoutAutosave() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        let r = RecoveryScanner(store: store, isProcessAlive: { _ in false }).scanSessions()
        #expect(r.candidates.isEmpty)
        #expect(r.crashed.count == 1)
        #expect(r.crashed[0].autosave == nil)
        #expect(r.crashed[0].info.projectName == "P")
    }

    @Test func cleanCloseAndLiveSessionAreNotCrashes() throws {
        let store = AutosaveStore(base: try tempDir())
        let a = Project(name: "A"), b = Project(name: "B")
        let m = SessionMarker(store: store)
        try m.begin(projectID: a.id, projectURL: nil, projectName: "A", pid: 1, date: t(0)); m.end(projectID: a.id, pid: 1)
        try m.begin(projectID: b.id, projectURL: nil, projectName: "B", pid: 2, date: t(0))
        #expect(RecoveryScanner(store: store, isProcessAlive: { _ in true }, processStart: { _ in nil }).scanSessions().crashed.isEmpty)
    }

    @Test func crashedSessionCarriesNewestAutosave() throws {
        let store = AutosaveStore(base: try tempDir())
        let p = Project(name: "P")
        try SessionMarker(store: store).begin(projectID: p.id, projectURL: nil, projectName: "P", pid: 1, date: t(0))
        try store.write(p, date: t(10)); try store.write(p, date: t(20))
        let r = RecoveryScanner(store: store, isProcessAlive: { _ in false }).scanSessions()
        #expect(r.crashed.first?.autosave?.date == t(20))
    }

    @Test func summaryHasCountsAndNamesButNoPaths() {
        var p = Project(name: "Wedding")
        p.media = [MediaRef(name: "a.mov", path: "/Users/someone/Movies/a.mov", fingerprint: MediaFingerprint(size: 1))]
        let text = CrashReport.stateSummary(of: p).joined(separator: "\n")
        #expect(text.contains("Wedding"))
        #expect(text.contains("a.mov"))
        #expect(text.contains("media items: 1"))
        #expect(!text.contains("/Users/someone"))
    }

    @Test func redactsHomeFolderInLogLines() {
        #expect(CrashReport.redact("open /Users/me/Movies/x.mov", home: "/Users/me") == "open ~/Movies/x.mov")
    }

    @Test func logTailTakesLastLinesAcrossFilesInOrder() throws {
        let d = try tempDir()
        let cur = d.appendingPathComponent("sq.log"), old = d.appendingPathComponent("sq.1.log")
        try "c1\nc2\n".write(to: cur, atomically: true, encoding: .utf8)
        try "o1\no2\no3\n".write(to: old, atomically: true, encoding: .utf8)
        #expect(CrashReport.logTail(files: [cur, old], count: 3) == ["o3", "c1", "c2"])
        #expect(CrashReport.logTail(files: [d.appendingPathComponent("none.log")], count: 3).isEmpty)
    }

    @Test func renderContainsSessionStateAndRedactedLog() {
        let info = SessionMarker.Info(pid: 9, started: Date(timeIntervalSince1970: 0), projectName: "P",
                                      projectPath: "/x/P.sqproj", processStart: nil)
        let s = CrashedSession(projectID: UUID(), info: info, autosave: nil)
        let text = CrashReport.render(session: s, project: Project(name: "P"), log: ["err /Users/me/a"], appVersion: "1.0 (5)",
                                      os: "macOS 27", systemReport: "Sequence Studio-2026.ips", home: "/Users/me")
        #expect(text.contains("app: 1.0 (5)"))
        #expect(text.contains("project open: P"))
        #expect(text.contains("err ~/a"))
        #expect(!text.contains("/Users/me"))
        #expect(!text.contains("/x/P.sqproj"))
        #expect(text.contains("Sequence Studio-2026.ips"))
    }

    @Test func storeWritesAndKeepsNewestOnly() throws {
        let store = CrashReportStore(directory: try tempDir(), keep: 2)
        for i in 0..<4 { try store.write("r\(i)", date: t(Double(i))) }
        let r = store.reports()
        #expect(r.count == 2)
        #expect(try String(contentsOf: r[0], encoding: .utf8) == "r3")
    }
}
