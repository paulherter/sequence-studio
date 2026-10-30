import Foundation
import Testing
@testable import SQCore

@Suite struct MediaManagementTests {
    func ref(_ path: String) -> MediaRef {
        MediaRef(name: NSString(string: path).lastPathComponent, path: path, fingerprint: MediaFingerprint(size: 10))
    }

    @Test func layoutIsFolderWithProjectAndFiles() {
        let l = MediaManagement.layout(name: "Film", in: URL(fileURLWithPath: "/tmp/p"))
        #expect(l.folder.path == "/tmp/p/Film")
        #expect(l.projectFile.path == "/tmp/p/Film/Film.sqproj")
        #expect(l.filesFolder.path == "/tmp/p/Film/Files")
        #expect(MediaManagement.filesFolder(forProjectAt: l.projectFile).path == l.filesFolder.path)
    }

    @Test func looseProjectsGetANamedFilesFolderAndNoImplicitImport() {
        let loose = URL(fileURLWithPath: "/Users/p/Documents/Film.sqproj")
        #expect(!MediaManagement.isProjectFolderLayout(loose))
        #expect(MediaManagement.filesFolder(forProjectAt: loose).path == "/Users/p/Documents/Film Files")
        let p = Project(name: "Film")
        #expect(MediaManagement.importMode(of: p, projectURL: loose) == .leave)
        #expect(MediaManagement.importMode(of: Project(name: "F", importMode: .move), projectURL: loose) == .move)
        #expect(MediaManagement.importMode(of: p, projectURL: URL(fileURLWithPath: "/x/Film/Film.sqproj")) == .copy)
        #expect(MediaManagement.importMode(of: p, projectURL: nil) == .leave)
    }

    @Test(.enabled(if: TestFileSystem.canMakeSymlinks)) func insideResolvesSymlinksAndCase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sqin-\(UUID().uuidString)")
        let files = root.appendingPathComponent("Files")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let link = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: link, withDestinationURL: files)
        #expect(MediaManagement.isInside(link.appendingPathComponent("a.mov").path, folder: files))
        #if canImport(Darwin)
        // /var/... spelling of a /private/var/... folder
        let alt = files.path.hasPrefix("/private") ? String(files.path.dropFirst(8)) : "/private" + files.path
        #expect(MediaManagement.isInside(alt + "/a.mov", folder: files))
        #endif
        #expect(MediaManagement.isInside(files.path.uppercased() + "/a.mov", folder: files) == !isCaseSensitive(root))
    }

    func isCaseSensitive(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    @Test func nameIsSanitized() {
        #expect(MediaManagement.sanitized("a/b:c") == "a-b-c")
        #expect(MediaManagement.sanitized("  ..hidden ") == "hidden")
        #expect(MediaManagement.sanitized("   ") == "Untitled")
    }

    @Test func insideIsComponentWise() {
        let f = URL(fileURLWithPath: "/a/Files")
        #expect(MediaManagement.isInside("/a/Files/x.mov", folder: f))
        #expect(MediaManagement.isInside("/a/Files/sub/x.mov", folder: f))
        #expect(!MediaManagement.isInside("/a/Files2/x.mov", folder: f))
        #expect(!MediaManagement.isInside("/a/Files", folder: f))
    }

    @Test func uniqueNameCountsUp() {
        #expect(MediaManagement.uniqueName("a.mov") { _ in false } == "a.mov")
        #expect(MediaManagement.uniqueName("a.mov") { ["a.mov", "a 2.mov"].contains($0) } == "a 3.mov")
        #expect(MediaManagement.uniqueName("A.MOV") { $0 == "A.MOV" } == "A 2.MOV")
        // The candidate is passed with its real case, so a case-sensitive check sees "Clip 2.MOV".
        #expect(MediaManagement.uniqueName("Clip.MOV") { ["Clip.MOV", "Clip 2.MOV"].contains($0) } == "Clip 3.MOV")
        #expect(MediaManagement.uniqueName("noext") { $0 == "noext" } == "noext 2")
    }

    @Test func collectPlanSkipsInsideMissingAndAvoidsCollisions() {
        let files = URL(fileURLWithPath: "/p/Files")
        let media = [ref("/d/a.mov"), ref("/e/a.mov"), ref("/p/Files/b.mov"), ref("/d/gone.mov"), ref("/d/c.mov")]
        let plan = MediaManagement.collectPlan(media: media, into: files, existing: ["c.mov"],
                                               exists: { $0 != "/d/gone.mov" })
        #expect(plan.map(\.destination) == ["/p/Files/a.mov", "/p/Files/a 2.mov", "/p/Files/c 2.mov"])
        #expect(plan.map(\.source) == ["/d/a.mov", "/e/a.mov", "/d/c.mov"])
    }

    @Test func sameSourceSharesDestination() {
        let plan = MediaManagement.collectPlan(media: [ref("/d/a.mov"), ref("/d/a.mov")], into: URL(fileURLWithPath: "/p/Files"),
                                               existing: [], exists: { _ in true })
        #expect(plan.count == 2 && plan[0].destination == plan[1].destination)
    }

    @Test func repointKeepsFingerprint() {
        let m = ref("/d/a.mov")
        var p = Project(name: "P", media: [m])
        p.repoint([CollectItem(id: m.id, source: m.path, destination: "/p/Files/a.mov")])
        #expect(p.media[0].path == "/p/Files/a.mov")
        #expect(p.media[0].fingerprint == m.fingerprint)
    }

    @Test func importModeRoundTripsAndDefaultsWhenAbsent() throws {
        var p = Project(name: "P")
        #expect(p.effectiveImportMode == .copy)
        let none = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(none.importMode == nil)
        p.importMode = .move
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.importMode == .move)
        #expect(!String(decoding: try JSONEncoder().encode(Project(name: "Q")), as: UTF8.self).contains("importMode"))
    }
}
