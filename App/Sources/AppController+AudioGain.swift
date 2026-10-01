import AppKit
import SSCore
import SSEditorUI

extension AppController {
    /// G: the Audio Gain sheet for the selected audio clips (and the audio of selected linked video clips).
    func requestAudioGain() {
        let clips = session.audioGainTargets
        guard !clips.isEmpty else { shell.statusBar.flash("Select an audio clip first."); return }
        let items = clips.map { c in
            AudioGainPlan.Item(id: c.id, name: c.name, gainDB: c.audioGainDB,
                               peak: panels.waveforms.data[c.media].map { AudioGainPlan.peak(of: $0, source: c.source) })
        }
        AudioGainDialog.present(on: window, items: items) { [weak self] choice in
            guard let self, let choice else { return }
            let gains = AudioGainPlan.plan(choice, items: items)
            if gains.isEmpty { shell.statusBar.flash("The audio is silent or not analysed yet."); return }
            session.setAudioGain(gains)
        }
    }
}
