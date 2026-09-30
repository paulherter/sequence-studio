import Foundation
import Testing
@testable import SSLibrary

@Suite struct LibrarySearchTests {
    let fid = UUID()
    func e(_ p: String, _ k: LibraryItemKind = .video, size: Int64 = 1, t: TimeInterval = 0) -> LibraryEntry {
        LibraryEntry(folderID: fid, relativePath: p, kind: k, size: size, modified: Date(timeIntervalSince1970: t))
    }

    @Test func multiTokenCaseAndDiacriticInsensitive() {
        let all = [e("Café Interview Take 2.mov"), e("cafe/b-roll.mov"), e("Interview.wav", .audio)]
        #expect(LibrarySearch.filter(all, query: "CAFE take").map(\.name) == ["Café Interview Take 2.mov"])
        #expect(LibrarySearch.filter(all, query: "interview").count == 2)
        #expect(LibrarySearch.filter(all, query: "  ").count == 3)
        #expect(LibrarySearch.filter(all, query: "zzz").isEmpty)
    }

    @Test func searchMatchesFileNameNotFolderPath() {
        let all = [e("cafe/b-roll.mov")]
        #expect(LibrarySearch.filter(all, query: "cafe").isEmpty)
    }

    @Test func kindFilter() {
        let all = [e("a.mov"), e("b.wav", .audio), e("c.png", .image)]
        #expect(LibrarySearch.filter(all, kinds: [.audio, .image]).map(\.name) == ["b.wav", "c.png"])
        #expect(LibrarySearch.filter(all, kinds: []).count == 3)
    }

    @Test func sorting() {
        let all = [e("b10.mov", size: 5, t: 30), e("b2.mov", size: 9, t: 10), e("A.mov", size: 1, t: 20)]
        #expect(LibrarySearch.filter(all, sort: .name).map(\.name) == ["A.mov", "b2.mov", "b10.mov"])
        #expect(LibrarySearch.filter(all, sort: .name, ascending: false).map(\.name) == ["b10.mov", "b2.mov", "A.mov"])
        #expect(LibrarySearch.filter(all, sort: .date).map(\.name) == ["b2.mov", "A.mov", "b10.mov"])
        #expect(LibrarySearch.filter(all, sort: .size, ascending: false).map(\.name) == ["b2.mov", "b10.mov", "A.mov"])
    }

    @Test func ties() {
        let all = [e("z/a.mov", size: 1), e("a/a.mov", size: 1)]
        #expect(LibrarySearch.filter(all, sort: .size).map(\.relativePath) == ["a/a.mov", "z/a.mov"])
    }
}

@Suite struct FavoritesTests {
    let id1 = LibraryEntryID(folderID: UUID(), relativePath: "a.mov")
    let id2 = LibraryEntryID(folderID: UUID(), relativePath: "b/c.wav")

    @Test func toggleAndContains() {
        var f = Favorites()
        #expect(!f.contains(id1))
        let on = f.toggle(id1)
        #expect(on)
        #expect(f.contains(id1))
        let off = f.toggle(id1)
        #expect(!off)
        #expect(f.ids.isEmpty)
    }

    @Test func persistenceRoundTripAndDeterministicOutput() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = dir.url.appendingPathComponent("sub/favorites.json")
        var f = Favorites(); f.add(id1); f.add(id2)
        try FavoritesStore.save(f, to: url)
        #expect(try FavoritesStore.load(from: url) == f)
        let first = try Data(contentsOf: url)
        try FavoritesStore.save(f, to: url)
        #expect(try Data(contentsOf: url) == first)
        #expect(String(decoding: first, as: UTF8.self).contains("\"formatVersion\""))
    }

    @Test func missingFileIsEmpty() throws {
        let dir = try TempDir(); defer { dir.remove() }
        #expect(try FavoritesStore.load(from: dir.url.appendingPathComponent("none.json")).ids.isEmpty)
    }

    @Test func newerVersionThrows() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = dir.url.appendingPathComponent("f.json")
        try Data(#"{"formatVersion":99,"items":[]}"#.utf8).write(to: url)
        #expect(throws: LibraryStoreError.newerFormat(found: 99, supported: 1)) { try FavoritesStore.load(from: url) }
    }

    @Test func corruptFileIsBackedUpAndEmpty() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let url = dir.url.appendingPathComponent("f.json")
        try Data("not json".utf8).write(to: url)
        #expect(try FavoritesStore.load(from: url).ids.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(files.contains { $0.hasPrefix("f.json.corrupt-") })
    }
}
