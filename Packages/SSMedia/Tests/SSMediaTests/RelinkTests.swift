import Foundation
import SSCore
import Testing
@testable import SSMedia

private final class Sandbox {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, _ bytes: String) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: u)
        return u
    }
    func ref(_ url: URL) -> MediaRef {
        MediaRef(name: url.lastPathComponent, path: url.path, fingerprint: MediaLocator.fingerprint(of: url)!)
    }
    func dir(_ rel: String) -> URL { root.appendingPathComponent(rel) }
}

@Suite("Relink")
struct RelinkTests {
    @Test func originalPathWins() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "AAAA")
        let r = MediaLocator().locate(s.ref(a))
        #expect(r.resolved?.url.path == a.path)
        #expect(r.resolved?.method == .originalPath)
    }

    @Test func bookmarkFollowsMovedFile() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "AAAA")
        var ref = s.ref(a)
        ref.bookmark = try a.bookmarkData()
        let b = s.dir("b/clip.mov")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: b)
        let r = MediaLocator().locate(ref)
        #expect(r.resolved?.method == .bookmark)
        #expect(r.resolved?.url.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path)
    }

    @Test func movedFolderFoundInProjectNeighbours() throws {
        let s = try Sandbox()
        let a = try s.write("old/footage/clip.mov", "CONTENT-1")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: s.dir("old"))
        try s.write("new/footage/clip.mov", "CONTENT-1")
        try s.write("proj/Project.ssproj/x.json", "{}")
        let r = MediaLocator(projectFolder: s.dir("proj")).locate(ref)
        #expect(r.resolved?.method == .projectNeighbour)
        #expect(r.resolved?.url.lastPathComponent == "clip.mov")
    }

    @Test func renamedFileFoundByFingerprint() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", String(repeating: "x", count: 5000))
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        try s.write("lib/renamed.mov", String(repeating: "x", count: 5000))
        try s.write("lib/other.mov", String(repeating: "y", count: 5000))
        let r = MediaLocator(searchFolders: [s.dir("lib")]).locate(ref)
        #expect(r.resolved?.url.lastPathComponent == "renamed.mov")
        #expect(r.resolved?.method == .fingerprint)
        #expect(r.candidates.first?.score == .fingerprint)
    }

    @Test func sameNameTwiceIsAmbiguousNeverAutoPicked() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "ORIGINAL")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        try s.write("lib/one/clip.mov", "DIFFERENT-ONE")
        try s.write("lib/two/clip.mov", "DIFFERENT-TWO!")
        let r = MediaLocator(searchFolders: [s.dir("lib")]).locate(ref)
        #expect(r.resolved == nil)
        #expect(r.candidates.count == 2)
        #expect(r.candidates.allSatisfy { $0.score == .nameOnly })
    }

    @Test func twoFingerprintMatchesAreAmbiguous() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "SAME")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        try s.write("lib/one/clip.mov", "SAME")
        try s.write("lib/two/copy.mov", "SAME")
        let r = MediaLocator(searchFolders: [s.dir("lib")]).locate(ref)
        #expect(r.resolved == nil)
        #expect(r.candidates.count == 2)
    }

    @Test func nameAndSizeRanksAboveNameOnly() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "12345678")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        try s.write("lib/one/clip.mov", "abcdefgh")  // same size, different content
        try s.write("lib/two/clip.mov", "abc")
        let r = MediaLocator(searchFolders: [s.dir("lib")]).locate(ref)
        #expect(r.resolved == nil)
        #expect(r.candidates.map(\.score) == [.nameSize, .nameOnly])
    }

    @Test func searchSkipsHiddenPackagesAndDepth() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "Q")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        try s.write("lib/.hidden/clip.mov", "Q")
        try s.write("lib/Thing.app/Contents/clip.mov", "Q")
        try s.write("lib/d1/d2/d3/d4/clip.mov", "Q")
        let r = MediaLocator(searchFolders: [s.dir("lib")], maxDepth: 3).locate(ref)
        #expect(r.candidates.isEmpty)
    }

    @Test func relinkOthersMapsDirectoryAndVerifiesFingerprint() throws {
        let s = try Sandbox()
        let a = try s.write("drive1/shoot/day1/a.mov", "AAA-content")
        let b = try s.write("drive1/shoot/day2/b.mov", "BBB-content")
        let c = try s.write("drive1/shoot/day2/c.mov", "CCC-content")
        let d = try s.write("elsewhere/d.mov", "DDD-content")
        let refs = [a, b, c, d].map { s.ref($0) }
        try FileManager.default.removeItem(at: s.dir("drive1"))
        try FileManager.default.removeItem(at: s.dir("elsewhere"))
        try s.write("drive2/archive/shoot/day1/a.mov", "AAA-content")
        try s.write("drive2/archive/shoot/day2/b.mov", "BBB-content")
        try s.write("drive2/archive/shoot/day2/c.mov", "TAMPERED!!!!")
        let chosen = s.dir("drive2/archive/shoot/day1/a.mov")
        let out = MediaLocator.relinkOthers(chosen: refs[0], to: chosen, others: Array(refs.dropFirst()))
        #expect(out.report.relinked.count == 2)  // chosen + b
        #expect(out.report.relinked[refs[1].id]?.lastPathComponent == "b.mov")
        #expect(out.report.fingerprintMismatch == [refs[2].id])
        #expect(out.report.missing == [refs[3].id])
        #expect(out.refs[1].path.hasSuffix("drive2/archive/shoot/day2/b.mov"))
        #expect(out.refs[2].path == refs[2].path)
    }

    @Test func applyUpdatesRef() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "AAAA")
        let b = try s.write("b/clip2.mov", "AAAA")
        var ref = s.ref(a)
        ref.bookmark = Data([1])
        let new = MediaLocator.applying(b, to: ref)
        #expect(new.path == b.path && new.name == "clip2.mov" && new.id == ref.id)
        #expect(new.bookmark != Data([1]))
    }

    // MARK: Review fixes

    @Test func depthBoundaryIsExact() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "Q")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        try s.write("lib/d1/d2/clip.mov", "Q")          // 2 directories below the root: allowed at maxDepth 2
        try s.write("lib/d1/d2/d3/clip.mov", "Q")       // 3 below: too deep
        let r = MediaLocator(searchFolders: [s.dir("lib")], maxDepth: 2).locate(ref)
        #expect(r.candidates.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["d2"])
    }

    @Test func symlinkToFileInsideRootIsFoundButOutsideIsNot() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "SYM")
        let ref = s.ref(a)
        try FileManager.default.removeItem(at: a)
        let real = try s.write("lib/real/clip.mov", "SYM")
        let outside = try s.write("outside/other.mov", "SYM")
        try FileManager.default.createDirectory(at: s.dir("lib/links"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: real)
        try FileManager.default.createSymbolicLink(at: s.dir("lib/links/clip.mov"), withDestinationURL: outside)
        var r = MediaLocator(searchFolders: [s.dir("lib")]).locate(ref)
        #expect(r.candidates.isEmpty)                    // target outside the search root
        try FileManager.default.removeItem(at: s.dir("lib/links/clip.mov"))
        let target = try s.write("lib/.store/target.mov", "SYM")   // hidden: only reachable through the link
        try FileManager.default.createSymbolicLink(at: s.dir("lib/links/clip.mov"), withDestinationURL: target)
        r = MediaLocator(searchFolders: [s.dir("lib")]).locate(ref)
        #expect(!r.candidates.isEmpty)
        #expect(r.resolved?.url.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
    }

    @Test func originalPathWithDifferentContentIsOnlyACandidate() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "ORIGINAL")
        let ref = s.ref(a)
        try Data("REPLACED-WITH-OTHER-FILE".utf8).write(to: a)
        let r = MediaLocator().locate(ref)
        #expect(r.resolved == nil)
        #expect(r.candidates.first?.url.path == a.path)
        #expect(r.candidates.first?.score != .fingerprint)
    }

    @Test func bookmarkToChangedFileIsOnlyACandidate() throws {
        let s = try Sandbox()
        let a = try s.write("a/clip.mov", "ORIGINAL")
        var ref = s.ref(a)
        ref.bookmark = try a.bookmarkData()
        try Data("REPLACED-WITH-OTHER-FILE".utf8).write(to: a)
        let r = MediaLocator().locate(ref)
        #expect(r.resolved == nil)
        #expect(r.candidates.count == 1)
    }

    @Test func relinkOthersComparesCaseInsensitivelyOnCaseInsensitiveVolume() throws {
        let s = try Sandbox()
        let sensitive = (try? s.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        guard !sensitive else { return }
        let a = try s.write("old/clip.mov", "AAA")
        let b = try s.write("old/b.mov", "BBB")
        let ra = s.ref(a)
        var rb = s.ref(b)
        rb.path = s.root.appendingPathComponent("OLD/b.mov").path   // differently-cased spelling of the same folder
        try FileManager.default.moveItem(at: s.dir("old"), to: s.dir("new"))
        let (_, report) = MediaLocator.relinkOthers(chosen: ra, to: s.dir("new/clip.mov"), others: [rb])
        #expect(report.relinked[rb.id] != nil)
    }
}
