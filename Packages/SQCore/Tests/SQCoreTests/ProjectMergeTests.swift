import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func media(_ path: String, name: String = "m") -> MediaRef {
    MediaRef(name: name, path: path, fingerprint: MediaFingerprint(size: 10), duration: s(100))
}
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil, media: UUID,
                  sequence: UUID? = nil) -> Clip {
    Clip(name: "c", media: media, kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start),
         link: link, mediaDuration: s(100), sequence: sequence)
}

/// Other project: media a (video) + b (audio), an inner sequence using both (linked), an outer sequence nesting the inner
/// one, a sub-bin holding the inner sequence and media a.
private func other(pathA: String = "/v/a.mov") throws -> Project {
    let a = media(pathA, name: "a"), b = media("/v/b.wav", name: "b")
    let link = UUID()
    var iv = Track(kind: .video), ia = Track(kind: .audio)
    try iv.overwrite(clip(0, 10, link: link, media: a.id))
    try ia.overwrite(clip(0, 10, kind: .audio, link: link, media: b.id))
    let inner = Timeline(name: "Inner", frameDuration: Time(1, 30), tracks: [iv, ia])
    var ov = Track(kind: .video)
    try ov.overwrite(clip(0, 10, media: inner.id, sequence: inner.id))
    let outer = Timeline(name: "Outer", frameDuration: Time(1, 30), tracks: [ov])
    var p = Project(name: "Other", media: [a, b], timelines: [outer, inner])
    let bin = p.newBin(name: "Sub")!
    p.move([.sequence(inner.id), .media(a.id)], to: bin)
    p.sourceMarks[a.id] = SourceMarks(markIn: s(1), markOut: s(5))
    return p
}

private func current() -> Project {
    let m = media("/v/own.mov", name: "own")
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
    return Project(name: "Current", media: [m], timelines: [t])
}

private func allIDs(_ p: Project) -> [UUID] {
    p.media.map(\.id) + p.timelines.map(\.id) + p.timelines.flatMap { $0.tracks.flatMap { $0.clips.map(\.id) } }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
}

@Suite struct ProjectMergeTests {
    @Test func importsEverythingUnderOneNamedBin() throws {
        var p = current()
        let active = p.activeTimeline
        let merged = p.merge(try other())
        let bin = try #require(merged)
        #expect(p.activeTimeline == active)
        #expect(p.timelines.count == 3 && p.media.count == 3)
        let b = try #require(p.bin(bin))
        #expect(b.name == "Other")
        #expect(p.rootBin.parent(of: .bin(bin)) == p.rootBin.id)
        #expect(b.allRefs.filter { if case .sequence = $0 { true } else { false } }.count == 2)
        #expect(b.allRefs.filter { if case .media = $0 { true } else { false } }.count == 2)
        let sub = try #require(b.children.compactMap { if case .bin(let x) = $0 { x } else { nil } }.first)
        #expect(sub.name == "Sub" && sub.children.count == 2)
        #expect(!b.contains(.sequence(p.timelines[0].id)))
    }

    @Test func idsNeverCollideEvenWhenMergedTwice() throws {
        var p = current()
        let o = try other()
        p.merge(o)
        p.merge(o)
        let ids = allIDs(p)
        #expect(Set(ids).count == ids.count)
        #expect(p.timelines.count == 5)
        #expect(Set(p.rootBin.allRefs).count == p.rootBin.allRefs.count)
        #expect(Set(ids).isDisjoint(with: Set(allIDs(o))))
    }

    @Test func nestedSequenceReferencesAreRemapped() throws {
        var p = current()
        p.merge(try other())
        let outer = try #require(p.timelines.first { $0.name == "Outer" })
        let inner = try #require(p.timelines.first { $0.name == "Inner" })
        let nested = try #require(outer.tracks[0].clips.first)
        #expect(nested.sequence == inner.id && nested.media == inner.id)
        #expect(p.isNestingAcyclic)
        #expect(p.wouldCreateCycle(nesting: outer.id, in: inner.id))
        #expect(!p.wouldCreateCycle(nesting: inner.id, in: p.timelines[0].id))
    }

    @Test func linksStayPairedAndMediaRefsResolve() throws {
        var p = current()
        let o = try other()
        p.merge(o)
        let inner = try #require(p.timelines.first { $0.name == "Inner" })
        let clips = inner.tracks.flatMap(\.clips)
        #expect(clips.count == 2 && clips[0].link != nil && clips[0].link == clips[1].link)
        #expect(clips.allSatisfy { c in p.media(c.media) != nil })
        #expect(clips[0].link != o.timelines.first { $0.name == "Inner" }?.tracks[0].clips[0].link)
    }

