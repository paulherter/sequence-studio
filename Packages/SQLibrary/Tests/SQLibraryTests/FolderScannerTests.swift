import Foundation
import Testing
@testable import SQLibrary

@Suite struct FolderScannerTests {
    @Test func scansRecursivelyAndSkipsHidden() throws {
        let dir = try TempDir(); defer { dir.remove() }
        try dir.write("a.mp4", bytes: 10)
        try dir.write("sub/deep/b.WAV", bytes: 20)
        try dir.write(".DS_Store")
        try dir.write(".hiddenDir/c.mp4")
        try dir.write("sub/look.cube")
        let folder = WatchedFolder(url: dir.url)
        let result = FolderScanner().scan(folder)
        guard case .online(let entries) = result else { Issue.record("offline"); return }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        #expect(Set(byPath.keys) == ["a.mp4", "sub/deep/b.WAV", "sub/look.cube"])
        #expect(byPath["a.mp4"]?.kind == .video)
        #expect(byPath["a.mp4"]?.size == 10)
        #expect(byPath["sub/deep/b.WAV"]?.kind == .audio)
        #expect(byPath["sub/look.cube"]?.kind == .lut)
        #expect(byPath["a.mp4"]?.folderID == folder.id)
    }

    /// L2: a symlink next to its target must get its own entry id.
    @Test func symlinkAndTargetGetDistinctIDs() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let target = try dir.write("real.mp4", bytes: 10)
        try FileManager.default.createSymbolicLink(at: dir.url.appendingPathComponent("link.mp4"), withDestinationURL: target)
        guard case .online(let entries) = FolderScanner().scan(WatchedFolder(url: dir.url)) else { Issue.record("offline"); return }
        #expect(entries.map(\.relativePath).sorted() == ["link.mp4", "real.mp4"])
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test func missingFolderIsOfflineNotError() {
        let folder = WatchedFolder(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(FolderScanner().scan(folder) == .offline)
    }

    @Test func fileInsteadOfFolderIsOffline() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let f = try dir.write("x.mp4")
        #expect(FolderScanner().scan(WatchedFolder(url: f)) == .offline)
    }

    @Test func displayNameDefaultsToFolderName() {
        let f = WatchedFolder(url: URL(fileURLWithPath: "/tmp/My Footage"))
        #expect(f.displayName == "My Footage")
        #expect(WatchedFolder(url: f.url, displayName: "X").displayName == "X")
    }

    @Test func diffFindsAddedRemovedChanged() {
        let fid = UUID()
        func e(_ p: String, size: Int64 = 1, t: TimeInterval = 0) -> LibraryEntry {
            LibraryEntry(folderID: fid, relativePath: p, kind: .video, size: size, modified: Date(timeIntervalSince1970: t))
        }
        let old = [e("keep"), e("gone"), e("size"), e("time")]
        let new = [e("keep"), e("new"), e("size", size: 2), e("time", t: 5)]
        let d = LibraryDiff.between(old: old, new: new)
        #expect(d.added.map(\.relativePath) == ["new"])
        #expect(d.removed.map(\.relativePath) == ["gone"])
        #expect(d.changed.map(\.relativePath).sorted() == ["size", "time"])
        #expect(!d.isEmpty)
        #expect(LibraryDiff.between(old: old, new: old).isEmpty)
    }

    @Test func entryIdentityAndURL() {
        let f = WatchedFolder(url: URL(fileURLWithPath: "/tmp/F"))
        let e = LibraryEntry(folderID: f.id, relativePath: "a/b.mp4", kind: .video, size: 1, modified: .distantPast)
        #expect(e.id == LibraryEntryID(folderID: f.id, relativePath: "a/b.mp4"))
        #expect(e.url(in: f).path == "/tmp/F/a/b.mp4")
    }

    @Test func watchedFolderCodableRoundTrip() throws {
        let f = WatchedFolder(url: URL(fileURLWithPath: "/tmp/F"), bookmark: Data([1, 2, 3]))
        let back = try JSONDecoder().decode(WatchedFolder.self, from: JSONEncoder().encode(f))
        #expect(back == f)
    }
}

@Suite struct LibraryIndexTests {
    @Test func rescanReportsDiffAndOfflineKeepsSnapshot() async throws {
        let dir = try TempDir()
        let watcher = FakeFolderWatcher()
        let index = LibraryIndex(watcher: watcher)
        let folder = WatchedFolder(url: dir.url)
        try dir.write("a.mp4")
        let first = await index.add(folder)
        #expect(first.diff.added.count == 1)
        #expect(await index.state(of: folder.id) == .online)

        try dir.write("b.wav")
        let second = await index.rescan(folder.id)
        #expect(second?.diff.added.map(\.relativePath) == ["b.wav"])
        #expect(await index.entries(in: folder.id).count == 2)

        dir.remove()
        let off = await index.rescan(folder.id)
        #expect(off?.diff.isEmpty == true)
        #expect(await index.state(of: folder.id) == .offline)
        #expect(await index.entries(in: folder.id).count == 2)

        #expect(await index.rescan(UUID()) == nil)
    }

    @Test func watcherEventTriggersRescan() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let watcher = FakeFolderWatcher()
        let index = LibraryIndex(watcher: watcher)
        let folder = WatchedFolder(url: dir.url)
        _ = await index.add(folder)
        let updates = await index.updates()
        try dir.write("new.mp4")
        watcher.fire(dir.url)
        var it = updates.makeAsyncIterator()
        let update = await it.next()
        #expect(update?.folderID == folder.id)
        #expect(update?.diff.added.map(\.relativePath) == ["new.mp4"])
    }

    @Test func removeStopsWatching() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let watcher = FakeFolderWatcher()
        let index = LibraryIndex(watcher: watcher)
        let folder = WatchedFolder(url: dir.url)
        _ = await index.add(folder)
        #expect(watcher.activeCount == 1)
        await index.remove(folder.id)
        #expect(watcher.activeCount == 0)
        #expect(await index.folders.isEmpty)
    }
}
