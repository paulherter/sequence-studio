import Foundation
import Testing
@testable import SQLibrary

@Suite struct LUTLibraryTests {
    func makeLib(_ dir: TempDir) -> LUTLibrary { LUTLibrary(directory: dir.url.appendingPathComponent("LUTs")) }

    @Test func importCopiesCubeFilesOnly() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        let a = try src.write("Warm.cube"), b = try src.write("notes.txt")
        var lib = makeLib(dst)
        let added = lib.importLUTs(from: [a, b]).added
        #expect(added.map(\.fileName) == ["Warm.cube"])
        #expect(FileManager.default.fileExists(atPath: lib.entries()[0].path))
        #expect(lib.entries()[0].name == "Warm")
        #expect(FileManager.default.fileExists(atPath: a.path))   // original untouched
    }

    @Test func importRenamesOnCollision() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        let a = try src.write("Warm.cube"), b = try src.write("sub/Warm.cube")
        var lib = makeLib(dst)
        _ = lib.importLUTs(from: [a]); _ = lib.importLUTs(from: [b])
        #expect(lib.entries().map(\.fileName) == ["Warm 2.cube", "Warm.cube"])
    }

    @Test func starredLUTIsFirst() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        var lib = makeLib(dst)
        _ = lib.importLUTs(from: [try src.write("A.cube"), try src.write("B.cube"), try src.write("C.cube")])
        #expect(lib.entries().map(\.name) == ["A", "B", "C"])
        try lib.toggleFavourite("C.cube")
        #expect(lib.entries().map(\.name) == ["C", "A", "B"])
        #expect(lib.entries()[0].isFavourite)
        try lib.toggleFavourite("B.cube")
        #expect(lib.entries().map(\.name) == ["B", "C", "A"])
        try lib.toggleFavourite("C.cube")
        #expect(lib.entries().map(\.name) == ["B", "A", "C"])
    }

    @Test func favouritesPersistAcrossReload() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        var lib = makeLib(dst)
        _ = lib.importLUTs(from: [try src.write("A.cube"), try src.write("B.cube")])
        try lib.toggleFavourite("B.cube")
        let again = makeLib(dst)
        #expect(again.entries().map(\.name) == ["B", "A"])
    }

    @Test func removeDeletesFileAndFavourite() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        var lib = makeLib(dst)
        _ = lib.importLUTs(from: [try src.write("A.cube")])
        try lib.toggleFavourite("A.cube")
        try lib.remove("A.cube")
        #expect(lib.entries().isEmpty)
        #expect(!makeLib(dst).isFavourite("A.cube"))
    }

    @Test func naturalNameOrder() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        var lib = makeLib(dst)
        _ = lib.importLUTs(from: [try src.write("look10.cube"), try src.write("Look2.cube")])
        #expect(lib.entries().map(\.name) == ["Look2", "look10"])
    }

    @Test func importKeepsEarlierFilesWhenALaterOneFails() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        var lib = makeLib(dst)
        let r = lib.importLUTs(from: [try src.write("A.cube"), src.url.appendingPathComponent("missing.cube"), try src.write("C.cube")])
        #expect(r.added.map(\.fileName) == ["A.cube", "C.cube"])
        #expect(r.failures.count == 1)
    }

    @Test func corruptFavouritesAreKeptAsBackupNotOverwritten() throws {
        let dst = try TempDir()
        defer { dst.remove() }
        let dir = dst.url.appendingPathComponent("LUTs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("favourites.json"))
        var lib = LUTLibrary(directory: dir)
        #expect(lib.loadError != nil)
        try lib.toggleFavourite("A.cube")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("favourites.json.corrupt-") })
    }

    @Test func pruneDropsStarsOfMissingFiles() throws {
        let src = try TempDir(), dst = try TempDir()
        defer { src.remove(); dst.remove() }
        var lib = makeLib(dst)
        lib.importLUTs(from: [try src.write("A.cube"), try src.write("B.cube")])
        try lib.toggleFavourite("A.cube"); try lib.toggleFavourite("B.cube")
        try FileManager.default.removeItem(atPath: lib.entries().first { $0.name == "A" }!.path)
        #expect(try lib.pruneMissingFavourites())
        #expect(!lib.isFavourite("A.cube") && lib.isFavourite("B.cube"))
        #expect(!makeLib(dst).isFavourite("A.cube"))
    }
}
