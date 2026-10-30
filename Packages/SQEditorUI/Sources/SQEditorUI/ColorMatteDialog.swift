import AppKit
import SQCore

/// Sheet for a new Color Matte: name, color (the one SQ color picker) and duration. Adds when the button is pressed.
@MainActor
public enum ColorMatteDialog {
    public struct Result: Equatable, Sendable {
        public var name: String
        public var color: ColorMatteColor
        public var duration: Time
    }

    public static let defaultDuration = Time(5, 1)
    public static let durationSeconds: ClosedRange<Double> = 0.1...3600

    /// The accessory view alone, so a test can render it.
    public static func makeView(name: String, color: ColorMatteColor, durationSeconds seconds: Double)
        -> (view: NSView, name: NSTextField, color: SQColorWell, duration: NumericSlider) {
        let field = SQDialog.makeField(width: 220)
        field.stringValue = name
        let well = SQColorWell(frame: .zero)
        well.color = nsColor(color)
        let duration = NumericSlider(value: seconds, range: durationSeconds, defaultValue: 5, step: 0.5, decimals: 1, unit: "s")
        duration.fieldWidth = 72
        duration.gap = 12
        duration.field.leadingText = true
        duration.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let grid = SQDialogForm(rows: [SQDialog.formRow("Name", field), SQDialog.formRow("Color", well),
                                       SQDialog.formRow("Duration", duration)])
        return (grid, field, well, duration)
    }

    public static func nsColor(_ c: ColorMatteColor) -> NSColor {
        SQColorValue(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255).nsColor
    }

    public static func matteColor(_ c: NSColor) -> ColorMatteColor {
        let v = SQColorValue(c).rgb
        func b(_ x: Double) -> UInt8 { UInt8((min(max(x, 0), 1) * 255).rounded()) }
        return ColorMatteColor(r: b(v.r), g: b(v.g), b: b(v.b))
    }

    public static func present(on window: NSWindow, completion: @escaping @MainActor (Result) -> Void) {
        let alert = SQDialog()
        alert.messageText = "New Color Matte"
        alert.informativeText = "A flat color layer for when there is no video. It goes on the timeline at the playhead."
        alert.width = SQModal.Size.xs.width
        let v = makeView(name: "Color Matte", color: .default, durationSeconds: 5)
        alert.accessoryView = v.view
        alert.addButton("Add")
        alert.addButton("Cancel")
        alert.initialFirstResponder = v.name
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { return }
                let n = v.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                // The seconds field is a whole number of milliseconds: the session snaps it to a frame.
                let ms = Int64((v.duration.value * 1000).rounded())
                completion(Result(name: n.isEmpty ? "Color Matte" : n, color: matteColor(v.color.color), duration: Time(ms, 1000)))
            }
        }
    }
}
