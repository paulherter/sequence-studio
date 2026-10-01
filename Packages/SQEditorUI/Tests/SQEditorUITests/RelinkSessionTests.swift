import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct RelinkSessionTests {
    @Test func relinkMovesOfflineMediaAndIsUndoable() throws {
        var p = EditorSession.makeUntitled()
        let m = MediaRef(name: "A.mov", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1))
        p.add(m)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-rl-\(UUID().uuidString)")
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
        #expect(s.missingMedia.map(\.id) == [m.id])
        s.relinkMedia([m.id: "/elsewhere/A.mov"])
        #expect(s.project.media(m.id)?.path == "/elsewhere/A.mov")
        #expect(s.undoName == "Relink Media")
        s.undo()
        #expect(s.project.media(m.id)?.path == "/nonexistent/A.mov")
    }
}
