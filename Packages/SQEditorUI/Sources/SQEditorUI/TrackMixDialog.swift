import AppKit
import SQCore
import SQMonitorUI   // re-exports SQDrawKit (TrackMixText)

/// Sheet for one audio track's fader and pan (the "mixer-lite": Premiere has a full Audio Track Mixer, this is the
/// two controls that matter for short-form work). Applies when OK is pressed.
@MainActor
public enum TrackMixDialog {
    /// The accessory view alone, so a test can render it. Double-click on either control resets it (0 dB, center).
    public static func makeView(volumeDB: Double, pan: Double) -> (view: NSView, volume: NumericSlider, pan: NumericSlider) {
        let volume = volumeSlider(volumeDB)
        let panSlider = NumericSlider(value: pan * 100, range: -100...100, defaultValue: 0, step: 1)
        panSlider.field.valueFormatter = { text(pan: $0) }
        panSlider.field.valueParser = { parse(pan: $0) }
        style(panSlider)
        let grid = SQDialogForm(rows: [SQDialog.formRow("Volume", volume), SQDialog.formRow("Pan", panSlider)])
        return (grid, volume, panSlider)
    }

    // The text and parse rules live in the portable `TrackMixText` (SQDrawKit), shared with the Windows app.
    nonisolated public static func parse(volumeDB text: String) -> Double? { TrackMixText.parse(volumeDB: text) }
    nonisolated public static func parse(pan text: String) -> Double? { TrackMixText.parse(pan: text) }
    nonisolated public static func text(volumeDB: Double) -> String { TrackMixText.text(volumeDB: volumeDB) }
    nonisolated public static func capsuleText(volumeDB: Double) -> String { TrackMixText.capsuleText(volumeDB: volumeDB) }
    nonisolated public static func text(pan: Double) -> String { TrackMixText.text(pan: pan) }

    /// Fader-range level slider (dB text, "-inf" at the floor); double-click resets to 0 dB.
    private static func volumeSlider(_ volumeDB: Double) -> NumericSlider {
        let volume = NumericSlider(value: volumeDB, range: TrackPan.minVolumeDB...TrackPan.maxVolumeDB, defaultValue: 0,
                                   step: 0.1, decimals: 1, unit: "dB")
        volume.field.valueFormatter = { capsuleText(volumeDB: $0) }
        volume.field.valueParser = { parse(volumeDB: $0) }
        style(volume)
        return volume
    }

    private static func style(_ s: NumericSlider) {
        s.fieldWidth = 72
        s.gap = 12
        s.field.leadingText = true
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// The Sequence Volume form alone (one level row, same fader range and text as a track), so a test can render it.
    public static func makeSequenceVolumeView(volumeDB: Double) -> (view: NSView, volume: NumericSlider) {
        let volume = volumeSlider(volumeDB)
        return (SQDialogForm(rows: [SQDialog.formRow("Volume", volume)]), volume)
    }

    /// Sheet for the level of the whole sequence: applied after every track and before the delivery limiter. OK applies.
    /// "Keyframe at playhead" (v86): ticked, OK sets a level key at the playhead instead of the constant level; a keyed
    /// sequence opens it ticked, and unticking it makes `volumeDB` the constant level again (the keys go).
    public static func presentSequenceVolume(on window: NSWindow, sequenceName: String, volumeDB: Double, keyed: Bool = false,
                                             completion: @escaping @MainActor (_ volumeDB: Double, _ animate: Bool) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Sequence Volume"
        alert.informativeText = sequenceName.isEmpty ? "Every track of this sequence" : "Every track of \(sequenceName)"
        alert.width = SQModal.Size.xs.width
        let v = makeSequenceVolumeView(volumeDB: volumeDB)
        let animate = SQCheckbox(title: "Keyframe at Playhead", target: nil, action: nil)
        animate.state = keyed ? .on : .off
        alert.accessoryView = SQDialogForm(rows: [SQDialog.formRow("Volume", v.volume), SQDialog.checkRow(animate)])
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { return }
                completion(v.volume.value, animate.state == .on)
            }
        }
    }

    public static func present(on window: NSWindow, trackName: String, volumeDB: Double, pan: Double,
                               completion: @escaping @MainActor (_ volumeDB: Double, _ pan: Double) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Track Volume and Pan"
        alert.informativeText = trackName
        alert.width = SQModal.Size.xs.width
        let v = makeView(volumeDB: volumeDB, pan: pan)
        alert.accessoryView = v.view
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { return }
                completion(v.volume.value, v.pan.value / 100)
            }
        }
    }
}
