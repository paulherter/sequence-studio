import AppKit
import SQCore

/// Sheet for one audio track's fader and pan (the "mixer-lite": Premiere has a full Audio Track Mixer, this is the
/// two controls that matter for short-form work). Applies when OK is pressed.
@MainActor
public enum TrackMixDialog {
    /// The accessory view alone, so a test can render it.
    public static func makeView(volumeDB: Double, pan: Double) -> (view: NSView, volume: NSSlider, pan: NSSlider) {
        let volume = NSSlider(value: volumeDB, minValue: TrackPan.minVolumeDB, maxValue: TrackPan.maxVolumeDB, target: nil, action: nil)
        let panSlider = NSSlider(value: pan * 100, minValue: -100, maxValue: 100, target: nil, action: nil)
        let volumeLabel = NSTextField(labelWithString: ""), panLabel = NSTextField(labelWithString: "")
        for l in [volumeLabel, panLabel] {
            l.alignment = .right; l.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            l.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        for s in [volume, panSlider] { s.widthAnchor.constraint(equalToConstant: 170).isActive = true; s.isContinuous = true }
        let live = TrackMixLive(volume, panSlider, volumeLabel, panLabel)
        for s in [volume, panSlider] { s.target = live; s.action = #selector(TrackMixLive.update(_:)) }
        objc_setAssociatedObject(volume, &liveKey, live, .OBJC_ASSOCIATION_RETAIN)
        live.update(nil)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Volume"), volume, volumeLabel],
            [NSTextField(labelWithString: "Pan"), panSlider, panLabel],
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 330, height: 56)
        return (grid, volume, panSlider)
    }

    nonisolated public static func text(volumeDB: Double) -> String {
        volumeDB <= TrackPan.minVolumeDB ? "-inf dB" : String(format: "%+.1f dB", volumeDB)
    }

    nonisolated public static func text(pan: Double) -> String {
        let p = Int(pan.rounded())
        return p == 0 ? "Center" : (p < 0 ? "L \(-p)" : "R \(p)")
    }

    public static func present(on window: NSWindow, trackName: String, volumeDB: Double, pan: Double,
                               completion: @escaping @MainActor (_ volumeDB: Double, _ pan: Double) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Track Volume and Pan"
        alert.informativeText = trackName
        let v = makeView(volumeDB: volumeDB, pan: pan)
        alert.accessoryView = v.view
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                completion(v.volume.doubleValue, v.pan.doubleValue / 100)
            }
        }
    }
}

nonisolated(unsafe) private var liveKey: UInt8 = 0

/// Keeps the two labels in step with the sliders.
@MainActor
private final class TrackMixLive: NSObject {
    let volume: NSSlider, pan: NSSlider, volumeLabel: NSTextField, panLabel: NSTextField
    init(_ v: NSSlider, _ p: NSSlider, _ vl: NSTextField, _ pl: NSTextField) { volume = v; pan = p; volumeLabel = vl; panLabel = pl }
    @objc func update(_ sender: Any?) {
        // A small dead zone at the centre and at unity, like a mixer detent.
        if abs(pan.doubleValue) < 3 { pan.doubleValue = 0 }
        if abs(volume.doubleValue) < 0.5 { volume.doubleValue = 0 }
        volumeLabel.stringValue = TrackMixDialog.text(volumeDB: volume.doubleValue)
        panLabel.stringValue = TrackMixDialog.text(pan: pan.doubleValue)
    }
}
