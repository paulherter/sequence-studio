import Foundation
import Testing
@testable import SQCore

@Suite struct RelinkTests {
    private func ref(_ name: String, size: Int64 = 100, path: String = "/gone") -> MediaRef {
        MediaRef(name: name, path: path + "/" + name, fingerprint: MediaFingerprint(size: size))
    }

    @Test func matchesByFileNameAndSize() {
        let a = ref("A.mov", size: 100), b = ref("B.mov", size: 200)
        let found = [
            RelinkCandidate(path: "/new/sub/a.MOV", size: 100),     // case-insensitive name
            RelinkCandidate(path: "/new/B.mov", size: 999),         // same name, other size: still offered when it is the only one
        ]
        let plan = RelinkPlanner.plan(missing: [a, b], candidates: found)
        #expect(plan[a.id] == "/new/sub/a.MOV")
        #expect(plan[b.id] == "/new/B.mov")
    }

    @Test func prefersTheSameSizeAmongSeveralWithTheSameName() {
        let a = ref("A.mov", size: 100)
        let plan = RelinkPlanner.plan(missing: [a], candidates: [
            RelinkCandidate(path: "/x/A.mov", size: 5), RelinkCandidate(path: "/y/A.mov", size: 100),
        ])
        #expect(plan[a.id] == "/y/A.mov")
    }

    @Test func unmatchedStayOffline() {
        let a = ref("A.mov")
        #expect(RelinkPlanner.plan(missing: [a], candidates: [RelinkCandidate(path: "/x/Z.mov", size: 100)]).isEmpty)
    }

    @Test func projectRelinkUpdatesPathAndDropsStaleBookmark() {
        var m = ref("A.mov")
        m.bookmark = Data([1])
        var p = Project(name: "P", timelines: [])
        p.add(m)
        p.relink([m.id: "/new/A.mov", UUID(): "/ignored.mov"])
        #expect(p.media(m.id)?.path == "/new/A.mov")
        #expect(p.media(m.id)?.bookmark == nil)
        #expect(p.media(m.id)?.name == "A.mov")
    }

    @Test func missingMediaListsOnlyMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-relink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("here.mov")
        try Data(count: 10).write(to: file)
        var p = Project(name: "P", timelines: [])
        let here = MediaRef(name: "here.mov", path: file.path, fingerprint: MediaFingerprint(size: 10))
        let gone = ref("gone.mov")
        p.add(here); p.add(gone)
        #expect(p.missingMedia().map(\.id) == [gone.id])
    }
}
