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

    @Test func coalescedCommitBackToTheStartDropsTheStep() {
        var h = History(1)
        h.commit("Before") { $0 = 5 }
        h.commit("Change Opacity", coalescing: "g") { $0 = 6 }
        h.commit("Change Opacity", coalescing: "g") { $0 = 7 }
        h.commit("Cancel", coalescing: "g") { $0 = 5 }    // Esc: back to where the gesture began
        #expect(h.current == 5)
        #expect(h.undoName == "Before")
        #expect(!h.canRedo)
        h.undo(); #expect(h.current == 1)
    }

    /// A canceled gesture is as if it never began: what could be redone before it can still be redone.
    @Test func aCanceledGestureGivesTheRedoStepsBack() {
        var h = History(1)
        h.commit("A") { $0 = 2 }
        h.commit("B") { $0 = 3 }
        h.undo(); h.undo()
        h.redo()                                         // at 2, "B" can be redone
        h.commit("Drag", coalescing: "g") { $0 = 10 }
        #expect(!h.canRedo)
        h.amendAll { $0 += 100 }                         // a background refinement reaches the held steps too
        h.commit("Drag", coalescing: "g") { $0 = 111 }
        h.commit("Drag", coalescing: "g") { $0 = 102 }   // Esc
        #expect(h.current == 102 && h.undoName == "A" && h.redoName == "B")
        h.redo(); #expect(h.current == 103)
        // A finished gesture, or anything else in between, leaves Redo empty.
        h.undo()
        h.commit("Drag", coalescing: "g") { $0 = 110 }
        h.commit("Other") { $0 = 120 }
        #expect(!h.canRedo)
        h.undo(); h.undo(); #expect(h.current == 102 && h.redoName == "Drag")
        h.commit("Drag", coalescing: "k") { $0 = 110 }
        h.undo()
        h.commit("Drag", coalescing: "k") { $0 = 111 }   // a new step after the undo, not a merge
        #expect(h.undoName == "Drag" && !h.canRedo)
    }

    /// Mouse up ends the gesture: what it kept aside for a cancel is let go at once, and a later commit with the same
    /// key that happens to return to the gesture's start is a step of its own, not a cancel.
    @Test func anEndedGestureLetsItsHeldRedoGo() {
        var h = History(1)
        h.commit("A") { $0 = 2 }
        h.commit("B") { $0 = 3 }
        h.undo()
        h.commit("Drag", coalescing: "g") { $0 = 10 }
        #expect(h.holdsRedo)
        h.endCoalescing()
        #expect(!h.holdsRedo)
        h.commit("Drag", coalescing: "g") { $0 = 2 }
        #expect(h.undoName == "Drag" && !h.canRedo)
        h.undo(); #expect(h.current == 10)
        h.undo(); #expect(h.current == 2)
    }

    /// A gesture that began at the undo limit pushed the oldest step out: canceled, that step is back.
    @Test func aCanceledGestureAtTheLimitGivesTheOldestStepBack() {
        var h = History(0, limit: 3)
        for i in 1...3 { h.commit("c\(i)") { $0 = i } }
        let depth = h.undoDepth
        h.commit("Drag", coalescing: "g") { $0 = 10 }
        #expect(h.undoDepth == depth + 1)
        h.amendAll { $0 += 100 }
        h.commit("Drag", coalescing: "g") { $0 = 103 }   // Esc
        #expect(h.undoDepth == depth && h.undoName == "c3")
        var steps = 0
        while h.undo() { steps += 1 }
        #expect(steps == 3 && h.current == 100)
        // A finished gesture at the limit does drop the oldest step.
        var k = History(0, limit: 3)
        for i in 1...3 { k.commit("c\(i)") { $0 = i } }
        k.commit("Drag", coalescing: "g") { $0 = 10 }
        k.endCoalescing()
        k.commit("Drag", coalescing: "g") { $0 = 3 }
        steps = 0
        while k.undo() { steps += 1 }
        #expect(steps == 3 && k.current == 2)
    }

    @Test func coalescedCommitBackToTheStartDoesNotMergeTheNextGesture() {
        var h = History(1)
        h.commit("A", coalescing: "g") { $0 = 2 }
        h.commit("A", coalescing: "g") { $0 = 1 }        // canceled
        #expect(!h.canUndo)
        h.commit("B", coalescing: "g") { $0 = 3 }
        h.commit("B", coalescing: "g") { $0 = 4 }
        #expect(h.undoName == "B")
        h.undo(); #expect(h.current == 1 && !h.canUndo)
    }

    @Test func amendAllKeepsCleanStateClean() {
        var h = History(1)
        h.amendAll { $0 += 1 }
        #expect(h.current == 2 && !h.isDirty && !h.canUndo)
    }
}
