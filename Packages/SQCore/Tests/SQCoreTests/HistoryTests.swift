import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct HistoryTests {
    struct Boom: Error {}

    @Test func timelineRippleDeleteUndoRedo() throws {
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(2)), start: s(0))
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(2)), start: s(2))
        var t = Track(kind: .video)
        try t.overwrite(a); try t.overwrite(b)
        let original = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        var h = History(original)
        try h.commit("Ripple Delete") { _ = try $0.rippleDelete([a.id]) }
        let after = h.current
        #expect(after != original)
        #expect(h.undoName == "Ripple Delete")
        let rundo = h.undo(); #expect(rundo)
        #expect(h.current == original)
        #expect(h.redoName == "Ripple Delete")
        let rredo = h.redo(); #expect(rredo)
        #expect(h.current == after)
    }

    @Test func noOpCommitAddsNothing() {
        var h = History(1)
        h.commit("Nothing") { _ in }
        h.commit("Same") { $0 = 1 }
        #expect(!h.canUndo)
        #expect(!h.isDirty)
    }

    @Test func throwLeavesStateUntouched() {
        var h = History(1)
        h.commit("Inc") { $0 += 1 }
        _ = h.undo()
        var threw = false
        do { try h.commit("Bad") { $0 = 99; throw Boom() } } catch { threw = error is Boom }
        #expect(threw)
        #expect(h.current == 1)
        #expect(!h.canUndo)
        #expect(h.canRedo)
    }

    @Test func newCommitClearsRedo() {
        var h = History(0)
        h.commit("A") { $0 = 1 }
        _ = h.undo()
        #expect(h.canRedo)
        h.commit("B") { $0 = 2 }
        #expect(!h.canRedo)
        #expect(h.redoName == nil)
        let rredo = h.redo(); #expect(!rredo)
    }

    @Test func undoRedoOnEmptyReturnFalse() {
        var h = History(0)
        let rundo = h.undo(); #expect(!rundo)
        let rredo = h.redo(); #expect(!rredo)
    }

    @Test func coalescingMergesSameKey() {
        var h = History(0)
        h.commit("Move", coalescing: "drag") { $0 = 1 }
        h.commit("Move 2", coalescing: "drag") { $0 = 2 }
        h.commit("Move 3", coalescing: "drag") { $0 = 3 }
        #expect(h.undoName == "Move 3")
        let rundo = h.undo(); #expect(rundo)
        #expect(h.current == 0)
        #expect(!h.canUndo)
    }

    @Test func coalescingBreaksOnOtherKeyOrUndo() {
        var h = History(0)
        h.commit("A", coalescing: "x") { $0 = 1 }
        h.commit("B", coalescing: "y") { $0 = 2 }
        h.commit("C") { $0 = 3 }
        h.commit("D", coalescing: "y") { $0 = 4 }
        #expect(h.current == 4)
        _ = h.undo(); _ = h.undo(); _ = h.undo(); _ = h.undo()
        #expect(h.current == 0)
        #expect(!h.canUndo)

        var g = History(0)
        g.commit("A", coalescing: "x") { $0 = 1 }
        _ = g.undo(); _ = g.redo()
        g.commit("A2", coalescing: "x") { $0 = 2 }
        _ = g.undo()
        #expect(g.current == 1)
    }

    @Test func limitDropsOldest() {
        var h = History(0, limit: 3)
        for i in 1...5 { h.commit("c\(i)") { $0 = i } }
        var steps = 0
        while h.undo() { steps += 1 }
        #expect(steps == 3)
        #expect(h.current == 2)
    }

    @Test func dirtyTracking() {
        var h = History(0)
        #expect(!h.isDirty)
        h.commit("A") { $0 = 1 }
        #expect(h.isDirty)
        h.markSaved()
        #expect(!h.isDirty)
        h.commit("B") { $0 = 2 }
        #expect(h.isDirty)
        _ = h.undo()
        #expect(!h.isDirty)
        _ = h.undo()
        #expect(h.isDirty)
        _ = h.redo()
        #expect(!h.isDirty)
    }

    @Test func amendAllChangesEveryStateWithoutAnUndoStepOrDirt() {
        var h = History(1)
        h.commit("inc") { $0 += 1 }       // 1 -> 2
        h.commit("inc") { $0 += 1 }       // 2 -> 3
        h.markSaved()
        h.undo()                          // current 2, redo holds 3
        h.amendAll { $0 += 100 }
        #expect(h.current == 102)
        #expect(h.isDirty)   // saved was 3 + 100, current 102: still different
        h.redo(); #expect(h.current == 103)
        h.undo(); h.undo(); #expect(h.current == 101)
        #expect(h.undoName == nil)
    }

    @Test func amendAllKeepsCleanStateClean() {
        var h = History(1)
        h.amendAll { $0 += 1 }
        #expect(h.current == 2 && !h.isDirty && !h.canUndo)
    }
}
