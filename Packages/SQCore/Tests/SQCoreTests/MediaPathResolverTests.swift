import Foundation
import Testing
@testable import SQCore

/// Premiere stores absolute paths from other machines/volumes (and sometimes a relative path); the resolver finds the
/// files next to the moved project or in folders the user chose with Locate.
@Suite struct MediaPathResolverTests {
    /// A fresh folder inside a fresh folder: the resolver also searches the parent, which must not be the shared temp dir.
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-resolver-\(UUID().uuidString)/w", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.resolvingSymlinksInPath()
    }

    @discardableResult
    private func file(_ dir: URL, _ rel: String, size: Int = 10) throws -> URL {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: u)
        return u
    }

    private func req(_ stored: String, relative: String? = nil, size: Int64? = nil) -> MediaPathResolver.Request {
        MediaPathResolver.Request(storedPath: stored, relativePath: relative, size: size)
    }

    @Test func fileNameHandlesPosixAndWindowsPaths() {
        #expect(MediaPathResolver.fileName(of: "/Volumes/SSD/Clips/C2117.mp4") == "C2117.mp4")
        #expect(MediaPathResolver.fileName(of: "D:\\Footage\\Day 1\\C2116.MP4") == "C2116.MP4")
        #expect(MediaPathResolver.fileName(of: "\\\\nas\\share\\a.mov") == "a.mov")
        #expect(MediaPathResolver.fileName(of: "C2117.mp4") == "C2117.mp4")
    }

    @Test func storedPathWinsWhenItExists() throws {
        let dir = tempDir()
        let f = try file(dir, "A.mov")
        let hits = MediaPathResolver(projectFolder: dir).resolve([req(f.path)])
        #expect(hits[f.path] == .init(path: f.path, method: .storedPath))
    }

    @Test func mediaNextToTheMovedProjectIsFound() throws {
        // The maintainer's "s112x2": project and both clips in one folder, stored paths from another volume.
        let dir = tempDir().appendingPathComponent("S112 x2", isDirectory: true)
        let a = try file(dir, "C2117.mp4"), b = try file(dir, "C2116.mp4")
        try file(dir, "S112 x2.prproj")
        let r = MediaPathResolver(projectFolder: dir)
        let hits = r.resolve([req("/Volumes/T7/S112 x2/C2117.mp4"), req("/Volumes/T7/S112 x2/C2116.mp4")])
        #expect(hits["/Volumes/T7/S112 x2/C2117.mp4"] == .init(path: a.path, method: .projectFolder))
        #expect(hits["/Volumes/T7/S112 x2/C2116.mp4"] == .init(path: b.path, method: .projectFolder))
    }

    @Test func windowsPathsResolveByFileName() throws {
        let dir = tempDir()
        let a = try file(dir, "Footage/C0001.MP4")
        let hits = MediaPathResolver(projectFolder: dir).resolve([req("E:\\Projekte\\Footage\\C0001.MP4")])
        #expect(hits["E:\\Projekte\\Footage\\C0001.MP4"]?.path == a.path)
    }

    @Test func relativePathIsTriedAgainstTheProjectFolder() throws {
        let root = tempDir()
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let a = try file(root, "Media/x.mov")
        let hits = MediaPathResolver(projectFolder: project).resolve([req("/old/Media/x.mov", relative: "..\\Media\\x.mov")])
        #expect(hits["/old/Media/x.mov"] == .init(path: a.path, method: .relativePath))
    }

    @Test func subfoldersAndTheParentAreSearched() throws {
        let root = tempDir()
        let project = root.appendingPathComponent("Edit", isDirectory: true)
        let deep = try file(project, "a/b/c/deep.mov")
        let sibling = try file(root, "Footage/sib.mov")
        let r = MediaPathResolver(projectFolder: project)
        let hits = r.resolve([req("/x/deep.mov"), req("/x/sib.mov")])
        #expect(hits["/x/deep.mov"]?.path == deep.path)
        #expect(hits["/x/sib.mov"]?.path == sibling.path)
    }

    @Test func locateFoldersAreSearchedLast() throws {
        let project = tempDir(), card = tempDir()
        let a = try file(card, "DCIM/100/clip.mov")
        let hits = MediaPathResolver(projectFolder: project, searchFolders: [card]).resolve([req("/gone/clip.mov")])
        #expect(hits["/gone/clip.mov"] == .init(path: a.path, method: .searchFolder))
    }

    @Test func knownSizeMustMatch() throws {
        let dir = tempDir()
        try file(dir, "A.mov", size: 10)
        let hits = MediaPathResolver(projectFolder: dir).resolve([req("/gone/A.mov", size: 99)])
        #expect(hits.isEmpty)
    }

    @Test func ambiguousNamesPickTheMatchingFolderOrNothing() throws {
        // Camera files repeat names across cards: never guess.
        let dir = tempDir()
        let card2 = try file(dir, "Card2/C0001.MP4")
        try file(dir, "Card1/C0001.MP4")
        let r = MediaPathResolver(projectFolder: dir)
        #expect(r.resolve([req("/Volumes/X/Card2/C0001.MP4")])["/Volumes/X/Card2/C0001.MP4"]?.path == card2.path)
        #expect(r.resolve([req("/Volumes/X/Other/C0001.MP4")]).isEmpty)
    }

    @Test func nameMatchIsCaseInsensitive() throws {
        let dir = tempDir()
        let a = try file(dir, "c2117.MP4")
        #expect(MediaPathResolver(projectFolder: dir).resolve([req("/gone/C2117.mp4")])["/gone/C2117.mp4"]?.path == a.path)
    }

    // MARK: Locate scan

    @Test func scanFindsWantedNamesRecursivelyInSeveralFolders() throws {
        let a = tempDir(), b = tempDir()
        try file(a, "x/y/z/one.mov", size: 5)
        try file(b, "two.MOV", size: 7)
        try file(b, "other.mov")
        let found = RelinkScanner.scan(folders: [a, b], named: ["one.mov", "two.mov"])
        #expect(Set(found.map { MediaPathResolver.fileName(of: $0.path) }) == ["one.mov", "two.MOV"])
        #expect(found.first { $0.path.hasSuffix("two.MOV") }?.size == 7)
    }

    @Test func plannerMatchesWindowsStoredPaths() {
        let m = MediaRef(name: "C2116", path: "D:\\Footage\\C2116.MP4", fingerprint: MediaFingerprint(size: 0))
        let plan = RelinkPlanner.plan(missing: [m], candidates: [RelinkCandidate(path: "/new/C2116.mp4", size: 3)])
        #expect(plan[m.id] == "/new/C2116.mp4")
    }

    @Test func plannerBreaksNameTiesByFolder() {
        let m = MediaRef(name: "C0001.MP4", path: "/Volumes/X/Card2/C0001.MP4", fingerprint: MediaFingerprint(size: 0))
        let r = RelinkPlanner.match(missing: [m], candidates: [RelinkCandidate(path: "/n/Card1/C0001.MP4", size: 1),
                                                               RelinkCandidate(path: "/n/Card2/C0001.MP4", size: 2)])
        #expect(r.plan[m.id] == "/n/Card2/C0001.MP4")
    }
}
