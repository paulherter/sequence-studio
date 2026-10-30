import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// Clip > Video Options > Anonymize: the sheets. Translated from the Mac `AnonymizeDialog` (the texts are shared in
/// `AnonymizeText`). The people finder and the tracker run in the host (the Mac: SQAnalysis through `runAnonymize`); the
/// edit is `EditorSession.applyAnonymize`.
extension ShellHost {
    /// What to cover, with what and which of the people found on the playhead's frame. nil: canceled or nobody ticked.
    public func askAnonymize(clipName: String, people: [AnonymizePerson], defaults: UserDefaults = .standard) async -> AnonymizeChoice? {
        let initial = AnonymizeChoice.remembered(defaults)
        let d = ShellDialog("Anonymize", informative: AnonymizeText.info(clipName: clipName))
        d.width = ShellDialog.M.widthS
        var rows: [ShellForm.Row] = [
            .segmented(id: "target", label: "Cover", options: AnonymizeTarget.allCases.map(\.title),
                       selected: AnonymizeTarget.allCases.firstIndex(of: initial.target) ?? 0, segmentWidth: 0),
            .segmented(id: "cover", label: "With", options: AnonymizeCover.allCases.map(\.title),
                       selected: AnonymizeCover.allCases.firstIndex(of: initial.cover) ?? 0, segmentWidth: 0),
            .text(AnonymizeText.peopleNote(count: people.count)),   // strong below: `formText(note: false)`
        ]
        for (i, p) in people.enumerated() { rows.append(.check(id: "person\(i)", title: AnonymizeText.personLabel(i, p), on: true)) }
        rows.append(.text(AnonymizeText.hint))
        let form = ShellForm(rows)
        form.extraGapBefore = [2: 8]   // `formText(top: 6)` over the stack spacing: measured 8 pt against the Mac PNG
        form.setNote(2, AnonymizeText.peopleNote(count: people.count), strong: true, plain: true)
        d.form = form
        d.addButton("Anonymize")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let f = d.form else { return nil }
        let targets = AnonymizeTarget.allCases, covers = AnonymizeCover.allCases
        let choice = AnonymizeChoice(target: targets[min(max(f.index("target") ?? 0, 0), targets.count - 1)],
                                     cover: covers[min(max(f.index("cover") ?? 0, 0), covers.count - 1)],
                                     people: people.indices.filter { f.bool("person\($0)") == true })
        guard !choice.people.isEmpty else { return nil }
        choice.remember(defaults)
        return choice
    }

    /// The frames to check by hand after a run: ranges where a person may be outside the cover first (all of them), then at
    /// most `AnonymizeText.maxLines` others. True when "Go to First" was pressed (the caller seeks to `lines.first`).
    public func askAnonymizeChecks(lines: [AnonymizeCheckLine]) async -> Time? {
        let list = AnonymizeCheckLine.shown(lines, limit: AnonymizeText.maxLines)
        guard let first = list.lines.first else { return nil }
        let d = ShellDialog("Anonymize: Check These Frames", informative: AnonymizeText.checksText(lines))
        d.width = 480   // Theme.Modal.widthSList
        var rows: [ShellForm.Row] = list.lines.map { .text($0.text) }
        if list.more > 0 { rows.append(.text(AnonymizeText.moreNote(list.more))) }
        d.form = ShellForm(rows)
        d.addButton("Go to First")
        d.addButton("Close", role: .cancel)
        return await ask(d) == .first ? first.time : nil
    }

    /// Clip > Video Options > Anonymize. The host runs the analysis (`runAnonymize`); without one the command says so.
    func anonymizeCommand() {
        if let run = runAnonymize { run() } else { flash("Anonymize needs the people finder, which this build does not have.") }
    }
}
