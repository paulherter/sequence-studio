import SQUIKit
import Foundation

extension SaveChangesPrompt {
    @MainActor
    public static func makeDialog(documentName: String, hasFile: Bool = true) -> SQDialog {
        let d = SQDialog()
        d.messageText = SQL10n.format("Save changes to “%@”?", documentName)
        d.informativeText = detail(hasFile: hasFile)
        for b in buttons { d.addButton(b.title, role: b.role) }
        return d
    }
}
