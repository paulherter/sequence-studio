import AppKit
import SQCore
import SQUIKit

/// Fill Reel…: what the picked media items do to the slots of the active sequence. Pure, so the sheet and its tests share it.
/// Items without a known length are left out up front, so they do not take a slot away from the item after them.
/// A still has no length of its own and fills a slot with the slot's length.
public struct FillReelPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var isStill: Bool
        public var hasLength: Bool
        public init(id: UUID, name: String, isStill: Bool, hasLength: Bool) {
            self.id = id; self.name = name; self.isStill = isStill; self.hasLength = hasLength
        }
    }
    public enum Reason: Equatable, Sendable { case noLength }
    public struct LeftOut: Equatable, Sendable { public var name: String; public var reason: Reason }

    public let slotCount: Int
    /// Items that go into the slots, in the order picked.
    public let fillable: [UUID]
    public let leftOut: [LeftOut]

    public init(slotCount: Int, items: [Item]) {
        self.slotCount = slotCount
        var ok: [UUID] = [], out: [LeftOut] = []
        for i in items {
            if !i.isStill && !i.hasLength { out.append(LeftOut(name: i.name, reason: .noLength)) }
            else { ok.append(i.id) }
        }
        fillable = ok; leftOut = out
    }

    public var canRun: Bool { slotCount > 0 && !fillable.isEmpty }
    public var unfilledSlots: Int { max(0, slotCount - fillable.count) }
    public var unusedItems: Int { max(0, fillable.count - slotCount) }

    /// A line about what will not happen, nil when every slot gets an item and every item a slot.
    public var note: String? {
        if unusedItems > 0 { return "\(unusedItems) \(unusedItems == 1 ? "item is" : "items are") beyond the last slot and will not be used." }
        if unfilledSlots > 0 { return "\(unfilledSlots) \(unfilledSlots == 1 ? "slot keeps" : "slots keep") its old media." }
        return nil
    }

    public static func resultText(_ r: ReelFillReport, intoCopy: Bool) -> String {
        resultText(filled: r.filled.count, shortened: r.shortened.count, skipped: r.skipped.count, intoCopy: intoCopy)
    }

    public static func resultText(filled n: Int, shortened: Int, skipped: Int, intoCopy: Bool) -> String {
        var text = "Filled \(n) \(n == 1 ? "slot" : "slots")" + (intoCopy ? " in a new sequence." : ".")
        if shortened > 0 { text += " \(shortened) was shorter than its slot and cut it short." }
        if skipped > 0 { text += " \(skipped) \(skipped == 1 ? "slot" : "slots") could not take its item." }
        return text
    }
}

/// What the user chose in the Fill Reel sheet.
public struct FillReelChoice: Sendable, Equatable {
    /// true: the template stays untouched and a copy "<name> Fill" gets the media.
    public var intoCopy: Bool
}

/// The Fill Reel sheet: the order the items go in, what is left out and whether a copy is made.
@MainActor
public enum FillReelDialog {
    private static let copyKey = "sq.fillReel.intoCopy"
    public static let maxLines = 8

    public static func present(on window: NSWindow, sequenceName: String, plan: FillReelPlan, names: [UUID: String],
                               completion: @escaping @MainActor (FillReelChoice?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Fill Reel"
        alert.informativeText = SQL10n.format("The clips of “%@” are slots: each keeps its place, length, effects and transitions and plays the next item from its first frame.", sequenceName)
        alert.width = SQModal.Size.s.width
        let copy = SQCheckbox(title: "Keep the template: fill a copy", target: nil, action: nil)
        let d = UserDefaults.standard
        copy.state = (d.object(forKey: copyKey) as? Bool ?? true) ? .on : .off
        var rows: [NSView] = []
        rows.append(SQDialog.formText("\(plan.fillable.count) of \(plan.slotCount) slots, in this order:", note: false))
        for (i, id) in plan.fillable.prefix(maxLines).enumerated() {
            rows.append(SQDialog.formText("\(i + 1)  \(names[id] ?? "Item")", note: false))
        }
        if plan.fillable.count > maxLines { rows.append(SQDialog.formText("and \(plan.fillable.count - maxLines) more.")) }
        for o in plan.leftOut {
            rows.append(SQDialog.formText("Left out: \(o.name) (length not known yet)."))
        }
        if let note = plan.note { rows.append(SQDialog.formText(note)) }
        rows.append(SQDialog.checkRow(copy))
        alert.accessoryView = SQDialogForm(rows: rows)
        alert.addButton("Fill Reel")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { completion(nil); return }
                let c = FillReelChoice(intoCopy: copy.state == .on)
                d.set(c.intoCopy, forKey: copyKey)
                completion(c)
            }
        }
    }
}
