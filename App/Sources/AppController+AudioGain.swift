import AppKit
import SQCore
import SQEditorUI
import SQMedia

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
        // The loudness is measured while the sheet is open (decoding the source range, like Match Loudness).
        let measure: (Clip.ID) async -> Double? = { [weak self] id in
            guard let self, let c = clips.first(where: { $0.id == id }) else { return nil }
            return await session.measureLoudness(of: c)
        }
        let target = session.activeTimeline.map { AudioGain.targetLUFS(for: clips, in: $0) } ?? AudioTag.dialogue.targetLUFS
        AudioGainDialog.present(on: window, items: items, loudnessTarget: target, measureLoudness: measure) { [weak self] choice, items in
            guard let self, let choice else { return }
            let gains = AudioGainPlan.plan(choice, items: items)
            if gains.isEmpty { shell.statusBar.flash("The audio is silent or not analyzed yet."); return }
            session.setAudioGain(gains)
            if gains.count < items.count {
                shell.statusBar.flash(SQL10n.plural(items.count - gains.count, one: "%@ clip was skipped: silent or not analyzed yet.", other: "%@ clips were skipped: silent or not analyzed yet."))
            }
            let clipping = AudioGainPlan.clippingClips(choice, items: items).count
            if clipping > 0 { shell.statusBar.flash(SQL10n.plural(clipping, one: "%@ clip now peaks above 0 dB.", other: "%@ clips now peak above 0 dB."), seconds: 5) }
        }
    }

    /// Audio scrubbing on or off; remembered between launches.
    func toggleAudioScrubbing() {
        let on = !session.engine.audioScrubbing
        session.engine.audioScrubbing = on
        settings.audioScrubbing = on
        settings.save()
        shell.statusBar.flash(on ? "Audio scrubbing on" : "Audio scrubbing off", seconds: 2)
    }

    /// Selection follows playhead on or off; remembered between launches (`sq.selectionFollowsPlayhead`).
    func toggleSelectionFollowsPlayhead() {
        let on = !session.selectionFollowsPlayhead
        session.setSelectionFollowsPlayhead(on)
        settings.selectionFollowsPlayhead = on
        settings.save()
        shell.statusBar.flash(on ? "Selection follows playhead on" : "Selection follows playhead off", seconds: 2)
    }

    /// Applies the remembered setting (AppSettings.audioScrubbing, default off).
    func restoreAudioScrubbing() {
        session.engine.audioScrubbing = settings.audioScrubbing
        session.setSelectionFollowsPlayhead(settings.selectionFollowsPlayhead)
        session.newSequenceEditMode = settings.newSequenceEditMode
    }
}

/// Audio short-form tools: gain keys, Match Loudness, Bake Live Duck to Keys, Remove Silences, tags.
extension AppController {
    /// `[` / `]` (Shift = 6 dB).
    func nudgeAudioGain(_ db: Double) {
        if let report = session.nudgeAudioGainReport(byDB: db) { shell.statusBar.flash(report) }
        else { shell.statusBar.flash("Select an audio clip first.") }
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

    /// Returns the measuring task (nil when nothing is selected) so a palette macro can wait for it.
    @discardableResult
    func requestMatchLoudness() -> Task<Void, Never>? {
        let clips = session.selectedAudioClips
        guard !clips.isEmpty else { shell.statusBar.flash("Select an audio clip first."); return nil }
        shell.statusBar.flash("Measuring loudness...", seconds: 30)
        let targets = session.activeTimeline.map { t in Set(clips.map { AudioGain.targetLUFS(for: $0, in: t) }) } ?? []
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let n = await session.matchLoudness()
            let t = targets.count == 1 ? SQL10n.format(" to %@ LUFS", String(format: "%g", targets.first!)) : ""
            shell.statusBar.flash(n == 0 ? "The audio is silent: nothing to match." : SQL10n.plural(n, one: "Matched %@ clip", other: "Matched %@ clips") + t + ".", seconds: 4)
        }
    }

