import Foundation
import Testing
import SQCore
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite(.serialized) struct ShellCollectTests {
    let root: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-collect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    @Test func collectCopiesOutsideMediaIntoImportedAndRepointsTheProject() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Camera/a.wav")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: source)
        let media = MediaRef(name: "a.wav", path: source.path, fingerprint: MediaFingerprint(size: 4))
        let s = ShellRecoveryTests.session(Project(name: "P", media: [media]))
        let h = ShellHost(session: s, map: .premiereDefault)
        var status: [String] = []
        h.onStatus = { status.append($0) }
        let project = root.appendingPathComponent("Proj/Proj.sqproj")
        await h.collectFiles(projectURL: project)
        let copy = MediaManagement.importedFolder(forProjectAt: project).appendingPathComponent("a.wav")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(s.project.media(media.id)?.path == copy.path)
        #expect(FileManager.default.fileExists(atPath: source.path))        // the original stays
        #expect(status.last?.hasPrefix("Collected 1 files into") == true)
        #expect(!s.canUndo)                                                    // not an undo step
        await h.collectFiles(projectURL: project)
        #expect(status.last == "All media is already in the project folder.")
    }

    @Test func anUntitledProjectAsksForASaveFirst() async {
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        var status: [String] = []
        h.onStatus = { status.append($0) }
        await h.collectFiles(unsaved: true)
        #expect(status.isEmpty)           // the error goes to the dialog, not the status line
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        #expect(h.dialog?.messageText == "Save the project first")
    }
}
