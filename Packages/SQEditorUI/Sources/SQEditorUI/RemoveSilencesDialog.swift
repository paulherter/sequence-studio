import AppKit
import SQCore

/// Settings of "Remove Silences…": what counts as a pause and how much of it stays.
public struct SilenceSettings: Sendable, Equatable {
    /// Audio quieter than this (peak, dB) is silence.
    public var thresholdDB: Double
    /// A pause must last at least this many milliseconds.
    public var minimumMs: Int
    /// Milliseconds of every pause that stay at both ends (so cuts do not sound clipped).
    public var paddingMs: Int

    public static let standard = SilenceSettings(thresholdDB: -35, minimumMs: 350, paddingMs: 100)

    public init(thresholdDB: Double, minimumMs: Int, paddingMs: Int) {
        self.thresholdDB = thresholdDB; self.minimumMs = minimumMs; self.paddingMs = paddingMs
    }

    public var minimum: Time { Time(Int64(max(minimumMs, 0)), 1000) }
    public var padding: Time { Time(Int64(max(paddingMs, 0)), 1000) }

    private enum Key { static let db = "sq.silence.thresholdDB", min = "sq.silence.minMs", pad = "sq.silence.padMs" }

    /// Last values used, or the defaults.
    public static func remembered(_ d: UserDefaults = .standard) -> SilenceSettings {
        guard d.object(forKey: Key.db) != nil else { return .standard }
        return SilenceSettings(thresholdDB: d.double(forKey: Key.db), minimumMs: d.integer(forKey: Key.min), paddingMs: d.integer(forKey: Key.pad))
    }

    public func remember(_ d: UserDefaults = .standard) {
        d.set(thresholdDB, forKey: Key.db); d.set(minimumMs, forKey: Key.min); d.set(paddingMs, forKey: Key.pad)
    }

    /// "12 pauses, 8.4 s will be removed" for the dialog's preview line.
    public static func previewText(count: Int, removed: Time) -> String {
        guard count > 0 else { return "No pauses found." }
        let sec = Double(removed.value) / Double(removed.timescale)
        return "\(count) \(count == 1 ? "pause" : "pauses"), \(String(format: "%.1f", sec)) s will be removed."
    }
}

/// The Remove Silences sheet: threshold, minimum length and padding, with a live count of what would be cut.
/// Nothing happens until OK; the cut is one undo step.
@MainActor
public enum RemoveSilencesDialog {
    public typealias Preview = @MainActor (SilenceSettings) -> (count: Int, removed: Time)

    public static func present(on window: NSWindow, clipName: String, initial: SilenceSettings, preview: @escaping Preview,
                               completion: @escaping @MainActor (SilenceSettings?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove Silences"
        alert.informativeText = clipName + "\nPauses are cut out of the sequence and the gap is closed. Audio and picture stay in sync."
        let ui = makeView(initial: initial, preview: preview)
        alert.accessoryView = ui.view
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(ui.controller) {}
                completion(response == .alertFirstButtonReturn ? ui.controller.settings : nil)
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
public final class SilenceFieldsController: NSObject, NSTextFieldDelegate {
    private let threshold = NSTextField(string: ""), minimum = NSTextField(string: ""), padding = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let preview: RemoveSilencesDialog.Preview
    public let view: NSView

    public var settings: SilenceSettings {
        SilenceSettings(thresholdDB: min(max(threshold.doubleValue, -90), 0), minimumMs: max(minimum.integerValue, 50),
                        paddingMs: max(padding.integerValue, 0))
    }

    init(initial: SilenceSettings, preview: @escaping RemoveSilencesDialog.Preview) {
        self.preview = preview
        threshold.stringValue = String(format: "%g", initial.thresholdDB)
        minimum.stringValue = "\(initial.minimumMs)"
        padding.stringValue = "\(initial.paddingMs)"
        func unit(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.textColor = .secondaryLabelColor; return l }
        for f in [threshold, minimum, padding] { f.alignment = .right; f.widthAnchor.constraint(equalToConstant: 64).isActive = true }
        previewLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Silence below"), threshold, unit("dB")],
            [NSTextField(labelWithString: "Pauses longer than"), minimum, unit("ms")],
            [NSTextField(labelWithString: "Keep padding"), padding, unit("ms each side")],
        ])
        grid.rowSpacing = 6; grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [grid, previewLabel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 330, height: 108)
        view = stack
        super.init()
        for f in [threshold, minimum, padding] { f.delegate = self }
        refresh()
    }

    public func controlTextDidChange(_ obj: Notification) { refresh() }

    func refresh() {
        let p = preview(settings)
        previewLabel.stringValue = SilenceSettings.previewText(count: p.count, removed: p.removed)
    }
}
