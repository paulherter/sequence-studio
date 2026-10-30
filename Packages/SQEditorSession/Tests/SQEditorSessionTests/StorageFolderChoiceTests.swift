import Foundation
import Synchronization
import Testing
@testable import SQEditorSession

/// Preferences > Cache Folder: an app that switches its proxy cache at once (Windows) gets the old and new proxy folder
/// instead of the background copy, and the note no longer says "at the next launch".
@Suite(.serialized) struct StorageFolderChoiceTests {
    @Test func anAppThatMovesProxiesAtOnceGetsBothFoldersAndANoteWithoutRelaunch() throws {
        let suite = "sq-folder-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var s = AppSettings.load(from: d)
        s.cacheCapGB = 0
        let moved = Mutex<[(URL, URL)]>([])
        let copied = Mutex(0)
        StorageFolderChoice.movesProxiesAtOnce = { old, new in moved.withLock { $0.append((old, new)) } }
        defer { StorageFolderChoice.movesProxiesAtOnce = nil }
        let old = s.locations(from: d).proxyDirectory
        let note = StorageFolderChoice.setCacheFolder(root, settings: &s, defaults: d, migrate: { _, _ in copied.withLock { $0 += 1 } })
        #expect(!note.contains("next launch"), "\(note)")
        #expect(note.hasPrefix("Proxies already made are copied from"))
        let m = moved.withLock { $0 }
        #expect(m.count == 1)
        #expect(m.first?.0.standardizedFileURL == old.standardizedFileURL)
        #expect(m.first?.1.standardizedFileURL == root.appendingPathComponent("Proxies", isDirectory: true).standardizedFileURL)
        #expect(copied.withLock { $0 } == 0)

        StorageFolderChoice.movesProxiesAtOnce = nil
        let back = StorageFolderChoice.setCacheFolder(nil, settings: &s, defaults: d, migrate: { _, _ in copied.withLock { $0 += 1 } })
        #expect(back.hasPrefix("Applies at the next launch"))
        #expect(copied.withLock { $0 } == 1)
    }
}
