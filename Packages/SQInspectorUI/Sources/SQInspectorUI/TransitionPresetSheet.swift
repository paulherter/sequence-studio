import AppKit

/// "Save as Preset…" for a transition: a small sheet asking for the preset name.
@MainActor
public enum TransitionPresetSheet {
    public static func present(on window: NSWindow?, defaultName: String, completion: @escaping (String) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Save Transition as Preset"
        alert.informativeText = "Kind, length, alignment, easing and style are saved to the Library (Presets, Transitions)."
        let field = SQDialog.makeField(defaultName, width: 240)
        field.setAccessibilityLabel("Preset name")
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        let finish: @MainActor (SQDialog.Response) -> Void = { r in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r == .first, !name.isEmpty else { return }
            completion(name)
        }
        if let window { alert.beginSheetModal(for: window, completion: finish) } else { finish(alert.runModal()) }
    }
}
