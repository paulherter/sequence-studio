import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// Sequence > Check Cuts: marks the findings on the timeline (click a marker to jump) and shows the edit stats.
    func requestCheckCuts() {
        let saved = UserDefaults.standard.string(forKey: "sq.cutCheck.platform").flatMap(CutCheckPlatform.init(rawValue:)) ?? .tiktok
        guard let report = session.runCutCheck(platform: saved) else { shell.statusBar.flash("Nothing to check: open a sequence first."); return }
        let alert = SQDialog()
        alert.messageText = "Check Cuts"
        alert.informativeText = "Findings are marked on the timeline. Undo removes them."
        let sheet = CutCheckSheetView(report: report, rerun: { [weak self] in self?.session.runCutCheck(platform: $0) })
        alert.accessoryView = sheet.form
        alert.width = SQModal.Size.s.width
        alert.addButton("Done")
        alert.beginSheetModal(for: window) { _ in _ = sheet }   // keeps the sheet view (picker target) alive
    }
}
