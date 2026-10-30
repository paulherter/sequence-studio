import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Opening a project copied from another machine: media next to the project file is linked again without an undo step.
@Suite @MainActor struct RelinkNearProjectTests {
    @Test func copiedProjectLinksTheFilesBesideItQuietly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SQNear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Files/Imported/C2171.MP4")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 12).write(to: file)
        var p = EditorSession.makeUntitled()
        let found = MediaRef(name: "C2171.MP4", path: "/Users/me/Oppo/Files/Imported/C2171.MP4",
                             fingerprint: MediaFingerprint(size: 12))
        let gone = MediaRef(name: "gone.mov", path: "/Users/me/Oppo/Media/gone.mov", fingerprint: MediaFingerprint(size: 3))
        p.add(found); p.add(gone)
        let s = EditorSession(project: p, fileURL: root.appendingPathComponent("Oppo.sqproj"))
        #expect(await s.relinkNearProject() == 1)
        #expect(s.project.media(found.id)?.path == file.standardizedFileURL.path)
        #expect(s.missingMedia.map(\.id) == [gone.id])
        #expect(!s.canUndo)                          // a background repair, not an edit
        #expect(await s.relinkNearProject() == 0)    // nothing more beside the project
    }

    @Test func untitledProjectHasNoFolderToSearch() async {
        var p = EditorSession.makeUntitled()
        p.add(MediaRef(name: "a.mov", path: "/Users/x/a.mov", fingerprint: MediaFingerprint(size: 1)))
        let s = EditorSession(project: p)
        #expect(await s.relinkNearProject() == 0)
    }
}
