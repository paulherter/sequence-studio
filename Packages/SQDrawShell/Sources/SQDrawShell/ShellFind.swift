import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Edit > Find (the Mac `ProjectPanelView.showFind` + `selectFound`): text in the name or label name and/or offline
/// media only; OK shows the Project panel and selects the matches (their bins opened), the status line counts them.
/// The field (placeholder "Text") and the Name / Label popup share the first line, as on the Mac.
extension ShellHost {
    func find() async {
        let form = ShellForm([
            .field(id: "text", label: "", value: ""),
            .popup(id: "field", label: "", options: ["Name", "Label"], selected: 0),
            .check(id: "offline", title: "Offline media only", on: false),
        ])
        form.placeholders = ["text": "Text"]
        form.inlinePopups = ["field"]
        form.beginEditing("text")
        let d = ShellDialog("Find", informative: "Select the clips and sequences that match.")
        d.width = 440
        d.form = form
        d.addButton("Find")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        let c = ProjectPanelModel.FindCriteria(text: form.text("text") ?? "", field: form.index("field") == 1 ? .label : .name,
                                               offlineOnly: form.bool("offline") ?? false)
        selectFound(c)
    }

    /// `ProjectPanelView.selectFound`: selects the matches in the Project panel and reports the count.
    func selectFound(_ c: ProjectPanelModel.FindCriteria) {
        guard let model = projectModel else { return }
        let found = model.find(c)
        guard !found.isEmpty else { flash(c.isEmpty ? "Nothing to find." : "No match."); return }
        model.searchText = ""
        _ = execute(.focusPanel(.project))
        projectList?.reveal(found, in: session.project.rootBin)
        onStatus?(SQL10n.plural(found.count, one: "%@ match.", other: "%@ matches."))
    }
}
