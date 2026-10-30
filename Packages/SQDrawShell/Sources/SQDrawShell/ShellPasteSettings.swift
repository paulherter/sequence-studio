import Foundation
import SQCore
import SQEditorSession

/// Edit > Paste Settings (Cmd+Opt+V): one check per attribute group of the copied clip, all on, plus "Scale Keyframe
/// Times" (off at first, remembered). Translated from the Mac `PasteAttributesDialog` and the `.pasteAttributes` case of
/// `AppController.execute`; the edit is `EditorSession.pasteAttributes`.
extension ShellHost {
    static let pasteScaleTimesKey = "sq.pasteAttributes.scaleTimes"

    func pasteSettings(defaults: UserDefaults = .standard) async {
        guard session.clipboard != nil else { flash("Copy a clip first, then select the clips to paste its attributes onto."); return }
        guard session.canPasteAttributes else { flash("Select clips of the same kind as the copied clip."); return }
        let choices = session.pasteAttributeChoices
        guard !choices.isEmpty else { return }
        let d = ShellDialog("Paste Settings", informative: "Choose what to paste onto the selected clips. Everything else stays as it is.")
        var rows: [ShellForm.Row] = choices.map { .check(id: $0.rawValue, title: $0.title, on: true) }
        rows.append(.check(id: "scaleTimes", title: "Scale Keyframe Times", on: defaults.bool(forKey: Self.pasteScaleTimesKey)))
        d.form = ShellForm(rows)
        d.addButton("Paste")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let f = d.form else { return }
        let scale = f.bool("scaleTimes") == true
        defaults.set(scale, forKey: Self.pasteScaleTimesKey)
        let groups = Set(choices.filter { f.bool($0.rawValue) == true })
        // A refused paste reports through the session error.
        if !session.pasteAttributes(groups: groups, scaleTimes: scale), let e = session.lastError { flash(e) }
    }
}
