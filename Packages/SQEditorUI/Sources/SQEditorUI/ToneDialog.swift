import AppKit
import SQCore

/// Sheet for a tone clip's frequency and level (Tone Settings). Applies when OK is pressed.
@MainActor
public enum ToneDialog {
    /// The accessory view alone, so a test can render it.
    public static func makeView(_ spec: ToneSpec) -> (view: NSView, frequency: NumericSlider, level: NumericSlider) {
        let hz = ToneSpec.frequencyRange
        let frequency = NumericSlider(value: spec.frequencyHz, range: Double(hz.lowerBound) / 1000...Double(hz.upperBound) / 1000,
                                      defaultValue: ToneSpec.default.frequencyHz, step: 1, decimals: 0, unit: "Hz")
        let lv = ToneSpec.levelRange
        let level = NumericSlider(value: spec.levelDB, range: Double(lv.lowerBound) / 100...Double(lv.upperBound) / 100,
                                  defaultValue: ToneSpec.default.levelDB, step: 0.5, decimals: 1, unit: "dB")
        for s in [frequency, level] {
            s.fieldWidth = 72
            s.gap = 12
            s.field.leadingText = true
            s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let grid = SQDialogForm(rows: [SQDialog.formRow("Frequency", frequency), SQDialog.formRow("Level", level)])
        return (grid, frequency, level)
    }

    public static func present(on window: NSWindow, spec: ToneSpec, confirm: String = "OK", completion: @escaping @MainActor (ToneSpec) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Tone Settings"
        alert.informativeText = "Sine tone, 1 kHz at -12 dB by default"
        alert.width = SQModal.Size.xs.width
        let v = makeView(spec)
        alert.accessoryView = v.view
        alert.addButton(confirm)
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { return }
                completion(ToneSpec(frequencyHz: v.frequency.value, levelDB: v.level.value))
            }
        }
    }
}
