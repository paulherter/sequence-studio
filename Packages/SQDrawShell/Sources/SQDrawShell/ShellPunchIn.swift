import Foundation
import SQCore
import SQEditorSession

/// Sequence > Punch In Cuts…: zoom levels, ease and pattern for consecutive shots. Translated from the Mac
/// `requestPunchInCuts` and `PunchInCutsSheetView`; the edit is `EditorSession.punchInCuts`.
extension ShellHost {
    static let punchInCutsKey = "sq.punchInCuts"
    /// The XS card (`Theme.Modal.widthXS`; the token is AppKit-only).
    static let punchInCutsWidth: CGFloat = 360

    func punchInCuts(defaults: UserDefaults = .standard) async {
        guard session.punchInCutsEnabled else {
            flash("Select two or more video clips, or target a video track with several shots."); return
        }
        let key = Self.punchInCutsKey
        let initial = PunchInCutsOptions(
            scales: (defaults.array(forKey: "\(key).scales") as? [Double]) ?? [115],
            ease: defaults.string(forKey: "\(key).ease").flatMap(PunchInCutsOptions.Ease.init(rawValue:)) ?? .hold,
            pattern: defaults.string(forKey: "\(key).pattern").flatMap(PunchInCutsOptions.Pattern.init(rawValue:)) ?? .alternate)
        let d = ShellDialog("Punch In Cuts",
                            informative: "Zooms consecutive shots in turn. Alternate swaps 100% and the lowest zoom ticked; Cycle walks through all ticked levels.")
        d.width = Self.punchInCutsWidth
        let choices = PunchInCutsOptions.scaleChoices
        func title(_ v: Double) -> String { v == 100 ? "100 % (no zoom)" : (v == v.rounded() ? "\(Int(v)) %" : String(format: "%.1f %%", v)) }
        var rows: [ShellForm.Row] = [
            .segmented(id: "pattern", label: "Pattern", options: ["Alternate", "Cycle"], selected: initial.pattern == .alternate ? 0 : 1, segmentWidth: 0),
            .popup(id: "ease", label: "Ease", options: PunchInCutsOptions.Ease.allCases.map(\.title),
                   selected: PunchInCutsOptions.Ease.allCases.firstIndex(of: initial.ease) ?? 0),
        ]
        for (i, v) in choices.enumerated() { rows.append(.check(id: "zoom\(i)", title: title(v), on: initial.scales.contains(v))) }
        let form = ShellForm(rows)
        // The first level carries the "Zoom" label, the others sit under it in the control column.
        for i in choices.indices { form.checkLabels["zoom\(i)"] = i == 0 ? "Zoom" : "" }
        d.form = form
        d.addButton("Apply")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let f = d.form else { return }
        let ease = PunchInCutsOptions.Ease.allCases[min(max(f.index("ease") ?? 0, 0), PunchInCutsOptions.Ease.allCases.count - 1)]
        let o = PunchInCutsOptions(scales: choices.indices.filter { f.bool("zoom\($0)") == true }.map { choices[$0] }, ease: ease,
                                   pattern: f.index("pattern") == 1 ? .cyclic : .alternate)
        defaults.set(o.scales, forKey: "\(key).scales")
        defaults.set(o.ease.rawValue, forKey: "\(key).ease")
        defaults.set(o.pattern.rawValue, forKey: "\(key).pattern")
        if !session.punchInCuts(o) { flash(session.lastError ?? "Tick a zoom above 100% (Cycle needs two levels).") }
    }
}
