import Foundation
import Testing
import SQCore
@testable import SQEditorSession

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

    @Test func quietRelinkAddsNoStepKeepsRedoAndFixesAllSnapshots() throws {
        var p = EditorSession.makeUntitled()
        let m = MediaRef(name: "A.mov", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1))
        p.add(m)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-rl-\(UUID().uuidString)")
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
        s.perform("Edit One") { $0.name = "One" }
        s.perform("Edit Two") { $0.name = "Two" }
        s.undo()
        #expect(s.canRedo)
        s.relinkMediaQuietly([m.id: "/inside/A.mov"])
        #expect(s.canRedo)
        #expect(s.undoName == "Edit One")
        #expect(s.isDirty)
        s.undo()
        #expect(s.project.media(m.id)?.path == "/inside/A.mov")
        s.redo(); s.redo()
        #expect(s.project.media(m.id)?.path == "/inside/A.mov")
    }

    @Test func locateOneFileRelinksOnlyThatItemAndOffersSiblingsInTheSameFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-loc-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 7).write(to: dir.appendingPathComponent("A.mov"))
        try Data(count: 9).write(to: dir.appendingPathComponent("B.mov"))
        try Data(count: 5).write(to: sub.appendingPathComponent("C.mov"))      // below the folder: not offered
        var p = EditorSession.makeUntitled()
        let a = MediaRef(name: "A.mov", path: "/gone/A.mov", fingerprint: MediaFingerprint(size: 7))
        let b = MediaRef(name: "B.mov", path: "/gone/B.mov", fingerprint: MediaFingerprint(size: 9))
        let c = MediaRef(name: "C.mov", path: "/gone/C.mov", fingerprint: MediaFingerprint(size: 5))
        for m in [a, b, c] { p.add(m) }
        let s = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir.appendingPathComponent("as")))
        #expect(s.locateMedia(a.id, at: dir.appendingPathComponent("A.mov")))
        #expect(s.project.media(a.id)?.path == dir.appendingPathComponent("A.mov").path)
        #expect(s.project.media(b.id)?.path == "/gone/B.mov" && s.undoName == "Locate Media")
        let siblings = await s.missingSiblings(in: dir, excluding: a.id)
        #expect(siblings == [b.id: dir.appendingPathComponent("B.mov").standardizedFileURL.path])
        s.relinkSiblings(siblings)
        #expect(s.missingMedia.map(\.id) == [c.id])
        #expect(!s.locateMedia(a.id, at: dir.appendingPathComponent("B.mov")))   // online item: refused
    }
}
