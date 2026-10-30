import Foundation
import Synchronization
import Testing
@testable import SQCore

@Suite struct BlockingLaneTests {
    /// The import hang (2026-10-03): every waveform build blocked a cooperative-pool thread in a synchronous read loop, so
    /// with as many media files as cores no other `await` (the next import's detached read, Task.sleep) ever ran again.
    /// Work on a lane must leave the pool free, however many jobs wait.
    @Test func manyBlockedJobsLeaveTheCooperativePoolFree() async throws {
        let lane = BlockingLane(label: "test.lane", width: 2)
        let release = DispatchSemaphore(value: 0)
        let jobs = ProcessInfo.processInfo.activeProcessorCount * 3
        let running = (0..<jobs).map { i in
            Task.detached { try await lane.run { _ in release.wait(); return i } }
        }
        // While every job is blocked (or queued), a detached task still runs.
        let probe = Task.detached { 42 }
        let got = try await withTimeout(seconds: 5) { await probe.value }
        #expect(got == 42)
        for _ in 0..<jobs { release.signal() }
        var sum = 0
        for t in running { sum += try await t.value }
        #expect(sum == (0..<jobs).reduce(0, +))
    }

    @Test func runsAtMostWidthJobsAtOnce() async throws {
        let lane = BlockingLane(label: "test.width", width: 2)
        final class Count: Sendable { let now = Mutex(0), peak = Mutex(0) }
        let count = Count()
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    try await lane.run { _ in
                        let n = count.now.withLock { $0 += 1; return $0 }
                        count.peak.withLock { $0 = max($0, n) }
                        Thread.sleep(forTimeInterval: 0.02)
                        count.now.withLock { $0 -= 1 }
                    }
                }
            }
            try await g.waitForAll()
        }
        #expect(count.peak.withLock { $0 } == 2)
    }

    @Test func cancellationReachesTheBlockingBody() async throws {
        let lane = BlockingLane(label: "test.cancel", width: 1)
        let started = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try await lane.run { isCancelled in
                started.signal()
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
                throw CancellationError()
            }
        }
        await withCheckedContinuation { c in DispatchQueue.global().async { started.wait(); c.resume() } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func stalledHasItsOwnWording() {
        let text = BlockingLane.Stalled().localizedDescription
        #expect(text == "The read stopped answering and was given up.")
        #expect(!text.contains("could not be read"))
    }

    /// A call that never returns (Vision, a decoder) must not hold a slot for the rest of the app run: without a beat
    /// for the deadline the caller gets `Stalled` and the next job runs.
    @Test func aJobWithoutABeatGivesItsSlotBack() async throws {
        let lane = BlockingLane(label: "test.stall", width: 1)
        let gate = DispatchSemaphore(value: 0)
        final class Seen: Sendable { let canceled = Mutex(false) }
        let seen = Seen()
        await #expect(throws: BlockingLane.Stalled.self) {
            try await lane.run(stallAfter: 0.1) { isCancelled, _ in
                gate.wait()
                seen.canceled.withLock { $0 = isCancelled() }
            }
        }
        let next = try await lane.run(stallAfter: 5) { _, _ in 7 }
        #expect(next == 7)
        gate.signal()
        for _ in 0..<200 where !seen.canceled.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.canceled.withLock { $0 })       // the thread that came back late knows it was given up
    }

    @Test func aJobThatBeatsMayTakeLongerThanTheDeadline() async throws {
        let lane = BlockingLane(label: "test.beat", width: 1)
        // Beats 30 times closer together than the deadline (a busy machine stretches a sleep), 2.5 s in all.
        let n = try await lane.run(stallAfter: 1.5) { _, beat in
            for _ in 0..<50 { Thread.sleep(forTimeInterval: 0.05); beat() }
            return 12
        }
        #expect(n == 12)
    }

    /// Stabilizer bug (2026-10-07): a job canceled while it waits for a slot must end at once, not when the busy job
    /// frees the slot (Cancel on the Analyze row did nothing while another analysis held the lane).
    @Test func cancellingAWaitingJobEndsItAtOnce() async throws {
        let lane = BlockingLane(label: "test.cancelWaiting", width: 1)
        let gate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        let blocker = Task.detached { try await lane.run { _ in started.signal(); gate.wait() } }
        await withCheckedContinuation { c in DispatchQueue.global().async { started.wait(); c.resume() } }
        final class Ran: Sendable { let m = Mutex(false) }
        let ran = Ran()
        let waiting = Task.detached { try await lane.run { _ in ran.m.withLock { $0 = true } } }
        while lane.waitingCount < 1 { try await Task.sleep(for: .milliseconds(2)) }
        waiting.cancel()
        let result = try await withTimeout(seconds: 2) { await waiting.result }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(lane.waitingCount == 0)
        gate.signal()
        try await blocker.value
        // The slot is free again: a new job runs, and the canceled one never ran.
        #expect(try await lane.run { _ in 7 } == 7)
        #expect(ran.m.withLock { $0 } == false)
    }

    /// What the user is looking at (the Source monitor's audio view) must not wait behind a whole import's waveforms.
    @Test func urgentJobsJumpTheQueue() async throws {
        let lane = BlockingLane(label: "test.urgent", width: 1)
        let gate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        final class Log: Sendable { let m = Mutex<[String]>([]); func add(_ s: String) { m.withLock { $0.append(s) } } }
        let order = Log()
        let blocker = Task.detached { try await lane.run { _ in started.signal(); gate.wait() } }
        await withCheckedContinuation { c in DispatchQueue.global().async { started.wait(); c.resume() } }
        func waitFor(_ n: Int) async throws { while lane.waitingCount < n { try await Task.sleep(for: .milliseconds(2)) } }
        let a = Task.detached { try await lane.run { _ in order.add("a") } }
        try await waitFor(1)
        let b = Task.detached { try await lane.run { _ in order.add("b") } }
        try await waitFor(2)
        let u = Task.detached { try await BlockingLane.$urgent.withValue(true) { try await lane.run { _ in order.add("u") } } }
        try await waitFor(3)
        gate.signal()
        _ = try await (blocker.value, a.value, b.value, u.value)
        #expect(order.m.withLock { $0 } == ["u", "a", "b"])
    }

    @Test func errorsAndValuesPassThrough() async throws {
        struct Boom: Error {}
        let lane = BlockingLane(label: "test.result", width: 1)
        #expect(try await lane.run { _ in "ok" } == "ok")
        await #expect(throws: Boom.self) { try await lane.run { _ in throw Boom() } }
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { g in
            g.addTask { await body() }
            g.addTask {
                // A dispatch timer, not Task.sleep: Task.sleep itself needs a free pool thread to resume.
                await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() } }
                return nil
            }
            guard let first = try await g.next(), let value = first else { g.cancelAll(); throw TimeoutError() }
            g.cancelAll()
            return value
        }
    }
    struct TimeoutError: Error {}
}
