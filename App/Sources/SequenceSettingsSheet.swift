import AppKit
import SQEditorSession
import SQEditorUI
import SQCore
import SQText
import SQUIKit

/// Sequence Settings and New Sequence (windows proposal section 5): a modal with Name, Preset, Frame Size (with swap),
/// Frame Rate, Sample Rate and Timeline (Normal / Fast Cut).
/// `present` shows it as a sheet; `completion` gets the result on OK and is not called on Cancel.
@MainActor
final class SequenceSettingsSheet: NSObject, NSTextFieldDelegate {
    private static let customTitle = "Custom"

    private let presetPopup = SQPopup(frame: .zero, pullsDown: false)
    /// Frame size in px; double-click resets to the size the sheet opened with.
    private let widthField = SQDialog.makeNumberField(range: 1...Double(SequenceFormatPresets.maxDimension), step: 1, width: nil)
    private let heightField = SQDialog.makeNumberField(range: 1...Double(SequenceFormatPresets.maxDimension), step: 1, width: nil)
    private let ratePopup = SQPopup(frame: .zero, pullsDown: false)
    private let shapePopup = SQPopup(frame: .zero, pullsDown: false)
    /// Pixel Shape choices: the ratios of `PixelAspect.presets` (plus the sequence's own if it is not one of them).
    private let shapes: [PixelAspect]
    private let audioPopup = SQPopup(frame: .zero, pullsDown: false)
    private let nameField = SQDialog.makeField("", width: nil)
    private let modeSegmented = SQSegmented(labels: ["Normal", "Fast Cut"], segmentWidth: 84)
    private let startField = SQDialog.makeField("", width: nil)
    private let displaySegmented = SQSegmented(labels: ["Timecode", "Frames"], segmentWidth: 84)
    private let qualityPopup = SQPopup(frame: .zero, pullsDown: false)
    private let channelsSegmented = SQSegmented(labels: ["Stereo", "Mono"], segmentWidth: 84)
    private static let qualities: [SequencePreviewQuality?] = [nil, .full, .half, .quarter]
    /// Live Ducking for this project (one system with Preferences > Audio): follow Preferences, off, or an amount. Timing of an
    /// existing project setting is kept as it is.
    private let duckingPopup = SQPopup(frame: .zero, pullsDown: false)
    private var duckingChoices: [ProjectLiveDuckingChoices.Choice] = []
    private var projectDucking: ProjectLiveDucking?
    private let original: SequenceFormat
    private var keepAlive: SequenceSettingsSheet?
    private var target: DeliveryTarget?
    /// "Starts at" as a rational time plus its text; frame rate and Display changes reformat the text (see `TimecodeStartEntry`).
    private var start: TimecodeStartEntry

