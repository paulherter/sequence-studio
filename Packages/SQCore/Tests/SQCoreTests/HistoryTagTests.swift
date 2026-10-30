import Foundation
import Testing
@testable import SQCore

/// Tags tie data outside the state to one undo step: they follow it through undo and redo and vanish with it.
@Suite struct HistoryTagTests {
    @Test func aMarkerIsAStepWithoutAChange() {
        var h = History(0)
        let t = UUID()
        h.pushMarker("Delete", tag: t)
        #expect(h.canUndo && h.undoName == "Delete" && h.undoTag == t && h.current == 0)
        h.undo()
        #expect(!h.canUndo && h.redoTag == t)
        h.redo()
        #expect(h.undoTag == t)
    }

    @Test func aTagFollowsAStepAndGoesWithIt() {
        var h = History(0, limit: 2)
        h.commit("A") { $0 = 1 }
        let t = UUID()
        #expect(h.tagNewestStep(t) && h.liveTags == [t])
        h.undo()
        h.commit("B") { $0 = 2 }                       // replaces the redo step
        #expect(h.liveTags.isEmpty)
        h.pushMarker("M", tag: UUID())
        h.commit("C") { $0 = 3 }
        h.commit("D") { $0 = 4 }                       // limit 2: the marker is trimmed
        #expect(h.liveTags.isEmpty)
    }

    @Test func rewindDropsTags() {
        var h = History(0)
        h.commit("A") { $0 = 1 }
        h.tagNewestStep(UUID())
        h.rewind(toDepth: 0)
        #expect(h.liveTags.isEmpty)
    }

    @Test func rewindReportsTheTagsItWithdrew() {
        var h = History(0)
        let a = UUID(), b = UUID()
        h.commit("A") { $0 = 1 }; h.tagNewestStep(a)
        h.commit("B") { $0 = 2 }; h.tagNewestStep(b)
        h.rewind(toDepth: 0)
        #expect(h.takeWithdrawnTags() == [b, a])         // newest first: the order to undo their effects
        #expect(h.takeWithdrawnTags().isEmpty)
    }

    @Test func aCanceledGestureReportsItsTag() {
        var h = History(0)
        h.commit("Drag", coalescing: "g") { $0 = 1 }
        let t = UUID()
        h.tagNewestStep(t)
        h.commit("Drag", coalescing: "g") { $0 = 0 }     // dragged back to the start: the step is dropped
        #expect(!h.canUndo && h.takeWithdrawnTags() == [t])
    }

    @Test func squashReportsTheTagsItMerged() {
        var h = History(0)
        let a = UUID(), b = UUID()
        h.commit("A") { $0 = 1 }; h.tagNewestStep(a)
        h.commit("B") { $0 = 2 }; h.tagNewestStep(b)
        h.commit("C") { $0 = 3 }
        h.squash(fromDepth: 0, name: "All")
        #expect(h.undoDepth == 1 && h.takeFoldedTags() == [a, b])
        #expect(h.undoTag == nil && h.liveTags.isEmpty)   // the caller tags the merged step again
    }

    @Test func squashWithoutTagsReportsNothing() {
        var h = History(0)
        h.commit("A") { $0 = 1 }
        h.commit("B") { $0 = 2 }
        h.squash(fromDepth: 0, name: "All")
        #expect(h.takeFoldedTags().isEmpty)
    }
}
