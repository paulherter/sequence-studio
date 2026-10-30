import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@Suite struct HistoryListTests {
    @Test func emptyHistoryHasOnlyTheOriginal() {
        let l = HistoryList(undoNames: [], redoNames: [])
        #expect(l.rows.map(\.title) == ["Original"])
        #expect(l.rows[0].isCurrent)
        #expect(l.steps(to: 0) == 0)
    }

    @Test func undoneStepsFollowTheCurrentRow() {
        let l = HistoryList(undoNames: ["A", "B"], redoNames: ["C", "D"])
        #expect(l.rows.map(\.title) == ["Original", "A", "B", "C", "D"])
        #expect(l.rows.filter(\.isCurrent).map(\.title) == ["B"])
        #expect(l.rows.map(\.isUndone) == [false, false, false, true, true])
        #expect(l.steps(to: 0) == -2)
        #expect(l.steps(to: 4) == 2)
        #expect(l.steps(to: 9) == 0)
    }

    @Test func historyNamesAreOrderedOldestFirst() {
        var h = History(0)
        h.commit("One") { $0 = 1 }
        h.commit("Two") { $0 = 2 }
        h.commit("Three") { $0 = 3 }
        h.undo(); h.undo()
        #expect(h.undoNames == ["One"])
        #expect(h.redoNames == ["Two", "Three"])
        let l = HistoryList(undoNames: h.undoNames, redoNames: h.redoNames)
        #expect(l.rows.map(\.title) == ["Original", "One", "Two", "Three"])
        #expect(l.position == 1)
    }
}
