import Foundation
import SQCore
import Testing
@testable import SQProxy

/// Q-PERF2 rec 3: a held queue (thermal "fair" or Low Power Mode) starts no new jobs; a running job finishes.
@Suite struct QueueHoldTests {
    private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<SQTiming.polls(400) { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return false
    }

    @Test func heldQueueStartsNothingUntilReleased() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        try writeFile(a, bytes: 1000, seed: 1); try writeFile(b, bytes: 1000, seed: 2)
        let t = FakeTranscoder()
        let q = ProxyQueue(cache: ProxyCache(directory: dir.appendingPathComponent("cache")), transcoder: t, concurrency: 1)
        let j1 = try await q.enqueue(a, kind: .proxyHalf)
        #expect(await waitUntil { await q.info(j1)?.state == .running })
        await q.setHeld(true)
        #expect(await q.isHeld)
        let j2 = try await q.enqueue(b, kind: .proxyHalf)
        t.release("a.mov")                                          // the running job finishes while held
        #expect(await waitUntil { await q.info(j1)?.isDone == true })
        try await Task.sleep(for: SQTiming.budget(.milliseconds(50)))
        #expect(await q.info(j2)?.state == .queued)                 // ...but the next one does not start
        #expect(t.started == ["a.mov"])
        await q.setHeld(false)
        #expect(await waitUntil { await q.info(j2)?.state == .running })
        t.release("b.mov")
        #expect(await waitUntil { await q.info(j2)?.isDone == true })
    }

    /// Within one priority the lower rank starts first (timeline-first ordering); `setRank` reorders queued jobs.
    @Test func lowerRankStartsFirstAndSetRankReorders() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["a.mov", "b.mov", "c.mov"]
        for (i, n) in names.enumerated() { try writeFile(dir.appendingPathComponent(n), bytes: 1000, seed: UInt8(i + 1)) }
        let t = FakeTranscoder()
        let q = ProxyQueue(cache: ProxyCache(directory: dir.appendingPathComponent("cache")), transcoder: t, concurrency: 1)
        await q.setHeld(true)
        let ja = try await q.enqueue(dir.appendingPathComponent("a.mov"), kind: .proxyHalf, rank: 2)
        let jb = try await q.enqueue(dir.appendingPathComponent("b.mov"), kind: .proxyHalf, rank: 1)
        let jc = try await q.enqueue(dir.appendingPathComponent("c.mov"), kind: .proxyHalf, rank: 3)
        await q.setRank(jc, 0)
        await q.setHeld(false)
        #expect(await waitUntil { await q.info(jc)?.state == .running })
        t.release("c.mov")
        #expect(await waitUntil { await q.info(jb)?.state == .running })
        t.release("b.mov")
        #expect(await waitUntil { await q.info(ja)?.state == .running })
        #expect(await waitUntil { t.started.count == 3 })
        #expect(t.started == ["c.mov", "b.mov", "a.mov"])
        t.release("a.mov")
    }
}
