import AppKit
import SQCore
import SQEditorUI
import SQPremiereImport

/// What the last project import knew: the checklist and, per row, which affected clip "Show" visits next.
@MainActor
final class ImportChecklistState {
    let report: PRImportReport
    let checklist: PRImportChecklist
    let fileName: String
    var cursor: [String: Int] = [:]

    init(report: PRImportReport, project: Project, fileName: String) {
        self.report = report; self.fileName = fileName
        checklist = PRImportChecklist(report: report, project: project)
    }
}

extension AppController {
    @objc func showImportChecklist(_ sender: Any?) { presentImportChecklist() }

    func presentImportChecklist() {
        guard let window, let state = importChecklistState else { return }
        ImportReportSheet.present(state.report, fileName: state.fileName, over: window, checklist: state.checklist,
                                  onShow: { [weak self] item in self?.showAffectedClip(item) },
                                  onReconnect: { [weak self] in self?.relinkMediaItem(nil) },
                                  completion: { [weak self] in self?.offerRelinkIfNeeded() })
    }

    /// Selects the next clip of a checklist row (wrapping), switching to its sequence and moving the playhead to it.
    func showAffectedClip(_ item: PRImportChecklist.Item) {
        guard let state = importChecklistState, !item.locations.isEmpty else { return }
        let at = state.cursor[item.id, default: 0] % item.locations.count
        state.cursor[item.id] = at + 1
        let loc = item.locations[at]
        guard let timeline = session.project.timeline(loc.timeline),
              let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id == loc.clip }) else {
            shell.statusBar.flash("That clip is gone.", seconds: 4); return
        }
        if session.activeTimelineID != loc.timeline { session.setActiveTimeline(loc.timeline) }
        session.select(clips: [loc.clip])
        session.seek(to: clip.timeline.start)
        shell.statusBar.flash(SQL10n.format("%@: clip %@ of %@. For the next, open File > Import Checklist",
                                            item.title, String(at + 1), String(item.locations.count)), seconds: 8)
    }
}
