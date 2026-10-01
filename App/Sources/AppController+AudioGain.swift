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

/// Audio short-form tools: gain keys, Match Loudness, Auto Duck Music, Remove Silences, tags.
extension AppController {
    /// `[` / `]` (Shift = 6 dB).
    func nudgeAudioGain(_ db: Double) {
        if !session.nudgeAudioGain(byDB: db) { shell.statusBar.flash("Select an audio clip first.") }
    }

    func tagSelectedAudio(_ tag: AudioTag) {
        if !session.toggleAudioTag(tag) { shell.statusBar.flash("Select an audio clip first.") }
    }

    /// Pauses of a clip from its waveform; nil when the waveform has not been read yet.
    private func silences(of clip: Clip, thresholdDB: Double, minimum: Time) -> [TimeRange]? {
        let fader = session.activeTimeline?.tracks.first { $0.clips.contains { $0.id == clip.id } }?.volumeDB ?? 0
        return panels.waveforms.data[clip.media].map {
            AudioShortform.silences(of: clip, in: $0, trackVolumeDB: fader, thresholdDB: thresholdDB, minimumLength: minimum)
        }
    }

    func requestMatchLoudness() {
        let clips = session.selectedAudioClips
        guard !clips.isEmpty else { shell.statusBar.flash("Select an audio clip first."); return }
        shell.statusBar.flash("Measuring loudness...", seconds: 30)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let n = await session.matchLoudness()
            let targets = Set(clips.map { AudioGain.targetLUFS(for: $0) })
            let t = targets.count == 1 ? String(format: " to %g LUFS", targets.first!) : ""
            shell.statusBar.flash(n == 0 ? "The audio is silent: nothing to match." : "Matched \(n) clip(s)\(t).", seconds: 4)
        }
    }

    func requestAutoDuck() {
        guard !session.musicDuckTargets.isEmpty else {
            shell.statusBar.flash("Tag a clip as Music first (Clip > Audio Options).", seconds: 4); return
        }
        // Dialogue pauses of 0.6 s or more let the music come back up; without a waveform the whole clip counts.
        let n = session.autoDuckMusic(silences: { [weak self] c in
            self?.silences(of: c, thresholdDB: -35, minimum: Time(3, 5)) ?? []
        })
        shell.statusBar.flash(n == 0 ? "No dialogue found: tag a clip as Dialogue first." : "Music ducked under the dialogue.", seconds: 4)
    }

    func requestRemoveSilences() {
        let clips = session.selectedAudioClips
        guard let first = clips.first else { shell.statusBar.flash("Select an audio clip first."); return }
        guard clips.allSatisfy({ panels.waveforms.data[$0.media] != nil }) else {
            shell.statusBar.flash("The audio is not analysed yet. Try again in a moment."); return
        }
        func cuts(_ s: SilenceSettings) -> [TimeRange] {
            session.silenceCuts(for: clips, silences: { silences(of: $0, thresholdDB: s.thresholdDB, minimum: s.minimum) ?? [] }, padding: s.padding)
        }
        RemoveSilencesDialog.present(on: window, clipName: clips.count == 1 ? first.name : "\(clips.count) clips", initial: .remembered(),
                                     preview: { s in
            let c = cuts(s)
            return (c.count, c.reduce(Time.zero) { $0 + $1.duration })
        }) { [weak self] settings in
            guard let self, let settings else { return }
            settings.remember()
            let c = cuts(settings)
            guard !c.isEmpty else { shell.statusBar.flash("No pauses found."); return }
            if session.removeSilences(cuts: c, from: clips) {
                shell.statusBar.flash(SilenceSettings.previewText(count: c.count, removed: c.reduce(Time.zero) { $0 + $1.duration })
                    .replacingOccurrences(of: "will be removed", with: "removed"), seconds: 4)
            }
        }
    }
}
