import Foundation
import SQCore
import SQUIKit
import SQMedia
import SQEditorSession

/// The audio tools of the Clip menu that read decoded waveforms: Bake Live Duck to Keys (Auto Duck), Remove Silences and
/// Sync Audio to Reference. Translated from the Mac AppController+AudioGain (`requestAutoDuck`, `bakeLiveDuckToKeys`,
/// `requestRemoveSilences`, `silences(of:)`) and AppController+SyncAudio; the waveforms come from the host's cache through
/// `ShellHost.waveform` (Windows: FFmpeg peaks, Mac: `TimelineWaveforms`).
extension ShellHost {
    // MARK: Waveforms

    /// The linear sample peak of a clip's source range (Audio Gain): the host's own answer, else the waveform's.
    func peak(of clip: Clip) -> Double? {
        if let p = clipPeak?(clip) { return p }
        return waveform?(clip.media).map { AudioGainPlan.peak(of: $0, source: clip.source) }
    }

    /// Pauses of a clip from its waveform as heard through its track fader; nil when the waveform has not been read yet.
    func silences(of clip: Clip, thresholdDB: Double, minimum: Time) -> [TimeRange]? {
        guard let w = waveform?(clip.media) else { return nil }
        let fader = session.activeTimeline?.tracks.first { $0.clips.contains { $0.id == clip.id } }?.volumeDB ?? 0
        return AudioShortform.silences(of: clip, in: w, trackVolumeDB: fader, thresholdDB: thresholdDB, minimumLength: minimum)
    }

