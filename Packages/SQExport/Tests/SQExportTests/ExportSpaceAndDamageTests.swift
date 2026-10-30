import Testing
import Foundation
import SQCore
@testable import SQExport

/// Free-space watch while an export runs, space estimate before it, and the damaged-media pre-flight.
@Suite struct ExportSpaceAndDamageTests {
    @Test func spaceVerdictComparesEstimateWithFreeSpace() {
        #expect(ExportPreflight.spaceVerdict(freeBytes: nil, estimatedBytes: 1_000) == .ok)
        #expect(ExportPreflight.spaceVerdict(freeBytes: 50_000_000_000, estimatedBytes: 1_000_000_000) == .ok)
        // Fits, but less than 20 % is left over: tight.
        #expect(ExportPreflight.spaceVerdict(freeBytes: 1_100_000_000, estimatedBytes: 1_000_000_000) == .tight)
        #expect(ExportPreflight.spaceVerdict(freeBytes: 500_000_000, estimatedBytes: 1_000_000_000) == .insufficient)
    }

    @Test func runningOutOfSpaceStopsTheJobAndRemovesTheFile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue(freeSpaceProbe: { _ in 10 }, minimumFreeBytes: 1_000, checkInterval: .milliseconds(20))
        let job = ExportJob(name: "Big", settings: smallSettings(codec: .h264), outputDirectory: dir) {
            let p = TestPatternSource(width: 64, height: 112, frameCount: 300, frameDuration: Time(1, 30))
            return ExportSources(video: SlowSource(inner: p), audio: nil)
        }
        let id = await q.enqueue(job)
        await q.runAll()
        let st = try #require(await q.status(id))
        guard case .failed(let message) = st.state else { Issue.record("not failed: \(st.state)"); return }
        #expect(message.contains("ran out of space"))
        #expect(!FileManager.default.fileExists(atPath: st.outputURL.path))
    }

    @Test func plentyOfSpaceDoesNotInterfere() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue(freeSpaceProbe: { _ in 500_000_000_000 }, minimumFreeBytes: 1_000, checkInterval: .milliseconds(20))
        let job = ExportJob(name: "Ok", settings: smallSettings(codec: .h264), outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 6, frameDuration: Time(1, 30)), audio: nil)
        }
        let id = await q.enqueue(job)
        await q.runAll()
        guard case .done = try #require(await q.status(id)).state else { Issue.record("not done"); return }
    }

    @Test func unreadableMediaListsEmptyAndGarbageFilesButNotGoodOrMissingOnes() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.mov"); try Data().write(to: empty)
        let junk = dir.appendingPathComponent("junk.mp4"); try Data(repeating: 7, count: 4096).write(to: junk)
        func ref(_ n: String, _ u: URL, size: Int64) -> MediaRef { MediaRef(name: n, path: u.path, fingerprint: MediaFingerprint(size: size)) }
        let gone = MediaRef(name: "gone", path: dir.appendingPathComponent("gone.mov").path, fingerprint: MediaFingerprint(size: 1))
        let media = [ref("empty", empty, size: 0), ref("junk", junk, size: 4096), gone]
        let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let clips = media.map { Clip(name: $0.name, media: $0.id, kind: .video, source: TimeRange(start: .zero, duration: Time(30, 30)), start: .zero) }
        let tl = Timeline(name: "T", format: fmt, tracks: [Track(kind: .video, clips: clips)])
        let p = Project(name: "P", media: media, timelines: [tl])
        let bad = await ExportPreflight.unreadableMedia(in: tl.id, project: p)
        #expect(Set(bad.map(\.name)) == ["empty", "junk"])
    }
}
