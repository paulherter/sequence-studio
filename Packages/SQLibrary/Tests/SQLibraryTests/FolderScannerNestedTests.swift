import Foundation
import Testing
@testable import SQLibrary

@Suite struct FolderScannerNestedTests {
    @Test(.disabled(if: symlinksNeedPrivilege, "creating symlinks needs a privilege on Windows")) func symlinkedDirectoryLoopTerminates() throws {
        let dir = try TempDir(); defer { dir.remove() }
        try dir.write("Cat/a.wav")
        try FileManager.default.createSymbolicLink(at: dir.url.appendingPathComponent("Cat/loop"), withDestinationURL: dir.url)
        guard case .online(let entries) = FolderScanner().scan(WatchedFolder(url: dir.url)) else { Issue.record("offline"); return }
        #expect(entries.map(\.relativePath) == ["Cat/a.wav"])
    }

    @Test func hiddenFoldersAndFilesAreSkipped() throws {
        let dir = try TempDir(); defer { dir.remove() }
        try dir.write("Cat/.secret/a.wav"); try dir.write("Cat/.b.wav"); try dir.write("Cat/ok.wav")
        guard case .online(let entries) = FolderScanner().scan(WatchedFolder(url: dir.url)) else { Issue.record("offline"); return }
        #expect(entries.map(\.relativePath) == ["Cat/ok.wav"])
    }

    @Test func depthGuardStopsDescent() throws {
        let dir = try TempDir(); defer { dir.remove() }
        try dir.write("a/b/c/d/deep.wav"); try dir.write("a/near.wav")
        var scanner = FolderScanner(); scanner.maxDepth = 3
        guard case .online(let entries) = scanner.scan(WatchedFolder(url: dir.url)) else { Issue.record("offline"); return }
        #expect(entries.map(\.relativePath) == ["a/near.wav"])
    }

    @Test func entryLimitCapsResult() throws {
        let dir = try TempDir(); defer { dir.remove() }
        for i in 0..<30 { try dir.write("c/f\(i).wav", bytes: 1) }
        var scanner = FolderScanner(); scanner.maxEntries = 10
        guard case .online(let entries) = scanner.scan(WatchedFolder(url: dir.url)) else { Issue.record("offline"); return }
        #expect(entries.count == 10)
    }

    @Test func fiveThousandFilesScan() throws {
        let dir = try TempDir(); defer { dir.remove() }
        for i in 0..<5000 { try dir.write("c\(i % 25)/f\(i).wav", bytes: 1) }
        guard case .online(let entries) = FolderScanner().scan(WatchedFolder(url: dir.url)) else { Issue.record("offline"); return }
        #expect(entries.count == 5000)
    }
}