    /// The waveforms of `ids`, waiting for the host to read the missing ones (the Mac awaits `prepareDialogue`). Media that
    /// never arrive (no audio, unreadable) are left out once `timeout` passes.
    /// shortcut: polls the host cache in 100 ms steps instead of awaiting the build; upgrade when `waveform` gets an async
    /// build-or-wait form on both hosts.
    func waveforms(_ ids: [UUID], timeout: Double = 10) async -> [UUID: WaveformData] {
        var found: [UUID: WaveformData] = [:]
        let start = Date()
        while true {
            for id in ids where found[id] == nil { if let w = waveform?(id) { found[id] = w } }
            if found.count == ids.count || Date().timeIntervalSince(start) >= timeout || waveform == nil { return found }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Bake Live Duck to Keys

    /// Bake Live Duck to Keys. With live ducking on and keys from an earlier Auto Duck on a ducked track, says so first:
    /// remove the old keys (live ducking stays the one duck) or bake again (keys replace the old ones).
    func autoDuck() async {
        guard session.canBakeLiveDuck else { flash("Tag a clip as Music first (Clip > Audio Options)."); return }
        guard !session.clipsDuckingTwice.isEmpty else { await bakeLiveDuckToKeys(); return }
        let d = ShellDialog("Music Ducks Twice",
                            informative: "Live Ducking is on, and music clips still carry keys from an earlier Auto Duck, so they get quieter twice. "
                                + "Remove the keys and let Live Ducking do it, or bake again: the keys are replaced and those tracks leave Live Ducking.")
        d.addButton("Remove Keys")
        d.addButton("Cancel", role: .cancel)
        d.addButton("Bake Again")
        let r = await ask(d)
        if r == .first {
            let n = session.removeKeysDuckingTwice()
            onStatus?(SQL10n.plural(n, one: "Removed the duck keys from %@ clip. Live Ducking does the rest.",
                                    other: "Removed the duck keys from %@ clips. Live Ducking does the rest."))
        } else if r == .third {
            await bakeLiveDuckToKeys()
        }
    }

    /// The one bake behind Clip > Bake Live Duck to Keys: the dialogue waveforms first, so the bake hears the pauses as
    /// playback does (dialogue pauses of 0.6 s or more let the music come back up; a clip without a waveform ducks whole).
    public func bakeLiveDuckToKeys(live: LiveDucking? = nil) async {
        guard let timeline = session.activeTimeline else { return }
        let dialogue = Array(LiveDucking.dialogueMedia(in: timeline))
        if dialogue.contains(where: { waveform?($0) == nil }) { flash("Reading the dialogue…") }
        let pauses = ShellDialoguePauses(waveforms: await waveforms(dialogue))
        let clipSilences: (Clip) -> [TimeRange] = { [weak self] c in
            MainActor.assumeIsolated { self?.silences(of: c, thresholdDB: WaveformSilencesDefaults.thresholdDB, minimum: Time(3, 5)) ?? [] }
        }
        // Keys from an earlier bake that no longer match (dialogue edited since, or keys changed by hand) are replaced:
        // say so before they go.
        let changed = session.clipsWithChangedDuckKeys(live: live, silences: pauses, clipSilences: clipSilences).count
        if changed > 0 {
            let d = ShellDialog("Replace Duck Keys?",
                                informative: (changed == 1 ? "1 music clip has" : "\(changed) music clips have")
                                    + " duck keys that differ from what the dialogue gives now: the dialogue was edited since the last bake, or the keys were changed by hand. Baking again replaces them.")
            d.addButton("Bake Again")
            d.addButton("Cancel", role: .cancel)
            guard await ask(d) == .first else { return }
        }
        let r = session.bakeDuck(live: live, silences: pauses, clipSilences: clipSilences)
        flash(r.keysAdded > 0 ? "Duck baked into volume keys."
              : r.changed ? "The dialogue no longer reaches the music: old duck keys removed."
              : "No dialogue found: tag a clip as Dialogue first.")
    }

    // MARK: Remove Silences

    /// Remove Silences…: Level, Min. Length and Keep Each Side with a live count of what would be cut; Remove ripple-deletes
    /// the pauses on every sync-locked track (one undo step), Mark for Review leaves them as proposed cuts.
    func removeSilences(defaults: UserDefaults = .standard) async {
        let clips = session.selectedAudioClips
        guard let first = clips.first else { flash("Select an audio clip first."); return }
        guard clips.allSatisfy({ waveform?($0.media) != nil }) else { flash("The audio is not analyzed yet. Try again in a moment."); return }
        // The scan is kept per threshold and minimum, so a padding change only recomputes the cuts.
        var memo: (key: SilenceSettings, silences: [Clip.ID: [TimeRange]])?
        func cuts(_ s: SilenceSettings) -> [TimeRange] {
            let key = SilenceSettings(thresholdDB: s.thresholdDB, minimumMs: s.minimumMs, paddingMs: 0)
            if memo?.key != key {
                memo = (key, Dictionary(clips.map { ($0.id, silences(of: $0, thresholdDB: s.thresholdDB, minimum: s.minimum) ?? []) },
                                        uniquingKeysWith: { a, _ in a }))
            }
            let found = memo!.silences
            return session.silenceCuts(for: clips, silences: { found[$0.id] ?? [] }, padding: s.padding)
        }
        let initial = SilenceSettings.remembered(defaults)
        let d = ShellDialog("Remove Silences",
                            informative: (clips.count == 1 ? first.name : "\(clips.count) clips")
                                + "\nSilences are cut and the gaps closed on every sync-locked track, so picture, music and B-roll stay in sync.")
        let form = ShellForm(ShellSilenceForm.rows(initial))
        func settings() -> SilenceSettings { ShellSilenceForm.settings(form) }
        func refresh() {
            let c = cuts(settings())
            form.setNote(ShellSilenceForm.previewRow, SilenceSettings.previewText(count: c.count, removed: c.reduce(Time.zero) { $0 + $1.duration }), strong: true)
            relayout(d)
            silencePreview?(c)
        }
        form.onChange = { _, _ in refresh() }
        d.form = form
        refresh()
        d.addButton("Remove")
        d.addButton("Cancel", role: .cancel)
        d.addButton("Mark for Review")
        let r = await ask(d)
        silencePreview?([])
        guard r == .first || r == .third else { return }
        form.commitEditing()
        let s = settings()
        s.remember(defaults)
        let c = cuts(s)
        guard !c.isEmpty else { flash("No silences found."); return }
        if r == .third {
            if session.proposeCuts(c) {
                onStatus?(SQL10n.plural(c.count, one: "%@ proposed cut marked. Clip > Audio Options > Accept All Proposed Cuts, or reject.",
                                        other: "%@ proposed cuts marked. Clip > Audio Options > Accept All Proposed Cuts, or reject."))
            }
            return
        }
        if session.removeSilences(cuts: c, from: clips) {
            flash(SilenceSettings.previewText(count: c.count, removed: c.reduce(Time.zero) { $0 + $1.duration })
                .replacingOccurrences(of: "will be removed", with: "removed"))
        } else if let e = session.lastError { flash(e) }
    }

    // MARK: Sync Audio to Reference

    /// Sync Audio to Reference: start timecodes when both files carry one, else the sound envelopes, else the capture dates;
    /// each target moves (and retimes for drift) to the reference in its own undo step (the Mac `requestSyncAudio`).
    func syncAudio() async {
        guard let plan = session.syncAudioPlan else {
            presentMessage("Sync Audio to Reference", "Select at least two clips. The clip that starts first is the reference; the others are lined up to it.")
            return
        }
        func media(_ id: Clip.ID) -> MediaRef? {
            guard let c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return nil }
            return session.project.media(c.media)
        }
        guard let reference = media(plan.reference) else {
            presentMessage("Sync Audio to Reference", "The reference clip has no media file."); return
        }
        let targets: [(id: Clip.ID, media: MediaRef)] = plan.targets.compactMap { id in media(id).map { (id, $0) } }
        onStatus?(SQL10n.string("Lining up the audio…"))
        let shapes = await waveforms(Array(Set([reference.id] + targets.map(\.media.id))))
        let ref = await syncFacts(reference, waveform: shapes[reference.id])
        var fits: [(id: Clip.ID, fit: AudioDriftFit.Fit?)] = []
        for t in targets {
            let other = await syncFacts(t.media, waveform: shapes[t.media.id])
            let fit = await Task.detached(priority: .userInitiated) { ShellSyncFacts.fit(reference: ref, other: other) }.value
            fits.append((t.id, fit))
        }
        finishSyncAudio(reference: plan.reference, fits: fits)
    }

    /// The start timecode comes from the host's reader first (the Mac: AVFoundation), else from the portable one
    /// (SQMedia `SourceTimecode`: QuickTime/MP4 tmcd, Sony XAVC rtmd, BWF bext), so Windows syncs by timecode too.
    func syncFacts(_ m: MediaRef, waveform w: WaveformData?) async -> ShellSyncFacts {
        let created = (try? FileManager.default.attributesOfItem(atPath: m.path))?[.creationDate] as? Date
        var tc = await startTimecode?(m)
        if tc == nil {
            let url = URL(fileURLWithPath: m.path)
            tc = await Task.detached(priority: .userInitiated) { (try? SourceTimecode.read(from: url))??.origin }.value
        }
        return ShellSyncFacts(startTimecode: tc, envelope: w?.envelope() ?? [], captureDate: created)
    }

    func finishSyncAudio(reference: Clip.ID, fits: [(id: Clip.ID, fit: AudioDriftFit.Fit?)]) {
        var done = 0, unmatched = 0, byDate = 0
        var failure: String?
        for f in fits {
            guard let fit = f.fit else { unmatched += 1; continue }
            if session.syncAudio(f.id, to: reference, fit: fit, retime: true) {
                done += 1
                if fit.method == .captureDate { byDate += 1 }
            } else if failure == nil { failure = session.lastError }
        }
        if let failure {
            presentMessage("Sync Audio to Reference", failure)
        } else if done == 0 {
            presentMessage("Sync Audio to Reference", "The recordings could not be matched: no shared sound and no timecode or capture date.")
        } else {
            var tail = unmatched > 0 ? " " + SQL10n.format("%@ could not be matched.", String(unmatched)) : ""
            if let w = EditorSession.captureDateWarning(count: byDate) { tail += " " + w }
            onStatus?(SQL10n.plural(done, one: "Synced %@ clip to the reference.", other: "Synced %@ clips to the reference.") + tail)
        }
    }
}

/// The detection the live duck uses (`WaveformSilences`, SQPlayback): -35 dB, at least 0.6 s.
enum WaveformSilencesDefaults {
    static let thresholdDB = -35.0
}

/// Dialogue pauses for the bake from the waveforms read before it (`WaveformSilences.forExport` without SQPlayback): a clip
/// whose media has no waveform is unknown, so it ducks whole (fail safe, as on the Mac).
struct ShellDialoguePauses: DialogueSilenceProvider {
    let waveforms: [UUID: WaveformData]
    func silences(of clip: Clip, trackVolumeDB: Double) -> [TimeRange]? {
        waveforms[clip.media].map {
            AudioShortform.silences(of: clip, in: $0, trackVolumeDB: trackVolumeDB, thresholdDB: WaveformSilencesDefaults.thresholdDB,
                                    minimumLength: Time(3, 5))
        }
    }
}

/// What Sync Audio reads from one file.
public struct ShellSyncFacts: Sendable, Equatable {
    public var startTimecode: Time?
    public var envelope: [Float]
    public var captureDate: Date?
    public init(startTimecode: Time? = nil, envelope: [Float] = [], captureDate: Date? = nil) {
        self.startTimecode = startTimecode; self.envelope = envelope; self.captureDate = captureDate
    }

