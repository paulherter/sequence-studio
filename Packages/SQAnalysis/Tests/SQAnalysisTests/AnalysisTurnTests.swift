import Foundation
import Synchronization
import Testing
@testable import SQAnalysis

@Suite struct AnalysisTurnTests {
    final class Log: Sendable {
        let events = Mutex<[String]>([])
        func add(_ e: String) { events.withLock { $0.append(e) } }
    }

    /// Two jobs that each yield between their steps never interleave: the second starts after the first ended.
    @Test func jobsDoNotAlternate() async throws {
        let turn = AnalysisTurn(), log = Log()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in ["a", "b"] {
                group.addTask {
                    try await turn.run {
                        for i in 0..<5 { log.add("\(name)\(i)"); await Task.yield(); try await Task.sleep(for: .milliseconds(2)) }
                    }
                }
                try await Task.sleep(for: .milliseconds(20))     // a is queued first
            }
            try await group.waitForAll()
        }
        #expect(log.events.withLock { $0 } == ["a0", "a1", "a2", "a3", "a4", "b0", "b1", "b2", "b3", "b4"])
    }

    @Test func canceledWaiterNeverRunsAndPassesNothingOn() async throws {
        let turn = AnalysisTurn(), log = Log()
        let release = Mutex(false), started = Mutex(false)
        let first = Task {
            try await turn.run {
                started.withLock { $0 = true }
                while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
                log.add("first")
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        let waiter = Task { try await turn.run { log.add("waiter") } }
        // A condition, not a time: the waiter is queued behind the first job.
        while turn.waitingCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        release.withLock { $0 = true }
        try await first.value
        try await turn.run { log.add("third") }                 // the turn was passed on, not lost
        #expect(log.events.withLock { $0 } == ["first", "third"])
    }

    @Test func aThrowingJobStillPassesTheTurn() async throws {
        struct Boom: Error {}
        let turn = AnalysisTurn()
        await #expect(throws: Boom.self) { try await turn.run { throw Boom() } }
        let v = try await turn.run { 3 }
        #expect(v == 3)
    }
}
