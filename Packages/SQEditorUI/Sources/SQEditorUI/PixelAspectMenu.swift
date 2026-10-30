import AppKit
import SQCore
import SQEditorSession

/// F7.3: the Pixel Aspect choices of a Project item's source settings (context menu > Pixel Aspect). Pure rows plus the
/// Custom ratio sheet; the panel maps the picks to `ProjectPanelModel.setPixelAspect` (one undo step for the selection).
public enum PixelAspectMenu {
    /// The pure parts live in SQEditorSession `PixelAspectChoices` (the portable shell builds the same rows).
    public typealias State = PixelAspectChoices.State
    public static var named: [(title: String, aspect: PixelAspect)] { PixelAspectChoices.named }
    public static func ratioText(_ a: PixelAspect) -> String { PixelAspectChoices.ratioText(a) }
    public static func title(_ a: PixelAspect) -> String { PixelAspectChoices.title(a) }

    /// The rows of the Pixel Aspect submenu (`PixelAspectChoices.items`, shared with the portable shell).
    @MainActor
    public static func items(_ s: State, pick: @escaping @MainActor (PixelAspect?) -> Void,
                             custom: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        PixelAspectChoices.items(s, pick: pick, custom: custom)
    }

    public static func aspect(fromRatio v: Double) -> PixelAspect? { PixelAspectChoices.aspect(fromRatio: v) }

    /// The Custom ratio sheet. `completion` gets the ratio; Cancel does not call it.
    @MainActor
    public static func presentCustom(on window: NSWindow, initial: PixelAspect, completion: @escaping @MainActor (PixelAspect) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Custom Pixel Aspect"
        alert.informativeText = "Width divided by height of one pixel. 1 is square, 2 is a 2x anamorphic lens."
        alert.width = SQModal.Size.xs.width
        let field = SQDialog.makeNumberField(value: initial.value, range: PixelAspectChoices.ratioRange, step: 0.01, decimals: 4, defaultValue: 1, width: nil)
        field.leadingText = true
        alert.accessoryView = SQDialogForm(rows: [SQDialog.formRow("Ratio", field)])
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first, let a = aspect(fromRatio: field.value) else { return }
                completion(a)
            }
        }
    }
}
