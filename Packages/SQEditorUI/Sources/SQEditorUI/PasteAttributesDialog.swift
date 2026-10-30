import AppKit

/// What the Paste Settings dialog returned.
public struct PasteAttributesChoice: Sendable, Equatable {
    public var groups: Set<PasteAttributeGroup>
    /// Stretch the copied key times to the target clip's length (Premiere: "Scale Attribute Times").
    public var scaleTimes: Bool
}

/// The Paste Attributes dialog: one checkbox per attribute group of the copied clip, all on at first, plus
/// "Scale Keyframe Times" (off by default, remembered in `sq.pasteAttributes.scaleTimes`).
@MainActor
public enum PasteAttributesDialog {
    static let scaleTimesKey = "sq.pasteAttributes.scaleTimes"

    /// Runs the dialog modally. Returns the choice, or nil when canceled.
    public static func run(choices: [PasteAttributeGroup]) -> PasteAttributesChoice? {
        guard !choices.isEmpty else { return nil }
        let alert = SQDialog()
        alert.messageText = "Paste Settings"
        alert.informativeText = "Choose what to paste onto the selected clips. Everything else stays as it is."
        let boxes = choices.map { g -> SQCheckbox in
            let b = SQCheckbox(title: g.title, target: nil, action: nil)
            b.state = .on
            return b
        }
        let scale = SQCheckbox(title: "Scale Keyframe Times", target: nil, action: nil)
        scale.state = UserDefaults.standard.bool(forKey: scaleTimesKey) ? .on : .off
        alert.accessoryView = SQDialogForm(rows: (boxes + [scale]).map { SQDialog.checkRow($0) })
        alert.addButton("Paste")
        alert.addButton("Cancel")
        guard alert.runModal() == .first else { return nil }
        let on = scale.state == .on
        UserDefaults.standard.set(on, forKey: scaleTimesKey)
        return PasteAttributesChoice(groups: Set(zip(choices, boxes).filter { $0.1.state == .on }.map(\.0)), scaleTimes: on)
    }
}
