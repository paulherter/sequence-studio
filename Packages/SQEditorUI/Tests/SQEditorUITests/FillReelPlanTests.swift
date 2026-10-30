import Foundation
import Testing
import SQCore
@testable import SQEditorUI

// Fill Reel…: which picked items go into the slots, which are left out and what the sheet says about it.
@Suite struct FillReelPlanTests {
    private func item(_ name: String, still: Bool = false, length: Bool = true) -> FillReelPlan.Item {
        FillReelPlan.Item(id: UUID(), name: name, isStill: still, hasLength: length)
    }

    @Test func itemsFillSlotsInOrder() {
        let a = item("A"), b = item("B"), c = item("C")
        let p = FillReelPlan(slotCount: 3, items: [a, b, c])
        #expect(p.fillable == [a.id, b.id, c.id])
        #expect(p.unfilledSlots == 0 && p.unusedItems == 0 && p.canRun)
        #expect(p.note == nil)
    }

    @Test func unreadableItemsAreLeftOutAndStillsTakeASlot() {
        let a = item("A"), s = item("Photo", still: true), u = item("Broken", length: false), b = item("B")
        let p = FillReelPlan(slotCount: 2, items: [a, s, u, b])
        #expect(p.fillable == [a.id, s.id, b.id])
        #expect(p.leftOut.map(\.name) == ["Broken"])
        #expect(p.leftOut.map(\.reason) == [.noLength])
        #expect(FillReelPlan(slotCount: 2, items: [item("Photo", still: true, length: false)]).fillable.count == 1)
        #expect(p.canRun)
    }

    @Test func moreItemsThanSlotsAndFewer() {
        let items = (1...4).map { item("C\($0)") }
        let many = FillReelPlan(slotCount: 2, items: items)
        #expect(many.unusedItems == 2 && many.unfilledSlots == 0)
        #expect(many.note?.contains("2 items") == true)
        let few = FillReelPlan(slotCount: 5, items: Array(items.prefix(2)))
        #expect(few.unfilledSlots == 3 && few.unusedItems == 0)
        #expect(few.note?.contains("3 slots") == true)
    }

    @Test func nothingToRun() {
        #expect(!FillReelPlan(slotCount: 0, items: [item("A")]).canRun)
        #expect(!FillReelPlan(slotCount: 3, items: [item("Broken", length: false)]).canRun)
        #expect(!FillReelPlan(slotCount: 3, items: []).canRun)
    }

    @Test func resultTextNamesShortenedAndSkipped() {
        #expect(FillReelPlan.resultText(filled: 2, shortened: 0, skipped: 0, intoCopy: true) == "Filled 2 slots in a new sequence.")
        let t = FillReelPlan.resultText(filled: 2, shortened: 1, skipped: 1, intoCopy: false)
        #expect(t.hasPrefix("Filled 2 slots."))
        #expect(t.contains("1 was shorter than its slot"))
        #expect(t.contains("1 slot could not take its item"))
    }
}
