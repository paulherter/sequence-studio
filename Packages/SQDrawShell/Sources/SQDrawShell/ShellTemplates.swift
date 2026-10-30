import Foundation
import SQCore
import SQUIKit

/// Rename and Delete of a saved template (the Mac `renameTemplate` / `templateStore.delete` behind the start window's
/// card menu). Built-in templates have neither.
extension ShellHost {
    /// One name field; a blank or unchanged name changes nothing.
    public func renameTemplate(_ t: ProjectTemplate) async {
        let form = ShellForm([.field(id: "name", label: "Name", value: t.name)])
        let d = ShellDialog("Rename Template")
        d.form = form
        d.addButton("Rename")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        let typed = (form.text("name") ?? "").trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != t.name else { return }
        do { try templateFolder.rename(t, to: typed); startScreen?.reload() }
        catch { presentError("Could not rename the template", error) }
    }

    /// Deletes the template's file right away, as the Mac does (no confirmation; the projects made from it stay).
    public func deleteTemplate(_ t: ProjectTemplate) {
        do { try templateFolder.delete(t) } catch { presentError("Could not delete the template", error); return }
        startScreen?.reload()
        flash(SQL10n.format("Deleted the template “%@”.", t.name))
    }
}
