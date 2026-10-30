import Testing
@testable import SQDrawKit

@Suite struct PointerLockTrackerTests {
    @Test func lockedDragCountsRawDeltasPastTheScreenEdge() {
        var t = PointerLockTracker()
        #expect(t.drag(x: 100, y: 50, dx: 3, dy: 0, locked: false) == (100, 50))
        // The lock begins on this move: panels see the real spot, the pointer pins there.
        #expect(t.drag(x: 104, y: 50, dx: 4, dy: 0, locked: true) == (104, 50))
        // The real pointer no longer moves; the deltas do.
        let p = t.drag(x: 104, y: 50, dx: 10, dy: -2, locked: true)
        #expect(p == (114, 48))
        #expect(t.drag(x: 104, y: 50, dx: 2000, dy: 0, locked: true).x == 2114)
        #expect(t.release(x: 104, y: 50) == (2114, 48))
        #expect(!t.isLocked)
    }

    @Test func unlockedDragAndReleaseUseTheRealPosition() {
        var t = PointerLockTracker()
        #expect(t.drag(x: 5, y: 6, dx: 1, dy: 1, locked: false) == (5, 6))
        #expect(t.release(x: 7, y: 8) == (7, 8))
    }
}