    /// Bake Live Duck to Keys. With live ducking on and keys from an earlier Auto Duck on a ducked track, says so first: remove
    /// the old keys (live ducking stays the one duck) or bake again (keys replace the old ones, the track leaves live ducking).
    func requestAutoDuck() {
        guard session.canBakeLiveDuck else {
            shell.statusBar.flash("Tag a clip as Music first (Clip > Audio Options).", seconds: 4); return
        }
        guard !session.clipsDuckingTwice.isEmpty else { bakeLiveDuckToKeys(); return }
        let alert = SQDialog()
        alert.messageText = "Music Ducks Twice"
        alert.informativeText = "Live Ducking is on, and music clips still carry keys from an earlier Auto Duck, so they get quieter twice. "
            + "Remove the keys and let Live Ducking do it, or bake again: the keys are replaced and those tracks leave Live Ducking."
        alert.addButton("Remove Keys")
        alert.addButton("Cancel")
        alert.addButton("Bake Again")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .first {
                    let n = self.session.removeKeysDuckingTwice()
                    self.shell.statusBar.flash(SQL10n.plural(n, one: "Removed the duck keys from %@ clip. Live Ducking does the rest.", other: "Removed the duck keys from %@ clips. Live Ducking does the rest."), seconds: 4)
                } else if response == .third { self.bakeLiveDuckToKeys() }
            }
        }
    }

    /// The one bake behind Clip > Bake Live Duck to Keys and the Live Ducking dialog's Bake button. `live`: the setting to
    /// bake (the dialog's choice), default the project's effective setting.
    func bakeLiveDuckToKeys(live: LiveDucking? = nil) {
        guard let timeline = session.activeTimeline else { return }
        // The dialogue waveforms first (built or awaited), so the bake hears the pauses as playback does. Dialogue pauses of
        // 0.6 s or more let the music come back up; a tagged clip without a waveform counts whole.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pauses = await panels.waveforms.prepareDialogue(of: timeline, project: session.project)
            let clipSilences: (Clip) -> [TimeRange] = { [weak self] c in
                self?.silences(of: c, thresholdDB: -35, minimum: Time(3, 5)) ?? []
            }
            let doBake = { [weak self] in
                guard let self else { return }
                let r = session.bakeDuck(live: live, silences: pauses, clipSilences: clipSilences)
                shell.statusBar.flash(r.keysAdded > 0 ? "Duck baked into volume keys."
                                      : r.changed ? "The dialogue no longer reaches the music: old duck keys removed."
                                      : "No dialogue found: tag a clip as Dialogue first.", seconds: 4)
            }
            // Keys from an earlier bake that no longer match (dialogue edited since, or keys changed by hand) are replaced:
            // say so before they go.
            let changed = session.clipsWithChangedDuckKeys(live: live, silences: pauses, clipSilences: clipSilences).count
            guard changed > 0 else { doBake(); return }
            let alert = SQDialog()
            alert.messageText = "Replace Duck Keys?"
            alert.informativeText = (changed == 1 ? "1 music clip has" : "\(changed) music clips have")
                + " duck keys that differ from what the dialogue gives now: the dialogue was edited since the last bake, or the keys were changed by hand. Baking again replaces them."
            alert.addButton("Bake Again")
            alert.addButton("Cancel")
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { if response == .first { doBake() } }
            }
        }
    }

    /// Markers on Beat / Markers on Downbeats: decodes and tracks the beat of the selected audio clips (else the Music clips)
    /// off the main actor, then writes the "Beat" markers as one undo step.
    func requestMarkersOnBeat(downbeatsOnly: Bool) {
        guard !session.beatAnalysisTargets.isEmpty else {
            shell.statusBar.flash("Select an audio clip or tag one as Music first (Clip > Audio Options).", seconds: 4); return
        }
        shell.statusBar.flash("Finding the beat...", seconds: 30)
        let project = session.project
        Task { @MainActor [weak self] in
            guard let self else { return }
            let grids = await session.beatGrids { clip in project.media(clip.media).map { URL(fileURLWithPath: $0.path) } }
            let n = session.addMarkersOnBeat(grids: grids, downbeatsOnly: downbeatsOnly)
            shell.statusBar.flash(n == 0 ? "No beat found." : SQL10n.plural(n, one: downbeatsOnly ? "Added %@ downbeat marker." : "Added %@ beat marker.", other: downbeatsOnly ? "Added %@ downbeat markers." : "Added %@ beat markers."), seconds: 4)
        }
    }

    func requestProposedCuts(_ command: EditorCommand) {
        let ok: Bool
        switch command {
        case .reviewProposedCuts:
            guard let cuts = session.activeTimeline?.proposedCuts, !cuts.isEmpty else { shell.statusBar.flash("No proposed cuts."); return }
            ProposedCutsReviewDialog.present(on: window, cuts: cuts) { [weak self] result in
                guard let self, let result else { return }
                switch result {
                case .accept(let ids): session.reviewProposedCuts(accepted: ids)
                case .rejectAll: session.rejectProposedCuts(nil)
                }
            }
            return
        case .acceptProposedCuts: ok = session.acceptProposedCuts(nil)
        case .rejectProposedCuts: ok = session.rejectProposedCuts(nil)
        case .acceptProposedCutAtPlayhead: ok = session.proposedCutAtPlayhead().map { session.acceptProposedCuts([$0]) } ?? false
        default: ok = session.proposedCutAtPlayhead().map { session.rejectProposedCuts([$0]) } ?? false
        }
        if !ok { shell.statusBar.flash("No proposed cuts.") }
    }

    /// Voice chain on or off for the tracks of the selected audio clips.
    func requestVoiceChain() {
        let wasActive = session.voiceChainActive
        guard session.toggleVoiceChain() else { shell.statusBar.flash("Select an audio clip first."); return }
        shell.statusBar.flash(wasActive ? "Voice chain removed." : "Voice chain on: EQ, compressor, noise reduction.", seconds: 4)
        guard !wasActive else { return }
        Task { @MainActor [weak self] in
            guard let self, let r = await session.voiceChainReadout() else { return }
            let target = String(format: "%g", r.targetLUFS), off = String(format: "%.1f", abs(r.deltaLU))
            let text: String = switch r.status {
            case .onTarget: SQL10n.format("Voice chain on. Loudness %@ LUFS, on the %@ LUFS target.", r.lufsText, target)
            case .quiet: SQL10n.format("Voice chain on. Loudness %@ LUFS, %@ LU under the %@ LUFS target (Match Loudness fixes it).", r.lufsText, off, target)
            case .loud: SQL10n.format("Voice chain on. Loudness %@ LUFS, %@ LU over the %@ LUFS target (Match Loudness fixes it).", r.lufsText, off, target)
            }
            shell.statusBar.flash(text, seconds: 6)
        }
    }

    func requestRemoveSilences() {
        let clips = session.selectedAudioClips
        guard let first = clips.first else { shell.statusBar.flash("Select an audio clip first."); return }
        guard clips.allSatisfy({ panels.waveforms.data[$0.media] != nil }) else {
            shell.statusBar.flash("The audio is not analyzed yet. Try again in a moment."); return
        }
        // Slider ticks only rescan the already-analyzed waveform peaks (no audio decoding); the scan is kept per
        // threshold and minimum so dragging the padding slider only recomputes the cuts.
        var memo: (key: SilenceSettings, silences: [Clip.ID: [TimeRange]])?
        func cuts(_ s: SilenceSettings) -> [TimeRange] {
            let key = SilenceSettings(thresholdDB: s.thresholdDB, minimumMs: s.minimumMs, paddingMs: 0)
            if memo?.key != key {
                memo = (key, Dictionary(uniqueKeysWithValues: clips.map {
                    ($0.id, silences(of: $0, thresholdDB: s.thresholdDB, minimum: s.minimum) ?? [])
                }))
            }
            let found = memo!.silences
            return session.silenceCuts(for: clips, silences: { found[$0.id] ?? [] }, padding: s.padding)
        }
        RemoveSilencesDialog.present(on: window, clipName: clips.count == 1 ? first.name : "\(clips.count) clips", initial: .remembered(),
                                     preview: { [weak self] s in
            let c = cuts(s)
            self?.panels.timelineView.silencePreview = c        // red ranges on the timeline while the sheet is open
            return (c.count, c.reduce(Time.zero) { $0 + $1.duration })
        }) { [weak self] settings, propose in
            guard let self else { return }
            panels.timelineView.silencePreview = []
            guard let settings else { return }
            settings.remember()
            let c = cuts(settings)
            guard !c.isEmpty else { shell.statusBar.flash("No silences found."); return }
            if propose {
                if session.proposeCuts(c) {
                    shell.statusBar.flash(SQL10n.plural(c.count, one: "%@ proposed cut marked. Clip > Audio Options > Accept All Proposed Cuts, or reject.", other: "%@ proposed cuts marked. Clip > Audio Options > Accept All Proposed Cuts, or reject."), seconds: 5)
                }
                return
            }
            if session.removeSilences(cuts: c, from: clips) {
                shell.statusBar.flash(SilenceSettings.previewText(count: c.count, removed: c.reduce(Time.zero) { $0 + $1.duration })
                    .replacingOccurrences(of: "will be removed", with: "removed"), seconds: 4)
            }
        }
    }
}
