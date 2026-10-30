import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// Crash recovery, autosave versions and checkpoints, translated from the Mac `AppController+Files` (Recovery, Close
/// Project / Autosave Versions): the same scanner, report, dialog texts and session calls; only the dialogs are the shell's.
extension ShellHost {
    /// File > Project > Autosave Versions rows (`fillAutosaveMenu` reads `session.autosaveVersions`).
    func autosaveRows() -> [AutosaveVersionRow] {
        session.autosaveVersions.map { AutosaveVersionRow(path: $0.url.path, date: $0.date, name: $0.name) }
    }

    /// `restoreAutosaveItem`: the version replaces the project; Undo brings back the previous state.
    public func restoreAutosave(path: String) {
        guard let v = session.autosaveVersions.first(where: { $0.url.path == path }) else { return }
        do {
            session.stopPlayback()
            try session.restoreAutosave(v)
            onProjectChanged?()
            flash(SQL10n.format("Restored the version from %@. Undo brings back the previous state.",
                                v.date.formatted(date: .omitted, time: .standard)))
        } catch { presentError("Could not restore this version", error) }
    }

    /// `saveCheckpointItem`: asks for a name, then keeps the project as it is now until the user deletes it.
    public func saveCheckpoint() async {
        let d = ShellDialog("Save Checkpoint", informative: "A checkpoint is kept until you remove it; automatic backups never replace it.")
        let form = ShellForm([.field(id: "name", label: "Checkpoint", value: "")])
        d.form = form
        d.addButton("Save")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let name = form.text("name"), AutosaveStore.sanitized(name) != nil else { return }
        if await session.saveCheckpoint(name: name) != nil {
            flash(SQL10n.format("Checkpoint “%@” saved.", AutosaveStore.sanitized(name) ?? name))
        }
    }

    // MARK: Recovery at launch

    /// `makeRecoveryDialog` of the Mac app.
    public static func recoveryDialog(projectName: String, date: Date) -> ShellDialog {
        let d = ShellDialog(SQL10n.format("Recover “%@”?", projectName),
                            informative: SQL10n.format("Sequence Studio did not close cleanly. An autosaved version from %@ is available.",
                                                       date.formatted(date: .abbreviated, time: .shortened)))
        d.addButton("Recover")
        d.addButton("Discard")
        return d
    }

    /// `writeCrashReports`: one report per crashed session found at launch (off the main thread); returns the newest.
    /// The Mac adds the newest system crash log from DiagnosticReports; Windows has no such folder (`systemReport` nil).
    nonisolated static func writeCrashReports(_ crashed: [CrashedSession], store: AutosaveStore, reports: CrashReportStore,
                                              appVersion: String) -> URL? {
        guard !crashed.isEmpty else { return nil }
        SQLog.shared.flush()
        let logFiles = (0..<3).map { SQLog.directory.appendingPathComponent($0 == 0 ? "sq.log" : "sq.\($0).log") }
        let log = CrashReport.logTail(files: logFiles)
        var newest: URL?
        for s in crashed {
            let project = s.autosave.flatMap { try? store.read($0) }
            let text = CrashReport.render(session: s, project: project, log: log, appVersion: appVersion,
                                          os: ProcessInfo.processInfo.operatingSystemVersionString, systemReport: nil)
            if let url = try? reports.write(text, date: Date()) { newest = url }
        }
        return newest
    }

    /// `offerRecovery`: crashed sessions get a report, and one with a newer autosave is offered for recovery. Returns
    /// once the questions are answered. Only asks while the window still shows the empty untitled project.
    public func offerRecovery(reports: CrashReportStore = CrashReportStore(), appVersion: String = "") async {
        let store = session.autosaveStore
        let scanner = RecoveryScanner(store: store)
        let (found, report) = await Task.detached(priority: .userInitiated) { () -> ([RecoveryCandidate], URL?) in
            let r = scanner.scanSessions()
            let url = Self.writeCrashReports(r.crashed, store: store, reports: reports, appVersion: appVersion)
            scanner.markReported(r.crashed)   // a kept recovery marker must not report the same crash again
            return (r.candidates, url)
        }.value
        guard dialog == nil, session.isEmptyUntitled else { return }
        if let report {
            SQLog.info("crash report written: \(report.lastPathComponent)")
            await presentCrashReport(report)
            guard dialog == nil, session.isEmptyUntitled else { return }
        }
        guard let candidate = found.first else { return }
        SQLog.info("recovery offered: \(candidate.projectName)")
        if await ask(Self.recoveryDialog(projectName: candidate.projectName, date: candidate.autosave.date)) == .first {
            do {
                try await session.recover(candidate, scanner: scanner)
                onProjectChanged?()
            } catch { presentError("Could not recover", error) }
        } else {
            SQLog.info("recovery discarded")
            scanner.dismiss(candidate)
        }
    }

    /// `presentCrashReport`: reveal the report in the file browser or copy its text (host hooks).
    func presentCrashReport(_ report: URL) async {
        let d = ShellDialog("Sequence Studio quit unexpectedly",
                            informative: "A report with the last log lines and a summary of the project (media names only, no file paths) was saved as "
                                + report.lastPathComponent + ". Send it with your feedback to help fix the problem.")
        d.addButton("Reveal Report")
        d.addButton("Copy Report")
        d.addButton("Close", role: .cancel)
        switch await ask(d) {
        case .first: revealFile?(report)
        case .second: copyText?((try? String(contentsOf: report, encoding: .utf8)) ?? "")
        default: break
        }
    }
}
