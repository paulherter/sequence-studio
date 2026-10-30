import Foundation
import SQCore
import SQUIKit
import SQEditorSession
import SQPremiereImport

/// What the last project import knew: the checklist and, per row, which affected clip "Show" visits next (the Mac
/// `ImportChecklistState`).
@MainActor
public final class ShellImportChecklist {
    public let checklist: PRImportChecklist
    public let report: PRImportReport
    public let fileName: String
    var cursor: [String: Int] = [:]

    public init(report: PRImportReport, project: Project, fileName: String) {
        self.fileName = fileName
        self.report = report
        checklist = PRImportChecklist(report: report, project: project)
    }
}

/// File > Project > Reconnect Media… (the Mac `RelinkSheet`) and Import Checklist… (the Mac `ImportReportSheet` with
/// its checklist rows), as shell dialogs.
extension ShellHost {
    /// Folders Reconnect Media searched, newest first (the Mac key, so both shells share the list).
    static let relinkFoldersKey = "sq.relink.folders"

    static func rememberRelinkFolder(_ url: URL, defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: relinkFoldersKey) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        defaults.set(Array(list.prefix(10)), forKey: relinkFoldersKey)
    }

    /// The dialog's title and note for `missing` of `total` offline files after `searched` folders.
    static func relinkText(missing: [MediaRef], total: Int, searched: Int) -> (title: String, detail: String) {
        let found = max(0, total - missing.count)
        let title = searched == 0
            ? (total == 1 ? SQL10n.string("1 media file is offline") : SQL10n.format("%@ media files are offline", String(total)))
            : SQL10n.format("%@ of %@ found", String(found), String(total))
        let names = missing.prefix(5).map { MediaPathResolver.fileName(of: $0.path) }.joined(separator: ", ")
        let more = missing.count > 5 ? ", …" : ""
        let detail = searched == 0
            ? SQL10n.format("Not found: %@. Choose the folder they are in; subfolders are searched too.", names + more)
            : SQL10n.format("Still missing: %@. Add another folder or click Done.", names + more)
        return (title, detail)
    }

    /// Asks for folders until everything is found or Done; each folder is searched with subfolders, one undo step each.
    func relinkMedia() async {
        let total = session.missingMedia.count
        guard total > 0 else { flash("All media is online."); return }
        guard let files else { flash(ShellPlatformText.notAvailable); return }
        var searched = 0
        var note: String?
        while !session.missingMedia.isEmpty {
            let text = Self.relinkText(missing: session.missingMedia, total: total, searched: searched)
            let d = ShellDialog(text.title, informative: note.map { $0 + "\n" + text.detail } ?? text.detail)
            d.width = 440
            d.addButton(searched == 0 ? "Locate…" : "Add Folder…")
            d.addButton("Done", role: .cancel)
            d.sheetStyle = true   // the Mac RelinkSheet: band footer, 56 pt header
            d.footerMascot = true   // Pip (`SQMascotPlace.mediaOffline`) at the left of the footer; the host draws him
            let answer = await ask(d)
            guard answer == .first else { break }
            guard let dir = await files.chooseFolder(prompt: SQL10n.string("Choose the folder that contains the offline media")) else { continue }
            searched += 1
            Self.rememberRelinkFolder(dir)
            flash(SQL10n.format("Searching %@…", dir.lastPathComponent))
            let r = await session.relinkMissing(searching: [dir])
            note = r.sizeDiffers > 0
                ? SQL10n.format("%@ files have the right name but another size; they were left offline.", String(r.sizeDiffers)) : nil
            SQLog.info("relink: \(r.relinked) relinked in \(dir.lastPathComponent), \(r.offline) offline")
        }
        let found = total - session.missingMedia.count
        if found > 0 { flash(SQL10n.format("Reconnected %@ media files.", String(found))) }
    }

    /// File > Project > Import Checklist…: what the last import approximated, left out or could not find, as the Mac
    /// `ImportReportSheet` (dot rows, Show / Reconnect… on the rows that can act, Save Report… and Done). Show visits the
    /// next affected clip; Reconnect… runs the relink dialog (then true).
    @discardableResult
    func showImportChecklist() async -> Bool {
        guard let state = importChecklist else { flash("No project import to check."); return false }
        let rows = ShellImportReportContent.rows(checklist: state.checklist, canReconnect: session.canRelink)
        let note = state.checklist.needsAttention
            ? "Show jumps to the affected clips. This list stays under File > Import Checklist." : "Everything came over as is."
        var chosen: PRImportChecklist.Item?
        var reconnect = false
        let content = ShellImportReportContent(rows: rows)
        await askImportReport(content, title: "Imported \(state.fileName)", note: note, report: state.report, fileName: state.fileName) { item in
            if item.kind == .missingFiles { reconnect = true } else { chosen = item }
        }
        if let chosen { showAffectedClip(chosen) }
        if reconnect { await relinkMedia(); return true }
        return false
    }

    /// The report card without a checklist (report mode of the Mac sheet): rows worst first, Save Report… and Done.
    public func showImportReport(_ report: PRImportReport, fileName: String) async {
        func total(_ s: PRImportReport.Status) -> Int { report.entries.filter { $0.status == s }.reduce(0) { $0 + $1.count } }
        let note = "\(total(.mapped)) mapped, \(total(.approximated)) approximated, \(total(.dropped)) dropped. Fix the last two by hand."
        await askImportReport(ShellImportReportContent(rows: ShellImportReportContent.rows(report: report)),
                                  title: "Imported \(fileName)", note: note, report: report, fileName: fileName) { _ in }
    }

    private func askImportReport(_ content: ShellImportReportContent, title: String, note: String, report: PRImportReport,
                                 fileName: String, act: @escaping (PRImportChecklist.Item) -> Void) async {
        let d = ShellDialog(title, informative: note)
        d.width = 600   // SQModal.Size.m
        d.content = content
        d.addButton("Done", role: .default)
        d.addButton("Save Report…")
        content.onAction = { [weak d] item in act(item); if let d { d.press(.first) } }
        // Save Report… keeps the card open (the Mac sheet writes the file and stays).
        d.canClose = { [weak self] r in
            guard r == .second else { return true }
            self?.spawn { [weak self] in await self?.saveImportReport(report, fileName: fileName) }
            return false
        }
        _ = await ask(d)
    }

    func saveImportReport(_ report: PRImportReport, fileName: String) async {
        guard let files else { flash(ShellPlatformText.notAvailable); return }
        guard let url = await files.chooseSaveLocation(suggestedName: "\(fileName) import report.txt", prompt: SQL10n.string("Save Report")) else { return }
        do { try report.summary.write(to: url, atomically: true, encoding: .utf8) } catch { presentError("Could not save the report", error) }
    }

    /// Selects the next clip of a checklist row (wrapping), switching to its sequence and moving the playhead to it.
    func showAffectedClip(_ item: PRImportChecklist.Item) {
        guard let state = importChecklist else { return }
        guard !item.locations.isEmpty else { flash("This row has no clips to show."); return }
        let at = state.cursor[item.id, default: 0] % item.locations.count
        state.cursor[item.id] = at + 1
        let loc = item.locations[at]
        guard let timeline = session.project.timeline(loc.timeline),
              let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == loc.clip }) else {
            flash("That clip is gone."); return
        }
        if session.activeTimelineID != loc.timeline { session.setActiveTimeline(loc.timeline) }
        session.select(clips: [loc.clip])
        session.seek(to: clip.timeline.start)
        onStatus?(SQL10n.format("%@: clip %@ of %@. For the next, open File > Import Checklist",
                                item.title, String(at + 1), String(item.locations.count)))
    }
}

extension ShellFilePicker {
    /// Default of the protocol requirement: no folder chooser (nil).
    public func chooseFolder(prompt: String) async -> URL? { nil }
}
