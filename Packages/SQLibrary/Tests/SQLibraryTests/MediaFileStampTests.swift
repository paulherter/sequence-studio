import Testing
import Foundation
@testable import SQLibrary

@Suite("MediaFileStamp")
struct MediaFileStampTests {
    private func tempFile(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString).mov")
        try Data(count: bytes).write(to: url)
        return url
    }

    @Test func unchangedFileIsNotReported() throws {
        let url = try tempFile(10)
        defer { try? FileManager.default.removeItem(at: url) }
        var tracker = MediaFileStampTracker()
        tracker.track(url)
        #expect(tracker.poll().isEmpty)
    }

    @Test func growingFileIsReportedOnce() throws {
        let url = try tempFile(10)
        defer { try? FileManager.default.removeItem(at: url) }
        var tracker = MediaFileStampTracker()
        tracker.track(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 100))
        try handle.close()
        #expect(tracker.poll() == [url])
        #expect(tracker.poll().isEmpty)
    }

    @Test func reRenderWithSameSizeChangesModificationDate() throws {
        let url = try tempFile(10)
        defer { try? FileManager.default.removeItem(at: url) }
        var tracker = MediaFileStampTracker()
        tracker.track(url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(tracker.poll() == [url])
    }

    @Test func missingThenReappearingIsReported() throws {
        let url = try tempFile(10)
        defer { try? FileManager.default.removeItem(at: url) }
        var tracker = MediaFileStampTracker()
        tracker.track(url)
        try FileManager.default.removeItem(at: url)
        #expect(tracker.poll() == [url])
        #expect(tracker.poll().isEmpty)
        try Data(count: 5).write(to: url)
        #expect(tracker.poll() == [url])
    }

    @Test func setTrackedAddsAndDrops() {
        let a = URL(fileURLWithPath: "/a.mov"), b = URL(fileURLWithPath: "/b.mov")
        var tracker = MediaFileStampTracker(reader: { _ in nil })
        tracker.setTracked([a])
        tracker.setTracked([b])
        #expect(tracker.tracked == [b])
    }

    @Test func trackedMissingFileDoesNotReportAtStart() {
        var tracker = MediaFileStampTracker(reader: { _ in nil })
        tracker.track(URL(fileURLWithPath: "/gone.mov"))
        #expect(tracker.poll().isEmpty)
    }
}
