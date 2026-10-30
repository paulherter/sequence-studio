import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@Suite @MainActor struct RelinkOfferTests {
    private func dir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("SQOffer-\(UUID().uuidString)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func media(_ path: String, size: Int64) -> MediaRef {
        MediaRef(name: "a.mov", path: path, fingerprint: MediaFingerprint(size: size), duration: Time(seconds: 1))
    }

    @Test func offerFindsFileInProjectFolderWithoutApplying() async throws {
        let folder = try dir("Project")
        let file = folder.appendingPathComponent("a.mov")
        try Data([1, 2, 3]).write(to: file)
        let m = media("/nonexistent/old/a.mov", size: 3)
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])])
        p.add(m)
        let s = EditorSession(project: p)
        let plan = await s.relinkOffer(projectFolder: folder, extraFolders: [], volumes: [])
        #expect(plan[m.id] == file.standardizedFileURL.path)
        #expect(s.project.media(m.id)?.path == "/nonexistent/old/a.mov")
        #expect(s.applyRelinkOffer(plan) == 1)
        #expect(s.project.media(m.id)?.path == file.standardizedFileURL.path)
        #expect(s.missingMedia.isEmpty)
    }

    @Test func rootsIncludeOldFolderAndExtrasOnce() throws {
        let old = try dir("Old"), extra = try dir("Extra")
        let m = media(old.appendingPathComponent("a.mov").path, size: 1)
        let roots = EditorSession.relinkOfferRoots(missing: [m], volumes: [], projectFolder: nil, extraFolders: [extra, extra])
        #expect(roots.map(\.0.path) == [old.standardizedFileURL.path, extra.standardizedFileURL.path])
    }

    @Test func otherVolumeCounterpartIsSearched() throws {
        let vol = try dir("NEWDISK")
        let shots = vol.appendingPathComponent("Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let m = media("/Volumes/OLDDISK/Shots/a.mov", size: 1)
        let roots = EditorSession.relinkOfferRoots(missing: [m], volumes: [URL(fileURLWithPath: "/Volumes/OLDDISK"), vol],
                                                   projectFolder: nil, extraFolders: [])
        #expect(roots.map(\.0.path) == [shots.standardizedFileURL.path])
    }
}
