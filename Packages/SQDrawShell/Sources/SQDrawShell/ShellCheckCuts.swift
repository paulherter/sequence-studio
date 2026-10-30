import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Sequence > Check Cuts (the Mac `requestCheckCuts` + `CutCheckSheetView`): runs the check, marks the findings on the
/// timeline (Undo removes them) and shows the summary; the platform popup reruns it with that platform's safe zone.
extension ShellHost {
    /// Same key as the Mac sheet, so both shells share the chosen platform.
    static let cutCheckPlatformKey = "sq.cutCheck.platform"

    /// `CutCheckSheetView`: the summary lines, the "Shot length" title and the `ShotHistogramView` bars.
    static func cutCheckChart(_ r: CutCheckReport) -> (note: String, bars: [ShellForm.Bar]) {
        (r.boardSummary, r.stats.histogram.map { ShellForm.Bar(label: $0.label, count: $0.count) })
    }

    func checkCuts() async {
        let platforms = CutCheckPlatform.allCases
        let saved = startDefaults.string(forKey: Self.cutCheckPlatformKey).flatMap(CutCheckPlatform.init(rawValue:)) ?? .tiktok
        guard let report = session.runCutCheck(platform: saved) else { flash("Nothing to check: open a sequence first."); return }
        onProjectChanged?()
        let form = ShellForm([
            // `SQSegmented` "Safe Zone" row, segments sized to their titles (52 fits "Shorts" in 11 pt).
            .segmented(id: "platform", label: "Safe Zone", options: platforms.map(\.title), selected: platforms.firstIndex(of: saved) ?? 0,
                       segmentWidth: 52),
            .chart(note: Self.cutCheckChart(report).note, title: "Shot length", bars: Self.cutCheckChart(report).bars),
        ])
        let d = ShellDialog("Check Cuts", informative: "Findings are marked on the timeline. Undo removes them.")
        form.onChange = { [weak self, weak form, weak d] id, value in
            guard let self, let form, id == "platform", case .index(let i) = value, platforms.indices.contains(i) else { return }
            self.startDefaults.set(platforms[i].rawValue, forKey: Self.cutCheckPlatformKey)
            guard let r = self.session.runCutCheck(platform: platforms[i]) else { return }
            let c = Self.cutCheckChart(r)
            form.setChart(1, note: c.note, bars: c.bars)
            if let d { self.relayout(d) }   // the chart row's height follows the summary lines
            self.onProjectChanged?()
        }
        d.width = 440
        d.form = form
        d.addButton("Done")
        _ = await ask(d)
    }
}
