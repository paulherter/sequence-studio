import Foundation
import SQCore
import Testing
@testable import SQProxy

/// Fake transcoder: each call waits until `release(source)` is called (or the task is cancelled).
final class FakeTranscoder: ProxyTranscoding, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var _started: [String] = []
    private var _running = 0, _maxRunning = 0
    var failing: Set<String> = []
    var started: [String] { lock.withLock { _started } }
    var maxRunning: Int { lock.withLock { _maxRunning } }

    func release(_ name: String) {
        lock.lock()
        if let g = gates.removeValue(forKey: name) { lock.unlock(); g.resume() } else { released.insert(name); lock.unlock() }
    }

    func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        let name = source.lastPathComponent
        lock.withLock { _started.append(name); _running += 1; _maxRunning = max(_maxRunning, _running) }
        defer { lock.withLock { _running -= 1 } }
        progress(0.5)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released.contains(name) || Task.isCancelled { lock.unlock(); c.resume() } else { gates[name] = c; lock.unlock() }
            }
        } onCancel: { [self] in
            lock.lock(); let g = gates.removeValue(forKey: name); lock.unlock(); g?.resume()
        }
        try Task.checkCancellation()
        if failing.contains(name) { throw Failure() }
        try Data("proxy".utf8).write(to: destination)
        progress(1)
        return TranscodeOutput(dimensions: ProxyDimensions(width: 960, height: 540), sourceDuration: Time(10, 1))
    }
}

private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
    return false
}

@Suite struct QueueTests {
    func setup(limit: Int = 1, files: [String] = ["a.mov", "b.mov", "c.mov"]) throws
        -> (ProxyQueue, FakeTranscoder, ProxyCache, [URL], URL) {
        let dir = try makeTempDir()
        var urls: [URL] = []
        for (i, f) in files.enumerated() {
            let u = dir.appendingPathComponent(f); try writeFile(u, bytes: 1000, seed: UInt8(i + 1)); urls.append(u)
        }
        let cache = ProxyCache(directory: dir.appendingPathComponent("cache"))
        let t = FakeTranscoder()
        return (ProxyQueue(cache: cache, transcoder: t, concurrency: limit), t, cache, urls, dir)
    }

