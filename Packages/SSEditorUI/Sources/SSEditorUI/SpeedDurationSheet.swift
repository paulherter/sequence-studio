import AppKit
import SSCore

/// Clip > Speed/Duration sheet (Cmd+R): Speed %, Duration timecode with a link between them, Reverse Speed,
/// Maintain Audio Pitch, Ripple Edit Shifting Trailing Clips. Logic lives in `SpeedDialogModel`.
@MainActor
public final class SpeedDurationSheet: NSObject, NSTextFieldDelegate {
    private var model: SpeedDialogModel
    private let timecode: Timecode
    private let speedField = NSTextField()
    private let durationField = NSTextField()
    private let linkButton = NSButton()
    private let reverseBox = NSButton(checkboxWithTitle: "Reverse Speed", target: nil, action: nil)
    private let pitchBox = NSButton(checkboxWithTitle: "Maintain Audio Pitch", target: nil, action: nil)
    private let rippleBox = NSButton(checkboxWithTitle: "Ripple Edit, Shifting Trailing Clips", target: nil, action: nil)

    init(model: SpeedDialogModel, timecode: Timecode) {
        self.model = model; self.timecode = timecode
        super.init()
    }

    /// Presents the sheet on `window`; `completion` gets the change on OK, nil on Cancel (or when nothing changed).
    public static func present(on window: NSWindow, model: SpeedDialogModel, timecode: Timecode,
                               completion: @escaping @MainActor (SpeedChange?) -> Void) {
        let sheet = SpeedDurationSheet(model: model, timecode: timecode)
        let alert = NSAlert()
        alert.messageText = "Clip Speed / Duration"
        alert.accessoryView = sheet.buildView()
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = sheet.speedField
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                sheet.commitEditing()
                _ = sheet      // keep the delegate alive until the sheet ends
                completion(response == .alertFirstButtonReturn && sheet.model.hasChanges ? sheet.model.change : nil)
            }
        }
    }

    func buildView() -> NSView {
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return l
        }
        for f in [speedField, durationField] {
            f.delegate = self
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        speedField.setAccessibilityLabel("Speed in percent")
        durationField.setAccessibilityLabel("Duration timecode")
        durationField.isEnabled = model.canEditDuration

        linkButton.setButtonType(.pushOnPushOff)
        linkButton.bezelStyle = .texturedRounded
        linkButton.imagePosition = .imageOnly
        linkButton.target = self
        linkButton.action = #selector(linkToggled)
        linkButton.toolTip = "Link speed and duration"
        linkButton.isEnabled = model.canEditDuration
        linkButton.setAccessibilityLabel("Link speed and duration")

        reverseBox.target = self; reverseBox.action = #selector(optionsChanged)
        pitchBox.target = self; pitchBox.action = #selector(optionsChanged)
        rippleBox.target = self; rippleBox.action = #selector(optionsChanged)
        pitchBox.isEnabled = model.hasAudio
        pitchBox.toolTip = "Time-stretches the audio so the pitch stays when the speed changes."
        rippleBox.toolTip = "Later clips on all sync-locked tracks move with the new length."

        let pct = NSTextField(labelWithString: "%")
        let speedRow = NSStackView(views: [label("Speed:"), speedField, pct])
        let durationRow = NSStackView(views: [label("Duration:"), durationField])
        for r in [speedRow, durationRow] { r.orientation = .horizontal; r.spacing = 6; r.alignment = .centerY }
        let fields = NSStackView(views: [speedRow, durationRow])
        fields.orientation = .vertical; fields.spacing = 8; fields.alignment = .leading
        let top = NSStackView(views: [fields, linkButton])
        top.orientation = .horizontal; top.spacing = 8; top.alignment = .centerY

        let boxes = NSStackView(views: [reverseBox, pitchBox, rippleBox])
        boxes.orientation = .vertical; boxes.spacing = 6; boxes.alignment = .leading
        let all = NSStackView(views: [top, boxes])
        all.orientation = .vertical; all.spacing = 14; all.alignment = .leading
        all.frame = NSRect(x: 0, y: 0, width: 300, height: 150)
        all.setFrameSize(all.fittingSize)
        refresh()
        return all
    }

    private func refresh() {
        var s = String(format: "%.2f", model.percent)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        speedField.stringValue = s
        durationField.stringValue = timecode.format(model.duration)
        linkButton.state = model.isLinked ? .on : .off
        linkButton.image = NSImage(systemSymbolName: model.isLinked ? "link" : "link.badge.plus",
                                   accessibilityDescription: "Link")
        reverseBox.state = model.reversed ? .on : .off
        pitchBox.state = model.keepsPitch ? .on : .off
        rippleBox.state = model.ripple ? .on : .off
    }

    /// Reads whichever field is being edited into the model.
    private func commitEditing() {
        speedField.window?.makeFirstResponder(nil)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === speedField {
            let text = f.stringValue.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
            if let v = Double(text) { model.setPercent(v) }
        } else if f === durationField, let t = timecode.parse(f.stringValue) {
            model.setDuration(t)
        }
        refresh()
    }

    @objc private func linkToggled() { model.isLinked = linkButton.state == .on; refresh() }

    @objc private func optionsChanged() {
        model.reversed = reverseBox.state == .on
        model.keepsPitch = pitchBox.state == .on
        model.ripple = rippleBox.state == .on
    }
}
