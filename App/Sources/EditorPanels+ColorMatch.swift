import AppKit
import SQCore
import SQEditorUI

/// FB-B3 Color Match: the Effect Controls Match row asks, the Program frame at the playhead is sampled here.
extension EditorPanels {
    func wireColorMatch() {
        effectModel.colorSourceOf = { [weak self] clip in
            self?.session.colorSource(of: clip) ?? clip.color.source ?? .rec709
        }
        effectModel.onColorMatch = { [weak self] effect, request in
            guard let self else { return }
            switch request {
            case .setReference: self.setColorMatchReference(effect)
            case .match: self.applyColorMatch(effect)
            }
        }
    }

    private func setColorMatchReference(_ effect: ClipEffect.ID) {
        let model = effectModel
        let at = session.playhead
        let shot = topVideoClip(at: at)
        let fd = session.activeTimeline?.frameDuration ?? Time(1, 30)
        let tc = TimecodeFormat(frameDuration: fd).string(for: at, frameDuration: fd)
        FrameSampler.sampleScaled(engine: session.engine, width: 96, key: "color.match.reference") { r in
            guard let r, let stats = ColorMatchStats.measure(FrameSampler.displayRGB(r.linear)) else { NSSound.beep(); return }
            let ref = ColorMatchReference(clip: shot?.id, time: at, label: "\(shot?.name ?? "Frame") \(tc)", stats: stats)
            model.setColorMatchReference(effect, ref)
        }
    }

    private func applyColorMatch(_ effect: ClipEffect.ID) {
        let model = effectModel
        if let reason = model.colorMatchBlock(effect) { onStatus?(reason); NSSound.beep(); return }
        FrameSampler.sampleScaled(engine: session.engine, width: 96, key: "color.match") { [weak self] r in
            guard let self, let r else { NSSound.beep(); return }
            if !model.applyColorMatch(effect, display: FrameSampler.displayRGB(r.linear)) {
                self.onStatus?("The clip already matches the reference.")
            }
        }
    }

    /// The clip shown on top at `t` (highest video track with a clip there).
    private func topVideoClip(at t: Time) -> Clip? {
        guard let tl = session.activeTimeline else { return nil }
        for track in tl.tracks.reversed() where track.kind == .video {
            if let c = track.clips.first(where: { $0.timeline.contains(t) }) { return c }
        }
        return nil
    }
}