    @Test func runsOneAtATimeAndRegistersInCache() async throws {
        let (q, t, cache, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j1 = try await q.enqueue(urls[0], kind: .proxyHalf)
        let j2 = try await q.enqueue(urls[1], kind: .proxyHalf)
        #expect(await waitUntil { await q.info(j1)?.state == .running })
        #expect(await q.info(j2)?.state == .queued)
        t.release("a.mov")
        #expect(await waitUntil { await q.info(j2)?.state == .running })
        t.release("b.mov")
        #expect(await waitUntil { await q.info(j2)?.isDone == true })
        #expect(t.maxRunning == 1)
        let fp = try SourceFingerprint.compute(for: urls[0])
        let rec = try #require(cache.lookup(fingerprint: fp, kind: .proxyHalf))
        #expect(rec.dimensions == ProxyDimensions(width: 960, height: 540))
        #expect(await q.info(j1)?.progress == 1)
    }

    @Test func concurrencyLimitTwo() async throws {
        let (q, t, _, urls, dir) = try setup(limit: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        for u in urls { _ = try await q.enqueue(u, kind: .proxyQuarter) }
        #expect(await waitUntil { t.started.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(t.started.count == 2)
        t.release("a.mov"); t.release("b.mov"); t.release("c.mov")
        #expect(await waitUntil { await q.allJobs().allSatisfy { $0.isDone } })
        #expect(t.maxRunning == 2)
    }

    @Test func dedupeQueuedRunningAndCached() async throws {
        let (q, t, _, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j1 = try await q.enqueue(urls[0], kind: .proxyHalf)
        let again = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(j1 == again)
        let other = try await q.enqueue(urls[0], kind: .optimized)
        #expect(other != j1)
        t.release("a.mov")
        #expect(await waitUntil { await q.info(j1)?.isDone == true })
        let cached = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(cached == j1)
        #expect(t.started.filter { $0 == "a.mov" }.count == 1 || t.started.count == 2)
    }

    /// P4: enqueue must not dedupe to a running job whose cancel was already requested.
    @Test func enqueueAfterCancelRequestStartsFreshJob() async throws {
        let (q, t, _, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j1 = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(await waitUntil { await q.info(j1)?.state == .running })
        await q.cancel(j1)
        let j2 = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(j2 != j1)
        #expect(await waitUntil { await q.info(j1)?.state == .cancelled })
        #expect(await waitUntil { t.started.count == 2 })
        t.release("a.mov")
        #expect(await waitUntil { await q.info(j2)?.isDone == true })
    }

    /// P5: a job that already runs before start() keeps its partial; unrelated partials are purged.
    @Test func startDoesNotPurgePartialOfRunningJob() async throws {
        let (q, _, cache, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j1 = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(await waitUntil { await q.info(j1)?.state == .running })
        let fp = try SourceFingerprint.compute(for: urls[0])
        let mine = cache.partialURL(fingerprint: fp, kind: .proxyHalf)
        let stray = cache.directory.appendingPathComponent("stray.mov.partial")
        try Data("x".utf8).write(to: mine); try Data("x".utf8).write(to: stray)
        await q.start()
        #expect(FileManager.default.fileExists(atPath: mine.path))
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func cachedWithoutJobReturnsDoneJob() async throws {
        let (q, _, cache, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fp = try SourceFingerprint.compute(for: urls[0])
        let r = ProxyRecord(fingerprint: fp, kind: .proxyHalf, fileName: ProxyCache.fileName(for: fp, kind: .proxyHalf),
                            dimensions: .init(width: 2, height: 2), createdAt: Date(), sourceDuration: Time(1, 1))
        let p = cache.partialURL(fingerprint: fp, kind: .proxyHalf)
        try Data("x".utf8).write(to: p)
        try cache.commit(partial: p, record: r)
        let j = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(await q.info(j)?.isDone == true)
    }

    @Test func failureAndCancel() async throws {
        let (q, t, cache, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        t.failing = ["a.mov"]
        let ja = try await q.enqueue(urls[0], kind: .proxyHalf)
        let jb = try await q.enqueue(urls[1], kind: .proxyHalf)
        let jc = try await q.enqueue(urls[2], kind: .proxyHalf)
        #expect(await waitUntil { await q.info(ja)?.state == .running })
        t.release("a.mov")
        #expect(await waitUntil { if case .failed = await q.info(ja)?.state { true } else { false } })
        // b is running now: cancel it, c queued: cancel it
        #expect(await waitUntil { await q.info(jb)?.state == .running })
        await q.cancel(jb)
        await q.cancel(jc)
        #expect(await waitUntil { await q.info(jb)?.state == .cancelled })
        #expect(await q.info(jc)?.state == .cancelled)
        let fp = try SourceFingerprint.compute(for: urls[1])
        #expect(cache.lookup(fingerprint: fp, kind: .proxyHalf) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.partialURL(fingerprint: fp, kind: .proxyHalf).path))
        // failed jobs can be retried
        t.failing = []
        let retry = try await q.enqueue(urls[0], kind: .proxyHalf)
        #expect(retry != ja)
    }

    @Test func cancelAll() async throws {
        let (q, _, _, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        for u in urls { _ = try await q.enqueue(u, kind: .proxyHalf) }
        await q.cancelAll()
        #expect(await waitUntil { await q.allJobs().allSatisfy { $0.state == .cancelled } })
    }

    @Test func jobStreamReportsProgressAndEnds() async throws {
        let (q, t, _, urls, dir) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = try await q.enqueue(urls[0], kind: .proxyHalf)
        let stream = await q.updates(for: j)
        t.release("a.mov")
        var last: ProxyJobInfo?
        for await i in stream { last = i }
        #expect(last?.isDone == true)
    }
}
