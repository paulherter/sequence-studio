import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// G: the Audio Gain sheet for the selected audio clips (and the audio of selected linked video clips).
    func requestAudioGain() {
        let clips = session.audioGainTargets
        guard !clips.isEmpty else { shell.statusBar.flash("Select an audio clip first."); return }
        let items = clips.map { c in
            AudioGainPlan.Item(id: c.id, name: c.name, gainDB: c.audioGainDB,
                               peak: panels.waveforms.data[c.media].map { AudioGainPlan.peak(of: $0, source: c.source) },
                               volume: AudioGainPlan.volumePeak(of: c))
        }
        AudioGainDialog.present(on: window, items: items) { [weak self] choice in
            guard let self, let choice else { return }
            let gains = AudioGainPlan.plan(choice, items: items)
            if gains.isEmpty { shell.statusBar.flash("The audio is silent or not analysed yet."); return }
            session.setAudioGain(gains)
            if gains.count < items.count {
                shell.statusBar.flash("\(items.count - gains.count) clip(s) were skipped: silent or not analysed yet.")
            }
        }
    }

    /// Audio scrubbing on or off; remembered between launches.
    func toggleAudioScrubbing() {
        let on = !session.engine.audioScrubbing
        session.engine.audioScrubbing = on
        UserDefaults.standard.set(on, forKey: "sq.audioScrubbing")
        shell.statusBar.flash(on ? "Audio scrubbing on" : "Audio scrubbing off", seconds: 2)
    }

    /// Restores the remembered setting (default on).
    func restoreAudioScrubbing() {
        if let v = UserDefaults.standard.object(forKey: "sq.audioScrubbing") as? Bool { session.engine.audioScrubbing = v }
    }
}