    private init(settings: SequenceSettings) {
        let format = settings.format
        original = format
        shapes = PixelAspect.presets + (PixelAspect.presets.contains(format.pixelAspect) ? [] : [format.pixelAspect])
        target = settings.deliveryTarget
        start = TimecodeStartEntry(start: settings.timecodeStart, frameDuration: format.frameDuration,
                                   framesOnly: settings.timecodeDisplay == .frames)
        super.init()
        presetPopup.addItem(withTitle: Self.customTitle)
        presetPopup.menu?.addItem(.separator())
        for n in SequenceFormatPresets.named { presetPopup.addItem(withTitle: n.name) }
        presetPopup.target = self
        presetPopup.action = #selector(namedPresetChanged)
        for a in shapes { shapePopup.addItem(withTitle: a.isSquare ? "Square" : "Anamorphic \(PixelAspectMenu.ratioText(a))") }
        shapePopup.selectItem(at: shapes.firstIndex(of: format.pixelAspect) ?? 0)
        shapePopup.target = self
        shapePopup.action = #selector(rateChanged)   // only re-syncs the preset popup
        for f in SequenceFormatPresets.frameRates { ratePopup.addItem(withTitle: f.label + " fps") }
        if SequenceFormatPresets.frameRate(format.frameDuration) == nil {
            ratePopup.addItem(withTitle: Self.label(format.frameDuration) + " fps")
        }
        for r in SequenceFormatPresets.sampleRates { audioPopup.addItem(withTitle: "\(r / 1000).\(r % 1000 / 100) kHz".replacingOccurrences(of: ".0 ", with: " ")) }
        if !SequenceFormatPresets.sampleRates.contains(format.audioSampleRate) { audioPopup.addItem(withTitle: "\(format.audioSampleRate) Hz") }

        widthField.value = Double(format.width); widthField.defaultValue = Double(format.width)
        heightField.value = Double(format.height); heightField.defaultValue = Double(format.height)
        for f in [widthField, heightField] {
            f.onChange = { [weak self] _ in self?.syncNamedPreset() }
            f.onEnd = { [weak self] _ in self?.syncNamedPreset() }
        }
        nameField.stringValue = settings.name
        ratePopup.target = self
        ratePopup.action = #selector(rateChanged)
        if let i = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == format.frameDuration }) {
            ratePopup.selectItem(at: i)
        } else { ratePopup.selectItem(at: ratePopup.numberOfItems - 1) }
        if let i = SequenceFormatPresets.sampleRates.firstIndex(of: format.audioSampleRate) { audioPopup.selectItem(at: i) }
        else { audioPopup.selectItem(at: audioPopup.numberOfItems - 1) }
        modeSegmented.selectedSegment = settings.editMode == .magnetic ? 1 : 0
        displaySegmented.selectedSegment = settings.timecodeDisplay == .frames ? 1 : 0
        startField.stringValue = start.text
        startField.delegate = self
        displaySegmented.target = self
        displaySegmented.action = #selector(displayChanged)
        for q in Self.qualities { qualityPopup.addItem(withTitle: q.flatMap { MonitorQuality(rawValue: $0.rawValue)?.title } ?? "App setting") }
        qualityPopup.selectItem(at: Self.qualities.firstIndex(of: settings.previewQuality) ?? 0)
        channelsSegmented.selectedSegment = settings.channelLayout == .mono ? 1 : 0
        syncNamedPreset()
    }

    /// Frame duration the rate popup shows right now.
    private var currentFrameDuration: Time {
        let rates = SequenceFormatPresets.frameRates
        let i = ratePopup.indexOfSelectedItem
        return i >= 0 && i < rates.count ? rates[i].frameDuration : original.frameDuration
    }

    /// Frame rate or Display changed: keep the start as a time and write the field again in the new rate and mode.
    private func refreshStart() {
        start.setText(startField.stringValue)
        start.reconfigure(frameDuration: currentFrameDuration, framesOnly: displaySegmented.selectedSegment == 1)
        startField.stringValue = start.text
        (startField as? SQTextField)?.isInvalid = false
    }

    @objc private func displayChanged() { refreshStart() }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === startField else { return }
        start.setText(startField.stringValue)
        (startField as? SQTextField)?.isInvalid = !start.isValid
    }

    /// OK closes only with a usable size and Starts at; otherwise the field shows its error state and nothing is lost.
    private func canConfirm() -> Bool {
        start.setText(startField.stringValue)
        (startField as? SQTextField)?.isInvalid = !start.isValid
        if !start.isValid { startField.window?.makeFirstResponder(startField); return false }
        if chosen() == nil { NSSound.beep(); return false }
        return true
    }

    /// "29.97", "24", "27.12": the rate with trailing zeros dropped.
    static func label(_ d: Time) -> String {
        let fps = Double(d.timescale) / Double(d.value)
        let s = String(format: "%.3f", fps)
        return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    @objc private func namedPresetChanged() {
        guard let n = SequenceFormatPresets.named.first(where: { $0.name == presetPopup.titleOfSelectedItem }) else { return }
        target = n.deliveryTarget
        widthField.value = Double(n.format.width)
        heightField.value = Double(n.format.height)
        if let i = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == n.format.frameDuration }) { ratePopup.selectItem(at: i) }
        refreshStart()
    }

    /// Named preset popup follows the fields: shows the preset when size and rate match one, else Custom.
    private func syncNamedPreset() {
        let w = Int(widthField.value.rounded()), h = Int(heightField.value.rounded())
        if let c = chosen(), c.width == w, c.height == h,
           let n = SequenceFormatPresets.named.first(where: { $0.format == c && $0.deliveryTarget == target })
                ?? SequenceFormatPresets.preset(matching: c) {
            presetPopup.selectItem(withTitle: n.name)
        } else { presetPopup.selectItem(withTitle: Self.customTitle) }
    }

    @objc private func rateChanged() { syncNamedPreset(); refreshStart() }

    /// Swap button: 1080 x 1920 becomes 1920 x 1080.
    @objc private func swapSize() {
        let w = widthField.value
        widthField.value = heightField.value
        heightField.value = w
        syncNamedPreset()
    }

    /// Group caption (board `cap`): quiet heading that starts at the label column's left edge.
    private static func groupCaption(_ title: String) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = Theme.Typography.body
        l.textColor = Theme.Colors.label3
        return SQDialog.pad(l, NSEdgeInsets(top: Theme.Spacing.sm, left: SQDialogMetrics.sidePad, bottom: 0, right: SQDialogMetrics.sidePad))
    }

    private func accessory(showTimeline: Bool) -> NSView {
        let times = NSTextField(labelWithString: "×")
        times.font = Theme.Typography.body; times.textColor = Theme.Colors.label3
        for f in [widthField, heightField] { f.leadingText = true; f.widthAnchor.constraint(equalToConstant: 72).isActive = true }
        let swap = SQButton(symbol: .swap, label: "Swap width and height", target: self, action: #selector(swapSize))
        swap.toolTip = "Swap width and height"
        for p in [ratePopup, shapePopup, audioPopup] { p.widthAnchor.constraint(equalToConstant: 120).isActive = true }
        nameField.placeholderString = "Sequence name"
        var rows: [NSView] = [SQDialog.formRow("Name", nameField), Self.groupCaption("Video"),
                              SQDialog.formRow("Preset", presetPopup),
                              SQDialog.formRow("Frame Size", [widthField, times, heightField, swap, NSView()]),
                              SQDialog.formRow("Pixel Shape", [shapePopup, NSView()]),
                              SQDialog.formRow("Frame Rate", [ratePopup, NSView()]),
                              Self.groupCaption("Audio"), SQDialog.formRow("Sample Rate", [audioPopup, NSView()])]
        if showTimeline {
            rows.append(SQDialog.formRow("Channels", [channelsSegmented, NSView()]))   // not in New Sequence: it creates from the format only
            rows += [SQDialog.formRow("Live Ducking", [duckingPopup, NSView()]),
                     SQDialog.formText("Music tracks get quieter while a Dialogue track speaks, in playback and export. Applies to the whole project; a track can opt out in its header menu."),
                     Self.groupCaption("Working"), SQDialog.formRow("Timeline", [modeSegmented, NSView()]),
                     SQDialog.formText("Normal keeps classic tracks. Fast Cut closes gaps on the main track by itself."),
                     Self.groupCaption("Timecode"), SQDialog.formRow("Starts at", [startField, NSView()]),
                     SQDialog.formRow("Display", [displaySegmented, NSView()]),
                     Self.groupCaption("Preview"), SQDialog.formRow("Quality", [qualityPopup, NSView()]),
                     SQDialog.formText("Starts at and Display change only what is shown. Quality is used while this sequence is open.")]
            startField.widthAnchor.constraint(equalToConstant: 120).isActive = true
            qualityPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }
        return SQDialogForm(rows: rows)
    }

    /// The format in the fields, or nil if the size is not a number in range.
    private func chosen() -> SequenceFormat? {
        let w = Int(widthField.value.rounded()), h = Int(heightField.value.rounded())
        let rates = SequenceFormatPresets.frameRates
        let i = ratePopup.indexOfSelectedItem
        let fd = i < rates.count ? rates[i].frameDuration : original.frameDuration
        let j = audioPopup.indexOfSelectedItem
        let sr = j < SequenceFormatPresets.sampleRates.count ? SequenceFormatPresets.sampleRates[j] : original.audioSampleRate
        var f = SequenceFormat(width: w, height: h, frameDuration: fd, audioSampleRate: sr)
        f.pixelAspect = shapes[max(0, min(shapePopup.indexOfSelectedItem, shapes.count - 1))]
        return f.isValid ? f : nil
    }

    /// `isNew`: New Sequence (`settings.name` is the suggested name, no Timeline row). Otherwise Sequence Settings of the
    /// active sequence. `completion` gets the edited settings on OK.
    static func present(on window: NSWindow, settings: SequenceSettings, isNew: Bool,
                        projectDucking: ProjectLiveDucking? = nil, preferredDucking: LiveDucking? = nil,
                        onDucking: (@MainActor (ProjectLiveDucking?) -> Void)? = nil,
                        completion: @escaping @MainActor (SequenceSettings) -> Void) {
        let sheet = SequenceSettingsSheet(settings: settings)
        sheet.projectDucking = projectDucking
        sheet.duckingChoices = ProjectLiveDuckingChoices.choices(current: projectDucking, preferences: preferredDucking)
        sheet.duckingPopup.addItems(withTitles: sheet.duckingChoices.map(\.title))
        sheet.duckingPopup.selectItem(at: ProjectLiveDuckingChoices.index(of: projectDucking, in: sheet.duckingChoices))
        sheet.duckingPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sheet.keepAlive = sheet
        let alert = SQDialog()
        alert.messageText = isNew ? "New Sequence" : "Sequence Settings"
        alert.informativeText = isNew ? "" : "Clips keep their scale and position."
        alert.width = SQModal.Size.m.width
        alert.accessoryView = sheet.accessory(showTimeline: !isNew)
        alert.addButton(isNew ? "Create" : "OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = isNew ? sheet.nameField : sheet.widthField
        alert.canClose = { [weak sheet] response in
            response != .first || (sheet?.canConfirm() ?? true)
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                defer { sheet.keepAlive = nil }
                guard response == .first else { return }
                guard let f = sheet.chosen() else { return }
                var out = settings
                out.name = sheet.nameField.stringValue
                out.format = f
                out.deliveryTarget = sheet.target
                if !isNew {
                    out.channelLayout = sheet.channelsSegmented.selectedSegment == 1 ? .mono : .stereo
                    out.editMode = sheet.modeSegmented.selectedSegment == 1 ? .magnetic : .normal
                    out.timecodeDisplay = sheet.displaySegmented.selectedSegment == 1 ? .frames : .timecode
                    out.timecodeStart = sheet.start.start
                    out.previewQuality = Self.qualities[max(0, sheet.qualityPopup.indexOfSelectedItem)]
                    let i = sheet.duckingPopup.indexOfSelectedItem
                    if sheet.duckingChoices.indices.contains(i) {
                        var chosen = sheet.duckingChoices[i].setting
                        if chosen?.isOn == true { chosen?.timing = projectDucking?.timing }
                        if chosen != projectDucking { onDucking?(chosen) }
                    }
                }
                completion(out)
            }
        }
    }
}

extension AppController {
    @objc func changeFormatItem(_ sender: Any?) {
        guard let tl = session.activeTimeline else { shell.statusBar.flash("Open a sequence first."); return }
        ChangeFormatSheet.present(on: window, current: tl.format, hasSelection: !session.selection.isEmpty, name: nil) { [weak self] r in
            guard let self, r.format != tl.format else { return }
            if !session.changeActiveFormat(to: r.format, mode: r.mode, selectedMode: r.selectedMode) {
                shell.statusBar.flash("Could not change the format.")
            }
        }
    }

    @objc func duplicateAsFormatItem(_ sender: Any?) {
        guard let tl = session.activeTimeline else { shell.statusBar.flash("Open a sequence first."); return }
        ChangeFormatSheet.present(on: window, current: tl.format, hasSelection: !session.selection.isEmpty, name: "") { [weak self] r in
            guard let self else { return }
            if session.duplicateActiveSequence(as: r.format, mode: r.mode, selectedMode: r.selectedMode, name: r.name) == nil {
                shell.statusBar.flash("Could not duplicate the sequence.")
            }
        }
    }
}
