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
            RelinkCandidate(path: "/new/B.mov", size: 999),         // same name, other size: a different file, never offered
        ]
        let plan = RelinkPlanner.plan(missing: [a, b], candidates: found)
        #expect(plan[a.id] == "/new/sub/a.MOV")
        #expect(plan[b.id] == nil)
        let r = RelinkPlanner.match(missing: [b], candidates: [RelinkCandidate(path: "/new/B.mov", size: -1)])
        #expect(r.plan.isEmpty && r.sizeMismatch == [b.id])   // unknown size never matches
    }

    @Test func prefersTheSameSizeAmongSeveralWithTheSameName() {
        let a = ref("A.mov", size: 100)
        let plan = RelinkPlanner.plan(missing: [a], candidates: [
            RelinkCandidate(path: "/x/A.mov", size: 5), RelinkCandidate(path: "/y/A.mov", size: 100),
        ])
        #expect(plan[a.id] == "/y/A.mov")
    }

    @Test func unknownRecordedSizeMatchesByNameWhenUnambiguous() {
        let a = ref("A.mov", size: 0)
        let one = RelinkPlanner.match(missing: [a], candidates: [RelinkCandidate(path: "/x/a.mov", size: 123)])
        #expect(one.plan[a.id] == "/x/a.mov" && one.sizeMismatch.isEmpty)
        let two = RelinkPlanner.match(missing: [a], candidates: [RelinkCandidate(path: "/x/A.mov", size: 1), RelinkCandidate(path: "/y/A.mov", size: 2)])
        #expect(two.plan.isEmpty && two.sizeMismatch == [a.id])   // ambiguous: not guessed
    }

    @Test func severalSameSizeCandidatesPickTheSameFileWhateverTheScanOrder() {
        let a = ref("A.mov", size: 100, path: "/Volumes/Old/Day1")
        let x = RelinkCandidate(path: "/zzz/Other/A.mov", size: 100)
        let y = RelinkCandidate(path: "/Volumes/New/Day1/A.mov", size: 100)       // same trailing folder
        let z = RelinkCandidate(path: "/Volumes/Old/Day2/A.mov", size: 100)       // closest to the old path
        #expect(RelinkPlanner.plan(missing: [a], candidates: [x, y, z])[a.id] == "/Volumes/New/Day1/A.mov")
        #expect(RelinkPlanner.plan(missing: [a], candidates: [z, y, x])[a.id] == "/Volumes/New/Day1/A.mov")
        // Without a folder hint the closest path wins, then the path text.
        let b = ref("B.mov", size: 50, path: "/Volumes/Old/Day1")
        let near = RelinkCandidate(path: "/Volumes/Old/Day2/B.mov", size: 50)
        let far = RelinkCandidate(path: "/a/B.mov", size: 50)
        #expect(RelinkPlanner.plan(missing: [b], candidates: [far, near])[b.id] == near.path)
        let tieA = RelinkCandidate(path: "/q/1/B.mov", size: 50), tieB = RelinkCandidate(path: "/q/2/B.mov", size: 50)
        #expect(RelinkPlanner.plan(missing: [b], candidates: [tieB, tieA])[b.id] == tieA.path)
    }

    @Test func modificationDateBreaksTiesBeforeFolders() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var m = ref("A.mov", size: 100, path: "/Volumes/Old/Day1")
        m.fingerprint.modified = when
        let sameFolderOtherDate = RelinkCandidate(path: "/Volumes/New/Day1/A.mov", size: 100, modified: when.addingTimeInterval(500))
        let sameDate = RelinkCandidate(path: "/elsewhere/A.mov", size: 100, modified: when)
        #expect(RelinkPlanner.plan(missing: [m], candidates: [sameFolderOtherDate, sameDate])[m.id] == "/elsewhere/A.mov")
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
