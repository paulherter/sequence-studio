import Foundation
import Testing
@testable import SSLibrary

/// L3: the FSEvents callback context must outlive queued callbacks. A real FSEvents stream is used; events are
/// produced right before cancelling/dropping the token so callbacks are still queued when the stream is torn down.
@Suite struct FSEventsWatcherTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func noCallbackAfterCancel() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let counter = Counter()
        let token = FSEventsFolderWatcher(latency: 0.05).watch(dir.url) { counter.bump() }
        try dir.write("a.mp4")
        for _ in 0..<200 where counter.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(counter.value > 0)
        token.cancel()
        let after = counter.value
        for i in 0..<5 { try dir.write("b\(i).mp4") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.value == after)
        token.cancel() // idempotent
    }

    @Test func cancelAndDropWhileEventsAreQueuedStress() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        for round in 0..<150 {
            let counter = Counter()
            let token = FSEventsFolderWatcher(latency: 0.0).watch(dir.url) { counter.bump() }
            try dir.write("r\(round % 5).mp4", bytes: 4 + round)
            if round % 2 == 0 { token.cancel() }
            // odd rounds: dropped without cancel -> deinit path
        }
        try await Task.sleep(for: .milliseconds(200))
    }
}
