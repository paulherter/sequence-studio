import AppKit
import SQCore
import SQEditorUI

extension AppController {
    private static let punchInCutsKey = "sq.punchInCuts"

    /// Sequence > Punch In Cuts…: one undo step over the selected clips (two or more) or the targeted video track.
    func requestPunchInCuts() {
        guard session.punchInCutsEnabled else {
            shell.statusBar.flash("Select two or more video clips, or target a video track with several shots.", seconds: 3); return
        }
        let d = UserDefaults.standard
        let initial = PunchInCutsOptions(
            scales: (d.array(forKey: "\(Self.punchInCutsKey).scales") as? [Double]) ?? [115],
            ease: d.string(forKey: "\(Self.punchInCutsKey).ease").flatMap(PunchInCutsOptions.Ease.init(rawValue:)) ?? .hold,
            pattern: d.string(forKey: "\(Self.punchInCutsKey).pattern").flatMap(PunchInCutsOptions.Pattern.init(rawValue:)) ?? .alternate)
        let alert = SQDialog()
        alert.messageText = "Punch In Cuts"
        alert.informativeText = "Zooms consecutive shots in turn. Alternate swaps 100% and the lowest zoom ticked; Cycle walks through all ticked levels."
        let sheet = PunchInCutsSheetView(initial)
        alert.width = SQModal.Size.xs.width
        alert.accessoryView = sheet.form
        alert.addButton("Apply")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .first, let self else { return }
            let o = sheet.options
            d.set(o.scales, forKey: "\(Self.punchInCutsKey).scales")
            d.set(o.ease.rawValue, forKey: "\(Self.punchInCutsKey).ease")
            d.set(o.pattern.rawValue, forKey: "\(Self.punchInCutsKey).pattern")
            if !session.punchInCuts(o) {
                shell.statusBar.flash(session.lastError ?? "Tick a zoom above 100% (Cycle needs two levels).", seconds: 3)
            }
        }
    }
}
