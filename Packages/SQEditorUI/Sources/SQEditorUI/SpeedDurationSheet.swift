import AppKit
import SQCore

/// Clip > Speed sheet (Cmd+R): Speed %, Duration timecode with a link between them, Reverse Speed,
/// Keep Pitch, Move Later Clips (board `Dialogs`). Logic lives in `SpeedDialogModel`.
@MainActor
public final class SpeedDurationSheet: NSObject {
    private var model: SpeedDialogModel
    private let originalDuration: Time
    private let timecode: Timecode
    /// Speed in percent (negative = reverse); double-click resets to 100 %.
    private let speedField = SQDialog.makeNumberField(value: 100, range: -SpeedDialogModel.percentRange.upperBound...SpeedDialogModel.percentRange.upperBound,
                                                      step: 1, decimals: 1, unit: "%", defaultValue: 100, width: nil)
    /// Duration as a timecode; the value is a frame count (one pixel = one frame).
    private let durationField = SQDialog.makeNumberField(range: 1...10_000_000, step: 1, width: nil)
    private let linkButton = SQButton(frame: .zero)
    private let reverseBox = SQCheckbox(title: "Reverse", target: nil, action: nil)
    private let pitchBox = SQCheckbox(title: "Keep Pitch", target: nil, action: nil)
    private let interpolationPopUp = SQPopup(frame: .zero, pullsDown: false)
    private let rippleBox = SQCheckbox(title: "Move Later Clips", target: nil, action: nil)

    init(model: SpeedDialogModel, timecode: Timecode) {
        self.model = model; self.timecode = timecode
        originalDuration = model.duration
        super.init()
    }

    /// Presents the sheet on `window`; `completion` gets the change on OK, nil on Cancel (or when nothing changed).
    public static func present(on window: NSWindow, model: SpeedDialogModel, timecode: Timecode,
                               completion: @escaping @MainActor (SpeedChange?) -> Void) {
        let sheet = SpeedDurationSheet(model: model, timecode: timecode)
        let alert = SQDialog()
        alert.messageText = "Speed"
        alert.accessoryView = sheet.buildView()
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = sheet.speedField
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                sheet.commitEditing()
                _ = sheet      // keep the delegate alive until the sheet ends
                completion(response == .first && sheet.model.hasChanges ? sheet.model.change : nil)
            }
        }
    }

    func buildView() -> NSView {
        let fd = model.frameDuration
        durationField.valueFormatter = { [timecode] frames in timecode.format(Time(Int64(frames.rounded()) * fd.value, fd.timescale)) }
        durationField.valueParser = { [timecode] text in timecode.parse(text).map { Self.frameCount($0, fd) } }
        durationField.defaultValue = Self.frameCount(model.duration, fd)
        speedField.onEnd = { [weak self] v in self?.speedEdited(v) }
        speedField.onReset = { [weak self] in self?.speedEdited(100) }
        durationField.onEnd = { [weak self] v in self?.durationEdited(v) }
        durationField.onReset = { [weak self] in
            guard let self else { return }
            self.durationEdited(Self.frameCount(self.originalDuration, self.model.frameDuration))
        }
        speedField.setAccessibilityLabel("Speed in percent")
        durationField.setAccessibilityLabel("Duration timecode")
        durationField.isEnabled = model.canEditDuration

        linkButton.style = .icon
        linkButton.imagePosition = .imageOnly
        linkButton.target = self
        linkButton.action = #selector(linkToggled)
        linkButton.sqToolTip = "Link speed and duration"
        linkButton.isEnabled = model.canEditDuration
        linkButton.setAccessibilityLabel("Link speed and duration")

        reverseBox.target = self; reverseBox.action = #selector(optionsChanged)
        pitchBox.target = self; pitchBox.action = #selector(optionsChanged)
        rippleBox.target = self; rippleBox.action = #selector(optionsChanged)
        pitchBox.isEnabled = model.hasAudio
        pitchBox.sqToolTip = "Time-stretches the audio so the pitch stays when the speed changes."
        rippleBox.sqToolTip = "Later clips on all sync-locked tracks move with the new length."

        speedField.leadingText = true
        durationField.leadingText = true
        let trail = SQDialogMetrics.sidePad * 2 + 24
        let fields = SQDialogForm(rows: [SQDialog.formRow("Speed", speedField, trailing: trail),
                                         SQDialog.formRow("Duration", durationField, trailing: trail)])
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        fields.addSubview(linkButton)
        NSLayoutConstraint.activate([
            linkButton.widthAnchor.constraint(equalToConstant: 24),
            linkButton.heightAnchor.constraint(equalToConstant: Theme.Row.control),
            linkButton.trailingAnchor.constraint(equalTo: fields.trailingAnchor, constant: -SQDialogMetrics.sidePad),
            linkButton.centerYAnchor.constraint(equalTo: fields.centerYAnchor),
        ])

        for t in TimeInterpolation.allCases { interpolationPopUp.addItem(withTitle: t.title) }
        interpolationPopUp.target = self; interpolationPopUp.action = #selector(optionsChanged)
        interpolationPopUp.sqToolTip = "Repeat frames repeats the nearest frame; Blend frames mixes the two frames around the moment; Optical flow moves both frames along their motion to the moment (smoothest slow motion, falls back to blending where the motion is unclear)."
        interpolationPopUp.setAccessibilityLabel("Frames")
        let interpolationRow = SQDialog.formRow("Frames", interpolationPopUp)
        interpolationRow.isHidden = !model.hasVideo
        let all = SQDialogForm(rows: [fields, interpolationRow, SQDialog.checkRow(reverseBox), SQDialog.checkRow(pitchBox),
                                      SQDialog.checkRow(rippleBox)])
        refresh()
        return all
    }

    private func refresh() {
        speedField.value = model.percent
        durationField.value = Self.frameCount(model.duration, model.frameDuration)
        linkButton.contentTintColor = model.isLinked ? Theme.Colors.accent : Theme.Colors.label2
        linkButton.image = Theme.symbol(model.isLinked ? .link : .unlink, size: 12, label: "Link")
        reverseBox.state = model.reversed ? .on : .off
        pitchBox.state = model.keepsPitch ? .on : .off
        rippleBox.state = model.ripple ? .on : .off
        interpolationPopUp.selectItem(at: TimeInterpolation.allCases.firstIndex(of: model.timeInterpolation) ?? 0)
    }

    /// Reads whichever field is being edited into the model.
    private func commitEditing() {
        speedField.window?.makeFirstResponder(nil)
    }

    private func speedEdited(_ v: Double) {
        model.setPercent(v)
        refresh()
    }

    private func durationEdited(_ frames: Double) {
        let fd = model.frameDuration
        model.setDuration(Time(Int64(frames.rounded()) * fd.value, fd.timescale))
        refresh()
    }

    /// Frames in `t` (Double for the field).
    nonisolated static func frameCount(_ t: Time, _ fd: Time) -> Double {
        Double(t.value * fd.timescale) / Double(t.timescale * fd.value)
    }

    @objc private func linkToggled() { model.isLinked.toggle(); refresh() }

    @objc private func optionsChanged() {
        model.reversed = reverseBox.state == .on
        model.keepsPitch = pitchBox.state == .on
        model.ripple = rippleBox.state == .on
        model.timeInterpolation = TimeInterpolation.allCases[max(interpolationPopUp.indexOfSelectedItem, 0)]
    }
}
