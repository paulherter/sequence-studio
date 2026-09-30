import Testing
import Foundation
import SSCore
@testable import SSExport

@Suite struct ExportQueueTests {
    func job(_ name: String, dir: URL, frames: Int = 6, slow: Bool = false, fail: Bool = false) -> ExportJob {
        ExportJob(name: name, settings: smallSettings(codec: .h264), outputDirectory: dir) {
            let p = TestPatternSource(width: 64, height: 112, frameCount: frames, frameDuration: Time(1, 30))
            if fail { throw ExportError.emptySource }
            return ExportSources(video: slow ? SlowSource(inner: p) : p, audio: nil)
        }
    }

    func waitUntil(_ timeout: Duration = .seconds(10), _ cond: @escaping @Sendable () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func runsJobsSequentiallyAndFinishes() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let a = await q.enqueue(job("A", dir: dir)), b = await q.enqueue(job("B", dir: dir)), c = await q.enqueue(job("C", dir: dir))
        #expect(await q.status(a)?.state == .waiting)
        await q.runAll()
        for id in [a, b, c] {
            let st = try #require(await q.status(id))
            guard case .done(let url) = st.state else { Issue.record("not done: \(st.state)"); continue }
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(st.progress == 1.0)
        }
    }

    @Test func eventsShowSequentialOrderAndProgress() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let events = await q.updates()
        let a = await q.enqueue(job("A", dir: dir)), b = await q.enqueue(job("B", dir: dir))
        let collector = Task { () -> [ExportQueue.Update] in
            var all: [ExportQueue.Update] = []
            for await u in events {
                all.append(u)
                if case .done = u.state, u.id == b { break }
            }
            return all
        }
        await q.runAll()
        let all = await collector.value
        let firstB = try #require(all.firstIndex { $0.id == b && $0.state == .running })
        let doneA = try #require(all.firstIndex { $0.id == a && { if case .done = $0.state { true } else { false } }($0) })
        #expect(doneA < firstB, "B must not start before A is done")
        let progA = all.filter { $0.id == a }.map(\.progress)
        #expect(zip(progA, progA.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(progA.last == 1.0)
    }

    @Test func uniqueFileNamesPerSequence() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0]).write(to: dir.appendingPathComponent("Clip.mp4")) // pre-existing
        let q = ExportQueue()
        let ids = [await q.enqueue(job("Clip", dir: dir)), await q.enqueue(job("Clip", dir: dir)), await q.enqueue(job("Clip", dir: dir))]
        var names: [String] = []
        for id in ids { names.append(try #require(await q.status(id)).outputURL.lastPathComponent) }
        #expect(Set(names).count == 3)
        #expect(names == ["Clip 2.mp4", "Clip 3.mp4", "Clip 4.mp4"])
        await q.runAll()
        for n in names { #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path)) }
        #expect(try Data(contentsOf: dir.appendingPathComponent("Clip.mp4")) == Data([0]))
    }

    @Test func unsafeNamesAreSanitized() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let id = await q.enqueue(job("a/b:c", dir: dir))
        let url = try #require(await q.status(id)).outputURL
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(url.lastPathComponent == "a-b-c.mp4")
    }

    @Test func failedJobDoesNotStopQueue() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let a = await q.enqueue(job("Bad", dir: dir, fail: true)), b = await q.enqueue(job("Good", dir: dir))
        await q.runAll()
        if case .failed = try #require(await q.status(a)).state {} else { Issue.record("A should fail") }
        if case .done = try #require(await q.status(b)).state {} else { Issue.record("B should be done") }
    }

    @Test func cancelWaitingJob() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let a = await q.enqueue(job("A", dir: dir)), b = await q.enqueue(job("B", dir: dir))
        await q.cancel(b)
        await q.runAll()
        #expect(await q.status(b)?.state == .cancelled)
        if case .done = try #require(await q.status(a)).state {} else { Issue.record("A should be done") }
        #expect(!FileManager.default.fileExists(atPath: try #require(await q.status(b)).outputURL.path))
    }

    @Test func cancelRunningJobContinuesWithNext() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        let a = await q.enqueue(job("Slow", dir: dir, frames: 300, slow: true)), b = await q.enqueue(job("Next", dir: dir))
        let runner = Task { await q.runAll() }
        #expect(await waitUntil { await q.status(a)?.state == .running })
        await q.cancel(a)
        await runner.value
        #expect(await q.status(a)?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: try #require(await q.status(a)).outputURL.path))
        if case .done = try #require(await q.status(b)).state {} else { Issue.record("B should be done") }
    }
}
