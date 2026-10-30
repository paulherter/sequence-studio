import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@Suite struct MediaDiskTrackerTests {
    private let id = UUID()
    private func state(_ exists: Bool = true, size: Int64 = 10, _ t: TimeInterval = 100) -> [UUID: MediaDiskState] {
        [id: MediaDiskState(exists: exists, size: exists ? size : nil, modified: exists ? Date(timeIntervalSince1970: t) : nil)]
    }

    @Test func firstLookOnlyRecords() {
        var t = MediaDiskTracker()
        #expect(t.update(state()).isEmpty)
        #expect(t.update(state()).isEmpty)
    }

    @Test func overwrittenFileIsModified() {
        var t = MediaDiskTracker()
        _ = t.update(state())
        #expect(t.update(state(size: 20)).modified == [id])
        #expect(t.update(state(size: 20, 200)).modified == [id])      // date only
        #expect(t.update(state(size: 20, 200)).isEmpty)
    }

    @Test func goneAndBack() {
        var t = MediaDiskTracker()
        _ = t.update(state())
        #expect(t.update(state(false)).vanished == [id])
        #expect(t.update(state(false)).isEmpty)
        let back = t.update(state())
        #expect(back.appeared == [id])
        #expect(back.all == [id])
    }

    @Test func itemNewToTheProjectIsABaseline() {
        var t = MediaDiskTracker()
        _ = t.update([:])
        #expect(t.update(state()).isEmpty)
    }

    @Test func readsRealFile() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("SQDisk-\(UUID().uuidString).bin")
        #expect(!MediaDiskState.read(u.path).exists)
        try Data([1, 2, 3]).write(to: u)
        let s = MediaDiskState.read(u.path)
        #expect(s.exists && s.size == 3 && s.modified != nil)
    }
}

@Suite @MainActor struct MediaDiskSessionTests {
    private func session(path: String) -> (EditorSession, MediaRef) {
        let m = MediaRef(name: "a.mov", path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(seconds: 5))
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])])
        p.add(m)
        return (EditorSession(project: p), m)
    }

    @Test func fileReplacedOnDiskIsReportedOnce() async throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("SQDisk-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: u)
        let (s, m) = session(path: u.path)
        var reported: [Set<UUID>] = []
        s.onMediaFilesChanged = { reported.append($0) }
        #expect(await s.refreshMediaFromDisk().isEmpty)               // baseline
        try Data([1, 2, 3, 4, 5]).write(to: u)
        #expect(await s.refreshMediaFromDisk() == [m.id])
        #expect(reported == [[m.id]])
        #expect(await s.refreshMediaFromDisk().isEmpty)
    }

    @Test func vanishedAndReturnedFileIsReported() async throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("SQDisk-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: u)
        let (s, m) = session(path: u.path)
        _ = await s.refreshMediaFromDisk()
        try FileManager.default.removeItem(at: u)
        #expect(await s.refreshMediaFromDisk() == [m.id])
        try Data([1, 2, 3]).write(to: u)
        #expect(await s.refreshMediaFromDisk() == [m.id])
    }

    @Test func sleepStopsPlayback() {
        let (s, _) = session(path: "/nonexistent/a.mov")
        s.handleDiskEvent(.willSleep)
        #expect(!s.isPlaying)
    }
}
