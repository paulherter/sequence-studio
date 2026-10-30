import Testing
import Foundation
import SQCore
@testable import SQExport

@Suite struct CoverImageQueueTests {
    private func job(_ dir: URL, cover: CoverImageFormat?, coverTime: Time? = nil) -> ExportJob {
        var s = smallSettings(codec: .h264)
        s.coverImage = cover; s.coverTime = coverTime
        return ExportJob(name: "Clip", settings: s, outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 30, frameDuration: Time(1, 30)), audio: nil)
        }
    }

    @Test func writesCoverNextToVideo() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let id = await q.enqueue(job(dir, cover: .png, coverTime: Time(15, 30)))
        await q.runAll()
        let st = try #require(await q.status(id))
        guard case .done = st.state else { Issue.record("not done: \(st.state)"); return }
        let cover = try #require(st.coverURL)
        #expect(cover.lastPathComponent == "Clip Cover.png")
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(st.coverError == nil)
    }

    @Test func noCoverWhenOff() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let id = await q.enqueue(job(dir, cover: nil))
        await q.runAll()
        let st = try #require(await q.status(id))
        #expect(st.coverURL == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Clip Cover.png").path))
    }

    @Test func existingCoverIsNeverOverwritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("Clip Cover.jpg"))
        let q = ExportQueue()
        let id = await q.enqueue(job(dir, cover: .jpg))
        await q.runAll()
        let st = try #require(await q.status(id))
        #expect(st.coverURL?.lastPathComponent == "Clip 2 Cover.jpg")
        #expect(try Data(contentsOf: dir.appendingPathComponent("Clip Cover.jpg")) == Data([1]))
    }
}
