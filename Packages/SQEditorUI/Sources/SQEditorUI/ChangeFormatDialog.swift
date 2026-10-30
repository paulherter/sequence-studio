import AppKit
import SQCore
import SQUIKit

/// Sequence > Change Format… and Duplicate as Format… (multi-format phase 1): pick a shape (9:16, 16:9, 4:5, 1:1, 4:3 or
/// a custom size) and how picture clips conform (fit or fill, the selected clips may differ). Text clips keep their size
/// and stay inside the title safe area (see `SequenceConform`). Frame rate and sample rate are kept.
@MainActor
public final class ChangeFormatSheet: NSObject {
    public struct Result {
        public var format: SequenceFormat
        public var mode: ConformMode
        /// Mode for the selected clips; nil = same as `mode`.
        public var selectedMode: ConformMode?
        public var name: String
    }

    let shapePopup = SQPopup(frame: .zero, pullsDown: false)
    let widthField = SQDialog.makeNumberField(range: 1...Double(SequenceFormatPresets.maxDimension), step: 1, width: nil)
    let heightField = SQDialog.makeNumberField(range: 1...Double(SequenceFormatPresets.maxDimension), step: 1, width: nil)
    let modePopup = SQPopup(frame: .zero, pullsDown: false)
    let selectedPopup = SQPopup(frame: .zero, pullsDown: false)
    let nameField = SQDialog.makeField("", width: nil)
    private let current: SequenceFormat
    private var keepAlive: ChangeFormatSheet?

    init(current: SequenceFormat) {
        self.current = current
        super.init()
        for p in SequenceConform.aspectPresets { shapePopup.addItem(withTitle: "\(p.name)  (\(p.width) × \(p.height))") }
        shapePopup.addItem(withTitle: "Custom")
        shapePopup.target = self
        shapePopup.action = #selector(shapeChanged)
        for m in ConformMode.allCases { modePopup.addItem(withTitle: m.title) }
        modePopup.selectItem(at: ConformMode.allCases.firstIndex(of: .fill) ?? 0)
        selectedPopup.addItem(withTitle: "Same as all clips")
        for m in ConformMode.allCases { selectedPopup.addItem(withTitle: m.title) }
        for f in [widthField, heightField] {
            f.onChange = { [weak self] _ in self?.syncShape() }
            f.onEnd = { [weak self] _ in self?.syncShape() }
        }
        // Start on the first shape that differs from the current one.
        let start = SequenceConform.aspectPresets.first {
            $0.width * current.height != $0.height * current.width
        } ?? SequenceConform.aspectPresets[0]
        widthField.value = Double(start.width); widthField.defaultValue = Double(start.width)
        heightField.value = Double(start.height); heightField.defaultValue = Double(start.height)
        syncShape()
    }

    @objc private func shapeChanged() {
        let i = shapePopup.indexOfSelectedItem
        guard i < SequenceConform.aspectPresets.count else { return }
        widthField.value = Double(SequenceConform.aspectPresets[i].width)
        heightField.value = Double(SequenceConform.aspectPresets[i].height)
    }

    private func syncShape() {
        let w = Int(widthField.value.rounded()), h = Int(heightField.value.rounded())
        if let i = SequenceConform.aspectPresets.firstIndex(where: { $0.width == w && $0.height == h }) {
            shapePopup.selectItem(at: i)
        } else { shapePopup.selectItem(withTitle: "Custom") }
    }

    func chosen() -> SequenceFormat? {
        let w = Int(widthField.value.rounded()), h = Int(heightField.value.rounded())
        var f = current
        f.width = w; f.height = h
        return f.isValid ? f : nil
    }

    func accessory(hasSelection: Bool, name: String?) -> NSView {
        var rows: [NSView] = []
        if let name {
            nameField.stringValue = name
            nameField.placeholderString = "Automatic (name + shape)"
            rows.append(SQDialog.formRow("Name", nameField))
        }
        let times = NSTextField(labelWithString: "×")
        times.font = Theme.Typography.body; times.textColor = Theme.Colors.label3
        // Board: both size fields 1fr of the 260 pt control column (minus the x and two gaps) = 117 pt.
        for f in [widthField, heightField] { f.leadingText = true; f.widthAnchor.constraint(equalToConstant: 117).isActive = true }
        modePopup.sqToolTip = "Fill crops, Fit shows bars. Text keeps its size and stays inside the title safe area."
        rows += [SQDialog.formRow("Format", shapePopup), SQDialog.formRow("Frame Size", [widthField, times, heightField]),
                 SQDialog.formRow("Clips", modePopup)]
        if hasSelection { rows.append(SQDialog.formRow("Selected Clips", selectedPopup)) }
        return SQDialogForm(rows: rows)
    }

    /// `name == nil`: Change Format of the active sequence. Otherwise Duplicate as Format with that suggested name
    /// (empty = automatic "<name> <shape>").
    public static func present(on window: NSWindow, current: SequenceFormat, hasSelection: Bool, name: String?,
                        completion: @escaping @MainActor (Result) -> Void) {
        let sheet = ChangeFormatSheet(current: current)
        sheet.keepAlive = sheet
        let alert = SQDialog()
        alert.messageText = name == nil ? "Change Format" : "Duplicate as Format"
        alert.informativeText = name == nil ? "Every clip is reframed for the new size." : "A reframed copy is added."
        alert.width = SQModal.Size.s.width
        alert.accessoryView = sheet.accessory(hasSelection: hasSelection, name: name)
        alert.addButton(name == nil ? "Change" : "Duplicate")
        alert.addButton("Cancel")
        alert.initialFirstResponder = sheet.shapePopup
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                defer { sheet.keepAlive = nil }
                guard response == .first else { return }
                guard let f = sheet.chosen() else { NSSound.beep(); return }
                let modes = ConformMode.allCases
                let mode = modes[max(0, min(sheet.modePopup.indexOfSelectedItem, modes.count - 1))]
                let si = sheet.selectedPopup.indexOfSelectedItem
                let selectedMode: ConformMode? = hasSelection && si >= 1 && si <= modes.count ? modes[si - 1] : nil
                completion(Result(format: f, mode: mode, selectedMode: selectedMode, name: sheet.nameField.stringValue))
            }
        }
    }
}
