import AppKit

/// "Save as Template" sheet (SQ dialog): just a name; the slots and animation zones are found from the selection.
public enum TitleTemplateSaveSheet {
    /// Presents the sheet on `window`; `completion` gets the name on Save, nil on Cancel.
    @MainActor
    public static func present(on window: NSWindow, defaultName: String, completion: @escaping @MainActor (String?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Save as Template"
        alert.informativeText = "Saves the selected layers as a template with editable text, color, font and size, and keeps the intro and outro when the clip is trimmed."
        let field = SQDialog.makeField(width: 260)
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(response == .first ? PresetSaveSheet.resolvedName(field.stringValue, fallback: defaultName) : nil)
            }
        }
    }
}
