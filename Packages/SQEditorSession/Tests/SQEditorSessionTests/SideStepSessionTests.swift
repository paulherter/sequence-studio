import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Steps whose effect lives outside the project (deleted Magic mask frames) are history steps with a tag.
@MainActor @Suite struct SideStepSessionTests {
    final class Log { var undone = 0, redone = 0 }

    func make() -> EditorSession {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(),
                             autosaveStore: AutosaveStore(base: dir))
    }

    func register(_ s: EditorSession, _ log: Log, since: Int? = nil) {
        s.registerSideStep("Delete", since: since ?? s.undoStepDepth,
                           undo: { log.undone += 1 }, redo: { log.redone += 1 })
    }

    @Test func aFramesOnlyDeleteIsAStepThatMarksTheProjectDirty() {
        let s = make(), log = Log()
        #expect(!s.isDirty)
        register(s, log)
        #expect(s.isDirty && s.undoName == "Delete")
        #expect(s.undo() && log.undone == 1)
        #expect(s.isDirty)
        #expect(s.redo() && log.redone == 1)
    }

    @Test func aDeleteThatAlsoChangesTheClipIsOneUndo() throws {
        let s = make(), log = Log()
        let depth = s.undoStepDepth
        try s.perform("Delete Keyframes") { $0.name = "Changed" }
        register(s, log, since: depth)
        #expect(s.undoStepDepth == depth + 1)
        #expect(s.undo() && log.undone == 1)
        #expect(!s.canUndo)
    }

    @Test func aStepFromAnOldProjectNeverFiresAfterReplace() throws {
        let s = make(), log = Log()
        register(s, log)
        s.newProject()
        #expect(!s.canUndo)
        try s.perform("Edit") { $0.name = "B" }
        #expect(s.undo() && log.undone == 0)
    }

    @Test func aRewoundStepIsGone() throws {
        let s = make(), log = Log()
        let depth = s.undoStepDepth
        register(s, log)
        s.rewindUndo(toDepth: depth)
        #expect(log.undone == 1)                          // withdrawn with its change still in effect: reverted now
        try s.perform("Edit") { $0.name = "B" }
        #expect(s.undo())
        #expect(!s.canUndo && log.undone == 1)            // and never again
    }

    @Test func aCanceledGestureRevertsItsSideStep() throws {
        let s = make(), log = Log()
        let depth = s.undoStepDepth
        try s.perform("Drag", coalescing: "g") { $0.name = "Changed" }
        register(s, log, since: depth)
        #expect(log.undone == 0)
        try s.perform("Drag", coalescing: "g") { $0.name = "Untitled" }   // back to the start: the step is dropped
        #expect(!s.canUndo && log.undone == 1)
    }

    /// Two side steps registered on one coalesced step (two frame deletes in one drag): the second must not replace
    /// the first, which would lose it without ever running it.
    @Test func aSecondSideStepOnTheSameStepKeepsTheFirst() throws {
        let s = make()
        var order: [String] = []
        let depth = s.undoStepDepth
        try s.perform("Drag", coalescing: "g") { $0.name = "Changed" }
        s.registerSideStep("A", since: depth, undo: { order.append("undoA") }, redo: { order.append("redoA") })
        try s.perform("Drag", coalescing: "g") { $0.name = "Changed more" }
        s.registerSideStep("B", since: depth, undo: { order.append("undoB") }, redo: { order.append("redoB") })
        #expect(s.undoStepDepth == depth + 1)
        #expect(s.undo())
        #expect(order == ["undoB", "undoA"])
        #expect(s.redo())
        #expect(order == ["undoB", "undoA", "redoA", "redoB"])
        // Canceled back to the start: both come back out, newest first.
        order = []
        let d2 = s.undoStepDepth
        try s.perform("Drag", coalescing: "h") { $0.name = "X" }
        s.registerSideStep("C", since: d2, undo: { order.append("undoC") }, redo: {})
        s.registerSideStep("D", since: d2, undo: { order.append("undoD") }, redo: {})
        try s.perform("Drag", coalescing: "h") { $0.name = "Changed more" }
        #expect(order == ["undoD", "undoC"])
    }

    /// A tagged step pushed over the history limit is trimmed with its tag: its change stays (no step left to undo it),
    /// nothing runs, and the steps that remain undo and redo as before.
    @Test func aTrimmedTaggedStepIsDroppedWithoutRunning() throws {
        let s = make(), log = Log()
        register(s, log)
        let limit = s.history.limit
        for i in 0..<(limit + 5) { try s.perform("Edit \(i)") { $0.name = "N\(i)" } }
        #expect(s.undoStepDepth == limit + 6 && s.history.undoNames.count == limit)
        var undone = 0
        while s.undo() { undone += 1 }
        #expect(undone == limit)
        #expect(log.undone == 0 && log.redone == 0)
        while s.redo() {}
        #expect(log.undone == 0 && log.redone == 0)
    }

    @Test func foldedStepsUndoAndRedoAsOneInOrder() throws {
        let s = make()
        var order: [String] = []
        let depth = s.undoStepDepth
        try s.perform("Add") { $0.name = "A" }
        s.registerSideStep("One", since: depth, undo: { order.append("undo1") }, redo: { order.append("redo1") })
        try s.perform("Edit") { $0.name = "B" }
        s.registerSideStep("Two", since: depth + 1, undo: { order.append("undo2") }, redo: { order.append("redo2") })
        s.foldUndo(fromDepth: depth, name: "Folded")
        #expect(s.undoStepDepth == depth + 1)
        #expect(order.isEmpty)
        #expect(s.undo())
        #expect(order == ["undo2", "undo1"] && !s.canUndo)
        #expect(s.redo())
        #expect(order == ["undo2", "undo1", "redo1", "redo2"])
    }

    @Test func aNewEditDropsTheRedoStep() throws {
        let s = make(), log = Log()
        register(s, log)
        #expect(s.undo() && log.undone == 1)
        try s.perform("Edit") { $0.name = "B" }
        #expect(!s.canRedo)
        #expect(s.undo() && log.undone == 1 && !s.canUndo)
    }

    @Test func aStepIsOrderedWithTheEditsAroundIt() throws {
        let s = make(), log = Log()
        try s.perform("A") { $0.name = "A" }
        register(s, log)
        try s.perform("B") { $0.name = "B" }
        #expect(s.undo() && log.undone == 0)
        #expect(s.undo() && log.undone == 1)
        #expect(s.undo() && log.undone == 1)
    }
}
