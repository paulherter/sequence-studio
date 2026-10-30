import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct ShellDailyDriverTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-sdd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func restoringAVersionGivesTheSameProject() async throws {
        let dir = tempDir()
        var p = EditorSession.makeUntitled()
        p.add(MediaRef(name: "A.mov", path: "/x/A.mov", fingerprint: MediaFingerprint(size: 1)))
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
        s.perform("Edit") { $0.name = "First" }
        #expect(await s.tickAutosave())
        let saved = s.project
        let version = try #require(s.autosaveVersions.first)
        s.perform("Edit 2") { $0.name = "Second" }
        #expect(s.project != saved)
        try s.restoreAutosave(version)
        #expect(s.project == saved)
        #expect(s.project.hashValue == saved.hashValue)
        #expect(s.undoName == "Restore Autosave Version")
        s.undo()
        #expect(s.project.name == "Second")
    }

    @Test func relinkingAMovedFileDuringTheSession() async throws {
        let dir = tempDir()
        let moved = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let file = moved.appendingPathComponent("B.mov")
        try Data(count: 10).write(to: file)
        var p = EditorSession.makeUntitled()
        let m = MediaRef(name: "B.mov", path: dir.appendingPathComponent("gone/B.mov").path, fingerprint: MediaFingerprint(size: 10))
        p.add(m)
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir.appendingPathComponent("as")))
        #expect(s.canRelink)
        let r = await s.relinkMissing(searching: dir)
        #expect(r.relinked == 1 && r.offline == 1 && r.sizeDiffers == 0)
        #expect(s.project.media(m.id).map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == file.resolvingSymlinksInPath().path)
        #expect(!s.canRelink)
    }

    @Test func locateSeveralFoldersWithWindowsStoredPaths() async throws {
        // Premiere placeholders: size unknown (0), path from a Windows machine. Second folder finds the rest.
        let a = tempDir(), b = tempDir()
        try Data(count: 3).write(to: a.appendingPathComponent("C2117.mp4"))
        try FileManager.default.createDirectory(at: b.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
        try Data(count: 3).write(to: b.appendingPathComponent("deep/er/c2116.MP4"))
        var p = EditorSession.makeUntitled()
        let m1 = MediaRef(name: "C2117", path: "D:\\S112 x2\\C2117.mp4", fingerprint: MediaFingerprint(size: 0))
        let m2 = MediaRef(name: "C2116", path: "/Volumes/T7/S112 x2/C2116.mp4", fingerprint: MediaFingerprint(size: 0))
        p.add(m1); p.add(m2)
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let r1 = await s.relinkMissing(searching: [a])
        #expect(r1.relinked == 1 && r1.offline == 2 && s.missingMedia.map(\.id) == [m2.id])
        let r2 = await s.relinkMissing(searching: [a, b])
        #expect(r2.relinked == 1 && r2.offline == 1 && s.missingMedia.isEmpty)
    }

    @Test func closeProjectGivesAnEmptyUntitledProject() {
        let s = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(),
                              autosaveStore: AutosaveStore(base: tempDir()))
        s.perform("Edit") { $0.name = "X" }
        s.closeProject()
        #expect(s.fileURL == nil && !s.isDirty)
        #expect(s.activeTimeline == nil && s.project.timelines.isEmpty && s.sequenceTabs.tabs.isEmpty && s.isEmptyUntitled)
    }

    @Test func aFileWithAnotherSizeIsNotRelinked() async throws {
        let dir = tempDir()
        try Data(count: 10).write(to: dir.appendingPathComponent("A001.mov"))
        var p = EditorSession.makeUntitled()
        let m = MediaRef(name: "A001.mov", path: "/gone/A001.mov", fingerprint: MediaFingerprint(size: 5_000_000_000))
        p.add(m)
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir.appendingPathComponent("as")))
        let r = await s.relinkMissing(searching: dir)
        #expect(r.relinked == 0 && r.sizeDiffers == 1)
        #expect(s.project.media(m.id)?.path == "/gone/A001.mov")
    }

    @Test func projectReplacedDuringTheScanAppliesNothing() async throws {
        let dir = tempDir()
        try Data(count: 10).write(to: dir.appendingPathComponent("B.mov"))
        var p = EditorSession.makeUntitled()
        p.add(MediaRef(name: "B.mov", path: "/gone/B.mov", fingerprint: MediaFingerprint(size: 10)))
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir.appendingPathComponent("as")))
        async let r = s.relinkMissing(searching: dir)
        s.closeProject()          // runs while the scan is suspended
        let out = await r
        #expect(out.relinked == 0)
        #expect(s.project.media.isEmpty)
    }

    @Test func emptyUntitledProjectCannotBeClosed() {
        let s = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(s.isEmptyUntitled)
        s.perform("Edit") { $0.name = "X" }
        #expect(!s.isEmptyUntitled)
    }
}
