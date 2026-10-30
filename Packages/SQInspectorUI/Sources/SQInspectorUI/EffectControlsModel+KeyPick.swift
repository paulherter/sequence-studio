import AppKit
import SQCore
import SQMonitorUI

/// Color Key eyedropper: the next click on the Program monitor samples the rendered frame (5 x 5 mean, like the white
/// balance picker) and sets Key Hue to that color's hue (one undo step, `setValue`).
extension EffectControlsModel {
    /// shortcut: samples the composite as shown, so an already active key makes its own keyed pixels transparent; set
    /// Output to Source (or pick before keying) for the true screen color. Upgrade with a pre-key readback if needed.
    func pickKeyColor(_ p: EffectProperty) {
        guard Self.isKeyHue(p), let session = speedSession else { NSSound.beep(); return }
        let engine = session.engine
        let hover: ColorPickHub.HoverSampler = { pos, done in FrameSampler.sampleGrid(engine: engine, at: pos, done) }
        ColorPickHub.shared.begin(hoverSampler: hover) { [weak self] pos in
            guard let pos else { return }
            FrameSampler.sampleColor(engine: engine, at: pos) { [weak self] rgb in
                guard let self else { return }
                guard let rgb else { self.onNotice?(Self.keyPickGrayNotice); return }
                self.applyKeyColor(p, linear: rgb)
            }
        }
    }
}