    @Test func existingMediaWithSamePathIsReused() throws {
        var p = current()
        let own = p.media[0]
        let merged = p.merge(try other(pathA: own.path))
        let bin = try #require(merged)
        #expect(p.media.count == 2)
        let inner = try #require(p.timelines.first { $0.name == "Inner" })
        #expect(inner.tracks[0].clips[0].media == own.id)
        #expect(!(p.bin(bin)?.contains(.media(own.id)) ?? true))
        #expect(p.rootBin.allRefs.filter { $0 == .media(own.id) }.count == 1)
    }

    @Test func sourceMarksTravelWithMedia() throws {
        var p = current()
        let o = try other()
        p.merge(o)
        let a = try #require(p.media.first { $0.name == "a" })
        #expect(p.sourceMarks[a.id] == o.sourceMarks.values.first)
    }

    @Test func relativePathsResolveAgainstTheSourceFolder() throws {
        var p = current()
        var o = try other(pathA: "Footage/a.mov")
        o.media[1].path = "/abs/b.wav"
        p.merge(o, sourceFolder: URL(fileURLWithPath: "/Users/x/Proj"))
        #expect(p.media.first { $0.name == "a" }?.path == "/Users/x/Proj/Footage/a.mov")
        #expect(p.media.first { $0.name == "b" }?.path == "/abs/b.wav")
    }

    @Test func intoGivenBinAndCustomName() throws {
        var p = current()
        let made = p.newBin(name: "Archive")
        let folder = try #require(made)
        let merged = p.merge(try other(), binName: "Old cut", into: folder)
        let bin = try #require(merged)
        #expect(p.rootBin.parent(of: .bin(bin)) == folder)
        #expect(p.bin(bin)?.name == "Old cut")
        let none = p.merge(try other(), into: UUID())
        #expect(none == nil)
    }

    @Test func builtInFixedIDsKeepTheirValue() {
        #expect(ProjectMerge.isFixedID("00000000-0000-0000-0000-000000000008"))
        #expect(ProjectMerge.isFixedID("6b657973-746f-6e65-0000-000000000001"))
        #expect(!ProjectMerge.isFixedID(UUID().uuidString))
    }

    @Test func loadsFromPackageAndMergesFromDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Other.sqproj")
        try ProjectFile.write(try other(), to: url)
        let loaded = try ProjectMerge.load(from: url)
        #expect(loaded.name == "Other" && loaded.timelines.count == 2)
        var p = current()
        let merged = p.merge(loaded)
        #expect(merged != nil)
    }

    @Test func errorsAreHumanReadable() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let empty = dir.appendingPathComponent("Empty.sqproj")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ProjectFileError.missing) { try ProjectMerge.load(from: empty) }
        let bad = dir.appendingPathComponent("Bad.sqproj")
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: bad.appendingPathComponent("project.json"))
        #expect(throws: ProjectFileError.corrupt) { try ProjectMerge.load(from: bad) }
        let newer = dir.appendingPathComponent("New.sqproj")
        try fm.createDirectory(at: newer, withIntermediateDirectories: true)
        try Data(#"{"formatVersion":9999,"project":{}}"#.utf8).write(to: newer.appendingPathComponent("project.json"))
        #expect(throws: ProjectFileError.newerVersion(found: 9999, supported: ProjectFile.currentVersion)) {
            try ProjectMerge.load(from: newer)
        }

        let cases: [(ProjectFileError, String)] = [(.missing, "no project"), (.corrupt, "damaged"),
                                                   (.newerVersion(found: 9, supported: 1), "newer")]
        for (e, word) in cases {
            let m = ProjectMerge.message(for: e, fileName: "X.sqproj")
            #expect(m.detail.contains(word))
            #expect(!m.title.contains("project.json") && !m.detail.contains("project.json"))
        }
        let generic = ProjectMerge.message(for: CocoaError(.fileReadNoPermission), fileName: "X.sqproj")
        #expect(generic.detail.contains("permission"))
    }

    @Test func binTreeStaysConsistent() throws {
        var p = current()
        p.merge(try other())
        var q = p
        q.normalizeBins()
        #expect(q == p)
    }
}
