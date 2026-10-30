import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Reconnect from one found file (the Mac `reconnectMedia` + `ReconnectSheet`): pick a file you found, every offline item
/// is scored against what is around it, and a checklist shows one row per proposed match. Strong matches start ticked,
/// weak ones unticked; nothing is linked until Reconnect. On the Mac it hangs off the Project panel's health line; the
/// shell offers it in the Reconnect Media dialog ("Found a File…").
extension ShellHost {
    /// The checklist's rows: one check per proposal (name) and its detail line (tier, signals, path).
    static func reconnectRows(_ result: RelinkScorer.Result, names: [MediaRef.ID: String]) -> [ShellForm.Row] {
        var rows: [ShellForm.Row] = []
        for (i, p) in result.proposals.enumerated() {
            rows.append(.check(id: "p\(i)", title: names[p.mediaID] ?? MediaPathResolver.fileName(of: p.path), on: p.isChecked))
            rows.append(.text("\(p.tier == .strong ? "Strong" : "Weak") · \(SQL10n.string(p.signalText)) · \(p.path)"))
        }
        return rows
    }

    /// The ticked proposals of a checklist form.
    static func tickedProposals(_ result: RelinkScorer.Result, form: ShellForm) -> [RelinkProposal] {
        result.proposals.enumerated().filter { form.bool("p\($0.offset)") == true }.map(\.element)
    }

    /// Asks for one found file, proposes matches around it and shows the checklist. Returns how many were reconnected.
    /// `volumes` nil = the mounted volumes (tests pass none).
    @discardableResult
    func reconnectFromFoundFile(volumes: [URL]? = nil) async -> Int {
        let missing = session.missingMedia
        guard !missing.isEmpty else { flash("All media is online."); return 0 }
        guard let files else { flash(ShellPlatformText.notAvailable); return 0 }
        let old = URL(fileURLWithPath: missing[0].path).deletingLastPathComponent()
        guard let url = await files.chooseFile(prompt: SQL10n.string("Choose one file you found. SQ looks around it for the other missing media."),
                                               directory: FileManager.default.fileExists(atPath: old.path) ? old : nil) else { return 0 }
        Self.rememberRelinkFolder(url.deletingLastPathComponent())
        flash("Searching…")
        let result = await session.proposeReconnect(from: url, volumes: volumes)
        guard !result.proposals.isEmpty else { flash("No matching files found around that location."); return 0 }
        let names = Dictionary(missing.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return await askReconnect(result, total: missing.count, names: names)
    }

    /// The checklist dialog; applies the ticked rows (one undo step).
    func askReconnect(_ result: RelinkScorer.Result, total: Int, names: [MediaRef.ID: String]) async -> Int {
        let unmatched = result.unmatched.count
        let form = ShellForm(Self.reconnectRows(result, names: names))
        let d = ShellDialog(result.foundText(total: total),
                            informative: unmatched == 0 ? "Untick any match you do not trust. Weak matches start unticked."
                                : "\(unmatched) still missing after this. Untick any match you do not trust; weak matches start unticked.")
        d.width = 560
        d.form = form
        d.addButton("Reconnect")
        d.addButton("Cancel", role: .cancel)
        // Reconnect needs a ticked row (the Mac button is disabled at zero).
        d.canClose = { r in r != .first || !Self.tickedProposals(result, form: form).isEmpty }
        guard await ask(d) == .first else { return 0 }
        let n = session.applyReconnect(Self.tickedProposals(result, form: form))
        if n > 0 {
            onProjectChanged?()
            flash(SQL10n.plural(n, one: "Reconnected %@ media file.", other: "Reconnected %@ media files."))
        }
        return n
    }
}