    /// The Mac `syncFit`: both files with a start timecode, the timecode difference; otherwise the sound fit; when the sound
    /// does not match, the capture dates (to the second).
    public static func fit(reference r: ShellSyncFacts, other o: ShellSyncFacts) -> AudioDriftFit.Fit? {
        if let a = r.startTimecode, let b = o.startTimecode { return AudioDriftFit.timecode(reference: a, other: b) }
        if !r.envelope.isEmpty, !o.envelope.isEmpty,
           let fit = AudioDriftFit.fit(reference: r.envelope, other: o.envelope, rate: WaveformData.envelopeRate) { return fit }
        guard let a = r.captureDate, let b = o.captureDate else { return nil }
        // shortcut: whole-second capture dates (file creation time), no sub-second placement and no camera metadata date;
        // upgrade when the probe reads the container's creation time.
        func s(_ d: Date) -> Time { Time(Int64(d.timeIntervalSince1970.rounded()), 1) }
        return AudioDriftFit.captureDate(reference: s(a), other: s(b))
    }
}

/// The Remove Silences form: the Mac `SilenceFieldsController` rows (Level, Min. Length, Keep Each Side, preview, hint).
@MainActor
enum ShellSilenceForm {
    static let previewRow = 3

    static func rows(_ s: SilenceSettings) -> [ShellForm.Row] {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        return [
            // `NumericSlider` rows as the Mac dialog draws them: slider, accent value, unit column.
            .sliderNumber(label: "Level", .init(id: "level", value: clamp(s.thresholdDB, SilenceSettings.thresholdRange), range: SilenceSettings.thresholdRange,
                                                step: 1, unit: "dB", defaultValue: SilenceSettings.standard.thresholdDB)),
            .sliderNumber(label: "Min. Length", .init(id: "minimum", value: clamp(Double(s.minimumMs), SilenceSettings.minimumRange), range: SilenceSettings.minimumRange,
                                                      step: 10, unit: "ms", defaultValue: Double(SilenceSettings.standard.minimumMs))),
            .sliderNumber(label: "Keep Each Side", .init(id: "padding", value: clamp(Double(s.paddingMs), SilenceSettings.paddingRange), range: SilenceSettings.paddingRange,
                                                         step: 5, unit: "ms", defaultValue: Double(SilenceSettings.standard.paddingMs))),
            .text(""),
            .text("Red ranges on the timeline will be cut. “Mark for Review” leaves them as proposed cuts to accept or reject."),
        ]
    }

    static func settings(_ f: ShellForm) -> SilenceSettings {
        let std = SilenceSettings.standard
        return SilenceSettings.snapped(thresholdDB: f.number("level") ?? std.thresholdDB, minimumMs: f.number("minimum") ?? Double(std.minimumMs),
                                       paddingMs: f.number("padding") ?? Double(std.paddingMs))
    }
}
