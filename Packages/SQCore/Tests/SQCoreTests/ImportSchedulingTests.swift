import Foundation
import Testing
@testable import SQCore

@Suite struct ImportCommitPlanTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    @Test func firstFinishedPrefixCommitsAtOnce() {
        var p = ImportCommitPlan(count: 5, interval: .milliseconds(250))
        #expect(p.finished(0, at: at(10)) == 0..<1)        // the bin shows something right away
        #expect(p.committed == 1)
    }

    @Test func onlyTheInOrderPrefixCommits() {
        var p = ImportCommitPlan(count: 4, interval: .milliseconds(250))
        #expect(p.finished(2, at: at(10)) == nil)           // 0 and 1 still probing: order in the bin stays the input order
        #expect(p.finished(1, at: at(20)) == nil)
        #expect(p.finished(0, at: at(30)) == 0..<3)
        #expect(p.finished(3, at: at(40)) == 3..<4)         // the last one always commits (nothing left to wait for)
        #expect(p.isComplete)
    }

    @Test func laterCommitsWaitForTheInterval() {
        var p = ImportCommitPlan(count: 10, interval: .milliseconds(250))
        #expect(p.finished(0, at: at(0)) == 0..<1)
        #expect(p.finished(1, at: at(100)) == nil)
        #expect(p.finished(2, at: at(200)) == nil)
        #expect(p.finished(3, at: at(260)) == 1..<4)
        #expect(p.finished(4, at: at(300)) == nil)
        #expect(p.flush() == 4..<5)                          // end of import / timer: whatever is ready
        #expect(p.flush() == nil)
    }

    @Test func flushHoldsBackItemsBehindAnUnfinishedOne() {
        var p = ImportCommitPlan(count: 3, interval: .milliseconds(250))
        _ = p.finished(1, at: at(0))
        _ = p.finished(2, at: at(0))
        #expect(p.flush() == nil)
        #expect(p.finished(0, at: at(1)) == 0..<3)
    }

    @Test func duplicateAndOutOfRangeReportsAreIgnored() {
        var p = ImportCommitPlan(count: 2, interval: .milliseconds(250))
        #expect(p.finished(0, at: at(0)) == 0..<1)
        #expect(p.finished(0, at: at(500)) == nil)
        #expect(p.finished(7, at: at(500)) == nil)
        #expect(p.finished(-1, at: at(500)) == nil)
        #expect(!p.isComplete)
    }
}

@Suite struct VisibleFirstQueueTests {
    @Test func servesInArrivalOrderWithoutVisibility() {
        var q = VisibleFirstQueue<Int>()
        for i in [3, 1, 2] { q.enqueue(i) }
        #expect(q.next() == 3)
        #expect(q.next() == 1)
        #expect(q.next() == 2)
        #expect(q.next() == nil)
    }

    @Test func visibleItemsJumpTheQueueInScreenOrder() {
        var q = VisibleFirstQueue<Int>()
        for i in 0..<10 { q.enqueue(i) }
        q.setVisible([8, 6, 7])                             // scrolled down: these are on screen, top-left first
        #expect(q.next() == 8)
        #expect(q.next() == 6)
        #expect(q.next() == 7)
        #expect(q.next() == 0)                              // then the rest, oldest request first
        #expect(q.next() == 1)
    }

    @Test func enqueueIsIdempotentAndKeepsTheFirstPlace() {
        var q = VisibleFirstQueue<String>()
        q.enqueue("a"); q.enqueue("b"); q.enqueue("a")
        #expect(q.count == 2)
        #expect(q.next() == "a")
        #expect(q.next() == "b")
    }

    @Test func visibleButNotRequestedIsNotServed() {
        var q = VisibleFirstQueue<Int>()
        q.setVisible([1, 2])
        q.enqueue(5)
        #expect(q.next() == 5)
        #expect(q.next() == nil)
        q.enqueue(2)                                         // requested later while on screen: first
        q.enqueue(9)
        #expect(q.next() == 2)
    }

    @Test func removeDropsAWaitingRequest() {
        var q = VisibleFirstQueue<Int>()
        for i in 0..<3 { q.enqueue(i) }
        q.remove(1)
        #expect(q.contains(0) && !q.contains(1))
        #expect(q.next() == 0)
        #expect(q.next() == 2)
        #expect(q.isEmpty)
    }

    @Test func manyItemsStayCheap() {
        var q = VisibleFirstQueue<Int>()
        for i in 0..<20_000 { q.enqueue(i) }
        q.setVisible(Array(19_990..<20_000))
        #expect(q.next() == 19_990)
        var n = 1
        while q.next() != nil { n += 1 }
        #expect(n == 20_000)
    }
}
