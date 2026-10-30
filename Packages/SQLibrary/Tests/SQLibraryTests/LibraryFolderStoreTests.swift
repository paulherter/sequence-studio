import Foundation
import Testing
@testable import SQLibrary

@Suite struct LibraryFolderStoreTests {
    private func defaults() -> UserDefaults {
        let name = "sq-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func roundTrip() {
        let d = defaults()
        let f = WatchedFolder(url: URL(fileURLWithPath: "/Volumes/News/Sounds"))
        LibraryFolderStore.save([f], d)
        #expect(LibraryFolderStore.load(d) == [f])
    }

    @Test func migratesLegacyKey() throws {
        let d = defaults()
        let f = WatchedFolder(url: URL(fileURLWithPath: "/tmp/gfx"))
        d.set(try JSONEncoder().encode([f]), forKey: LibraryFolderStore.legacyKey)
        #expect(LibraryFolderStore.load(d) == [f])
        #expect(d.data(forKey: LibraryFolderStore.legacyKey) == nil)
        #expect(d.data(forKey: LibraryFolderStore.key) != nil)
    }

    @Test func emptyAndCorrupt() {
        let d = defaults()
        #expect(LibraryFolderStore.load(d).isEmpty)
        d.set(Data([1, 2, 3]), forKey: LibraryFolderStore.key)
        #expect(LibraryFolderStore.load(d).isEmpty)
    }

    @Test func scanOf2000FilesIsFastAndMissingFolderIsOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for d in 0..<20 {
            let dir = root.appendingPathComponent("sub\(d)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<100 { FileManager.default.createFile(atPath: dir.appendingPathComponent("s\(i).wav").path, contents: Data([0])) }
        }
        let start = Date()
        let result = FolderScanner().scan(WatchedFolder(url: root))
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(ms < 3000, "SQ_SCAN_2000_MS \(Int(ms))")
        guard case .online(let entries) = result else { Issue.record("offline"); return }
        #expect(entries.count == 2000)
        #expect(FolderScanner().scan(WatchedFolder(url: root.appendingPathComponent("gone"))) == .offline)
    }
}
