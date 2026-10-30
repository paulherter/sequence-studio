import AppKit
import SQAnalysis
import SQUIKit

/// The Auto Reframe sheet: how calmly the camera follows the subject and how tight it sits. The last choice is
/// remembered (`sq.reframe.*`); Steady + Fill Frame are the plain defaults.
@MainActor
enum ReframeOptionsDialog {
    private enum Key { static let smoothness = "sq.reframe.smoothness", tightness = "sq.reframe.tightness" }

    static func remembered(_ d: UserDefaults = .standard) -> (ReframeSmoothness, ReframeTightness) {
        (d.string(forKey: Key.smoothness).flatMap(ReframeSmoothness.init(rawValue:)) ?? .steady,
         d.string(forKey: Key.tightness).flatMap(ReframeTightness.init(rawValue:)) ?? .fill)
    }

    /// `subject`: "“Clip”" or "3 clips". `completion` gets nil on Cancel.
    static func present(on window: NSWindow, subject: String, completion: @escaping @MainActor (ReframeOptions?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Auto Reframe"
        alert.informativeText = subject + "\nKeeps the subject in the frame with Position keys you can edit in Effect Controls."
        alert.width = SQModal.Size.s.width
        let start = remembered()
        let motion = SQSegmented(labels: ReframeSmoothness.allCases.map { SQL10n.string($0.title) }, segmentWidth: 104)
        let framing = SQSegmented(labels: ReframeTightness.allCases.map { SQL10n.string($0.title) }, segmentWidth: 104)
        motion.selectedSegment = ReframeSmoothness.allCases.firstIndex(of: start.0) ?? 1
        framing.selectedSegment = ReframeTightness.allCases.firstIndex(of: start.1) ?? 0
        alert.accessoryView = SQDialogForm(rows: [
            SQDialog.formRow("Motion", motion), SQDialog.formRow("Framing", framing),
            SQDialog.formText("Quick follows every move. Smooth holds the frame calmer but can trail a fast subject. Closer and Tight zoom in on the subject.")])
        alert.addButton("Reframe")
        alert.addButton("Cancel", role: .cancel)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { completion(nil); return }
                let s = ReframeSmoothness.allCases[min(max(motion.selectedSegment, 0), ReframeSmoothness.allCases.count - 1)]
                let t = ReframeTightness.allCases[min(max(framing.selectedSegment, 0), ReframeTightness.allCases.count - 1)]
                UserDefaults.standard.set(s.rawValue, forKey: Key.smoothness)
                UserDefaults.standard.set(t.rawValue, forKey: Key.tightness)
                completion(ReframeOptions(smoothness: s, tightness: t))
            }
        }
    }
}
