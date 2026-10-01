import AppKit
import SSCore

/// Sequence Settings and New Sequence (Premiere): frame size with presets, frame rate, audio sample rate.
/// `present` shows it as a sheet; `completion` gets the chosen name and format on OK, nil on Cancel.
@MainActor
final class SequenceSettingsSheet: NSObject, NSTextFieldDelegate {
    private static let customTitle = "Custom"

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let ratePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let audioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")
    private let original: SequenceFormat
    private var keepAlive: SequenceSettingsSheet?

    private init(format: SequenceFormat, name: String?) {
        original = format
        super.init()
        presetPopup.addItem(withTitle: Self.customTitle)
        presetPopup.menu?.addItem(.separator())
        for n in SequenceFormatPresets.named { presetPopup.addItem(withTitle: n.name) }
        presetPopup.target = self
        presetPopup.action = #selector(namedPresetChanged)
        for s in SequenceFormatPresets.sizes { sizePopup.addItem(withTitle: s.name) }
        sizePopup.addItem(withTitle: Self.customTitle)
        sizePopup.target = self
        sizePopup.action = #selector(sizePresetChanged)
        for f in SequenceFormatPresets.frameRates { ratePopup.addItem(withTitle: f.label + " fps") }
        if SequenceFormatPresets.frameRate(format.frameDuration) == nil {
            ratePopup.addItem(withTitle: Self.label(format.frameDuration) + " fps")
        }
        for r in SequenceFormatPresets.sampleRates { audioPopup.addItem(withTitle: "\(r / 1000).\(r % 1000 / 100) kHz".replacingOccurrences(of: ".0 ", with: " ")) }
        if !SequenceFormatPresets.sampleRates.contains(format.audioSampleRate) { audioPopup.addItem(withTitle: "\(format.audioSampleRate) Hz") }

        widthField.stringValue = "\(format.width)"
        heightField.stringValue = "\(format.height)"
        for f in [widthField, heightField] { f.delegate = self; f.alignment = .right }
        nameField.stringValue = name ?? ""
        selectSizePreset()
        ratePopup.target = self
        ratePopup.action = #selector(rateChanged)
        if let i = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == format.frameDuration }) {
            ratePopup.selectItem(at: i)
        } else { ratePopup.selectItem(at: ratePopup.numberOfItems - 1) }
        if let i = SequenceFormatPresets.sampleRates.firstIndex(of: format.audioSampleRate) { audioPopup.selectItem(at: i) }
        else { audioPopup.selectItem(at: audioPopup.numberOfItems - 1) }
        syncNamedPreset()
    }

    /// "29.97", "24", "27.12": the rate with trailing zeros dropped.
    static func label(_ d: Time) -> String {
        let fps = Double(d.timescale) / Double(d.value)
        let s = String(format: "%.3f", fps)
        return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    @objc private func namedPresetChanged() {
        guard let n = SequenceFormatPresets.named.first(where: { $0.name == presetPopup.titleOfSelectedItem }) else { return }
        widthField.stringValue = "\(n.format.width)"
        heightField.stringValue = "\(n.format.height)"
        selectSizePreset()
        if let i = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == n.format.frameDuration }) { ratePopup.selectItem(at: i) }
    }

    /// Named preset popup follows the fields: shows the preset when size and rate match one, else Custom.
    private func syncNamedPreset() {
        if let w = Int(widthField.stringValue), let h = Int(heightField.stringValue), let c = chosen(), c.width == w, c.height == h,
           let n = SequenceFormatPresets.preset(matching: c) {
            presetPopup.selectItem(withTitle: n.name)
        } else { presetPopup.selectItem(withTitle: Self.customTitle) }
    }

    @objc private func sizePresetChanged() {
        let i = sizePopup.indexOfSelectedItem
        guard i < SequenceFormatPresets.sizes.count else { return }
        widthField.stringValue = "\(SequenceFormatPresets.sizes[i].width)"
        heightField.stringValue = "\(SequenceFormatPresets.sizes[i].height)"
        syncNamedPreset()
    }

    @objc private func rateChanged() { syncNamedPreset() }

    func controlTextDidChange(_ obj: Notification) { selectSizePreset(); syncNamedPreset() }

    private func selectSizePreset() {
        if let w = Int(widthField.stringValue), let h = Int(heightField.stringValue),
           let i = SequenceFormatPresets.sizes.firstIndex(where: { $0.width == w && $0.height == h }) {
            sizePopup.selectItem(at: i)
        } else { sizePopup.selectItem(withTitle: Self.customTitle) }
    }

    private func accessory(showName: Bool) -> NSView {
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let sizeRow = NSStackView(views: [widthField, NSTextField(labelWithString: "×"), heightField, NSTextField(labelWithString: "px")])
        sizeRow.spacing = 6
        widthField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        heightField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        var rows: [[NSView]] = []
        if showName { nameField.placeholderString = "Sequence name"; rows.append([label("Name"), nameField]) }
        rows += [[label("Preset"), presetPopup], [label("Size preset"), sizePopup], [label("Frame size"), sizeRow], [label("Frame rate"), ratePopup],
                 [label("Audio sample rate"), audioPopup]]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(rows.count) * 30)
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return grid
    }

    /// The format in the fields, or nil if the size is not a number in range.
    private func chosen() -> SequenceFormat? {
        guard let w = Int(widthField.stringValue), let h = Int(heightField.stringValue) else { return nil }
        let rates = SequenceFormatPresets.frameRates
        let i = ratePopup.indexOfSelectedItem
        let fd = i < rates.count ? rates[i].frameDuration : original.frameDuration
        let j = audioPopup.indexOfSelectedItem
        let sr = j < SequenceFormatPresets.sampleRates.count ? SequenceFormatPresets.sampleRates[j] : original.audioSampleRate
        let f = SequenceFormat(width: w, height: h, frameDuration: fd, audioSampleRate: sr)
        return f.isValid ? f : nil
    }

    /// `name == nil`: Sequence Settings of the active sequence. Otherwise New Sequence with that suggested name.
    static func present(on window: NSWindow, format: SequenceFormat, name: String?,
                        completion: @escaping @MainActor (_ name: String, _ format: SequenceFormat) -> Void) {
        let sheet = SequenceSettingsSheet(format: format, name: name)
        sheet.keepAlive = sheet
        let alert = NSAlert()
        alert.messageText = name == nil ? "Sequence Settings" : "New Sequence"
        alert.informativeText = name == nil
            ? "Clips keep their scale and position; only the canvas changes."
            : "Pick a preset or enter a custom frame size."
        alert.accessoryView = sheet.accessory(showName: name != nil)
        alert.addButton(withTitle: name == nil ? "OK" : "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name == nil ? sheet.widthField : sheet.nameField
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                defer { sheet.keepAlive = nil }
                guard response == .alertFirstButtonReturn else { return }
                guard let f = sheet.chosen() else {
                    NSSound.beep(); return
                }
                completion(sheet.nameField.stringValue, f)
            }
        }
    }
}
