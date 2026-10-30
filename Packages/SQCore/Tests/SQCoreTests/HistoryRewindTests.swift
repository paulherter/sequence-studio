import Testing
@testable import SQCore

@Suite struct HistoryRewindTests {
    private func make() -> History<Int> {
        var h = History(0)
        h.commit("A") { $0 = 1 }
        return h
    }

    @Test func rewindDropsStepsWithoutRedo() {
        var h = make()
        h.commit("B") { $0 = 2 }
        h.commit("C") { $0 = 3 }
        #expect(h.undoDepth == 3)
        h.rewind(toDepth: 1)
        #expect(h.current == 1 && h.undoDepth == 1 && h.undoName == "A")
        #expect(!h.canRedo)
    }

    @Test func rewindToTheCurrentDepthChangesNothing() {
        var h = make()
        h.rewind(toDepth: 1)
        #expect(h.current == 1 && h.undoDepth == 1)
        h.rewind(toDepth: 5)
        #expect(h.current == 1 && h.undoDepth == 1)
    }

    @Test func squashFoldsStepsAboveDepthIntoOne() {
        var h = make()
        h.commit("B") { $0 = 2 }
        h.commit("C") { $0 = 3 }
        h.squash(fromDepth: 1, name: "Add Text")
        #expect(h.current == 3 && h.undoDepth == 2 && h.undoName == "Add Text")
        h.undo()
        #expect(h.current == 1)
    }

    @Test func squashOfASingleStepOnlyRenames() {
        var h = make()
        h.squash(fromDepth: 0, name: "Renamed")
        #expect(h.undoDepth == 1 && h.undoName == "Renamed" && h.current == 1)
    }
}
