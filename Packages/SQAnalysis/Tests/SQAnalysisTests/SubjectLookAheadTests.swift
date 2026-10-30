import Foundation
import Synchronization
import Testing
@testable import SQAnalysis

@Suite struct SubjectLookAheadTests {
    final class Key {}

    @Test func takesTheResultStartedForItsKeyOnce() throws {
        let ahead = SubjectLookAhead<Int>(label: "test")
        let a = Key(), b = Key()
        ahead.start(a) { 7 }
        #expect(try ahead.take(b) == nil)
        #expect(try ahead.take(a) == 7)
        #expect(try ahead.take(a) == nil)
    }

    @Test func runsOnItsOwnThreadAndTakeWaitsForIt() throws {
        let ahead = SubjectLookAhead<Int>(label: "test")
        let a = Key()
        let caller = Thread.current
        let ranElsewhere = Mutex(false)
        ahead.start(a) {
            Thread.sleep(forTimeInterval: 0.05)
            ranElsewhere.withLock { $0 = Thread.current != caller }
            return 1
        }
        #expect(ahead.holds(a))
        #expect(try ahead.take(a) == 1)
        #expect(ranElsewhere.withLock { $0 })
    }

    @Test func aSecondStartForTheSameKeyDoesNotRunAgain() throws {
        let ahead = SubjectLookAhead<Int>(label: "test")
        let a = Key()
        let runs = Mutex(0)
        ahead.start(a) { runs.withLock { $0 += 1; return $0 } }
        ahead.start(a) { runs.withLock { $0 += 1; return $0 } }
        #expect(try ahead.take(a) == 1)
        #expect(runs.withLock { $0 } == 1)
    }

    @Test func theResultAskedNowStaysWhileTheNextOneRunsOneAtATime() throws {
        let ahead = SubjectLookAhead<Int>(label: "test")
        let a = Key(), b = Key(), c = Key()
        let inFlight = Mutex(0), most = Mutex(0)
        func work(_ v: Int) -> () -> Int {
            {
                let n = inFlight.withLock { $0 += 1; return $0 }
                most.withLock { $0 = max($0, n) }
                Thread.sleep(forTimeInterval: 0.02)
                inFlight.withLock { $0 -= 1 }
                return v
            }
        }
        // The lane: frame b looked ahead while frame a (looked ahead before) is answered.
        ahead.start(a, work(1))
        ahead.start(b, work(2))
        #expect(try ahead.take(a) == 1)
        ahead.start(c, work(3))
        #expect(try ahead.take(b) == 2)
        #expect(try ahead.take(c) == 3)
        #expect(most.withLock { $0 } == 1)
        // Never taken: only the last two are held.
        ahead.start(a, work(1)); ahead.start(b, work(2)); ahead.start(c, work(3))
        #expect(try ahead.take(a) == nil)
        #expect(try ahead.take(b) == 2)
        #expect(try ahead.take(c) == 3)
    }

    struct Boom: Error {}

    @Test func anErrorOfTheWorkIsThrownByTake() {
        let ahead = SubjectLookAhead<Int>(label: "test")
        let a = Key()
        ahead.start(a) { throw Boom() }
        #expect(throws: Boom.self) { try ahead.take(a) }
    }
}
