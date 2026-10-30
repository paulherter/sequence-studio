import AppKit
import SQCore
import SQEditorSession

/// The Remove Silences sheet: threshold, minimum length and padding (slider plus number field each), with a live count of what would be cut. The
/// host shows the cuts on the timeline from `preview`; nothing changes until "Remove", which is one undo step.
@MainActor
public enum RemoveSilencesDialog {
    public typealias Preview = @MainActor (SilenceSettings) -> (count: Int, removed: Time)

    public static func present(on window: NSWindow, clipName: String, initial: SilenceSettings, preview: @escaping Preview,
                               completion: @escaping @MainActor (SilenceSettings?, _ propose: Bool) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Remove Silences"
        alert.informativeText = clipName + "\nSilences are cut and the gaps closed on every sync-locked track, so picture, music and B-roll stay in sync."
        alert.width = SQModal.Size.s.width
        let ui = makeView(initial: initial, preview: preview)
        alert.accessoryView = ui.view
        alert.addButton("Remove")
        alert.addButton("Cancel")
        alert.addButton("Mark for Review")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(ui.controller) {}
                let ok = response == .first || response == .third
                completion(ok ? ui.controller.settings : nil, response == .third)
            }
        }
    }

    /// The accessory view and its controller (a test renders the view).
    public static func makeView(initial: SilenceSettings, preview: @escaping Preview) -> (view: NSView, controller: SilenceFieldsController) {
        let c = SilenceFieldsController(initial: initial, preview: preview)
        return (c.view, c)
    }
}

@MainActor
public final class SilenceFieldsController: NSObject {
    /// Slider ranges: threshold in dB, minimum length and padding in ms.
    public static let thresholdRange = SilenceSettings.thresholdRange
    public static let minimumRange = SilenceSettings.minimumRange
    public static let paddingRange = SilenceSettings.paddingRange

    let threshold: NumericSlider, minimum: NumericSlider, padding: NumericSlider
    private let previewLabel = SQDialog.caption("")
    private let preview: RemoveSilencesDialog.Preview
    public let view: NSView

    public var settings: SilenceSettings {
        SilenceSettings.snapped(thresholdDB: threshold.value, minimumMs: minimum.value, paddingMs: padding.value)
    }

    init(initial: SilenceSettings, preview: @escaping RemoveSilencesDialog.Preview) {
        self.preview = preview
        func slider(_ v: Double, _ r: ClosedRange<Double>, standard: Double, step: Double, unit: String) -> NumericSlider {
            let s = NumericSlider(value: min(max(v, r.lowerBound), r.upperBound), range: r, defaultValue: standard,
                                  step: step, unit: unit)
            s.fieldWidth = 72; s.gap = 12; s.field.leadingText = true
            s.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return s
        }
        let std = SilenceSettings.standard
        threshold = slider(initial.thresholdDB, Self.thresholdRange, standard: std.thresholdDB, step: 1, unit: "dB")
        minimum = slider(Double(initial.minimumMs), Self.minimumRange, standard: Double(std.minimumMs), step: 10, unit: "ms")
        padding = slider(Double(initial.paddingMs), Self.paddingRange, standard: Double(std.paddingMs), step: 5, unit: "ms")
        previewLabel.font = Theme.Typography.bodyStrong
        previewLabel.textColor = Theme.Colors.label
        let hint = SQDialog.formText("Red ranges on the timeline will be cut. “Mark for Review” leaves them as proposed cuts to accept or reject.")
        let previewRow = SQDialog.pad(previewLabel, SQDialogMetrics.insets(0, 0))
        let stack = SQDialogForm(rows: [SQDialog.formRow("Level", threshold),
                                        SQDialog.formRow("Min. Length", minimum),
                                        SQDialog.formRow("Keep Each Side", padding), previewRow, hint])
        view = stack
        super.init()
        for s in [threshold, minimum, padding] {
            s.onChange = { [weak self] _ in self?.refresh() }
            s.onEnd = { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let s = settings
        // The applied values are rounded (1 dB, 50 ms, 10 ms): show them, so the fields never claim more than is used.
        threshold.value = s.thresholdDB; minimum.value = Double(s.minimumMs); padding.value = Double(s.paddingMs)
        let p = preview(s)
        previewLabel.stringValue = SilenceSettings.previewText(count: p.count, removed: p.removed)
    }

    /// Value labels and preview line (tests).
    var labels: [String] { [threshold.field.displayText, minimum.field.displayText, padding.field.displayText, previewLabel.stringValue] }
}
