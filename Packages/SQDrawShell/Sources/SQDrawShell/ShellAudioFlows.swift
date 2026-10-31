import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// The audio commands of the Clip and Sequence menus that the Mac AppController runs in `AppController+AudioGain`,
/// `+Voiceover`, `+VoiceRecording` and `+Speed`: Voice Chain, Markers on Beat / Downbeats, the proposed-cut commands and
/// their review sheet, Fit Music to Length, Voiceover from Text and Record Voice-Over. Same session calls and messages;
/// the dialogs are shell dialogs. Remove Filler Words and Disguise Voice need the Text panel's transcript and live in
/// `CaptionsHost` (registered through `commandHandlers`).

/// The text-to-speech engine of a platform (the Mac: `SpeechRenderer`). nil on a shell without one: Voiceover says so.
public struct ShellVoiceoverBackend {
    public var voices: @MainActor () -> [(id: String, title: String)]
    /// Speaks `text` into the file at `url`; returns its length. Throws `ShellVoiceoverError.noAudio` for a silent voice.
    public var render: @MainActor (_ text: String, _ voiceID: String, _ rate: Double, _ url: URL) async throws -> Time
    public init(voices: @escaping @MainActor () -> [(id: String, title: String)],
                render: @escaping @MainActor (String, String, Double, URL) async throws -> Time) {
        self.voices = voices; self.render = render
    }
}

public enum ShellVoiceoverError: Error, Equatable { case noAudio }

extension ShellHost {
    // MARK: Command table

    /// Runs the audio command `c` when this file owns it; false otherwise.
    func performAudioFlowCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .voiceChain: voiceChain()
        case .addBeatMarkers: spawn { await self.markersOnBeat(downbeatsOnly: false) }
        case .addMarkersOnDownbeats: spawn { await self.markersOnBeat(downbeatsOnly: true) }
        case .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead:
            spawn { await self.proposedCuts(c) }
        case .fitMusicToLength: spawn { await self.fitMusic() }
        case .voiceover: spawn { await self.voiceoverFromText() }
        case .recordVoiceOver: recordVoiceOver()
        default: return false
        }
        return true
    }

    // MARK: Voice chain

    /// Voice chain on or off for the tracks of the selected audio clips; says the loudness once it is on.
    func voiceChain() {
        let wasActive = session.voiceChainActive
        guard session.toggleVoiceChain() else { flash("Select an audio clip first."); return }
        flash(wasActive ? "Voice chain removed." : "Voice chain on: EQ, compressor, noise reduction.")
        guard !wasActive else { return }
        spawn { [weak self] in
            guard let self, let r = await self.session.voiceChainReadout() else { return }
            self.flash(Self.voiceChainText(r))
        }
    }

    static func voiceChainText(_ r: VoiceChainReadout) -> String {
        let target = String(format: "%g", r.targetLUFS), off = String(format: "%.1f", abs(r.deltaLU))
        switch r.status {
        case .onTarget: return SQL10n.format("Voice chain on. Loudness %@ LUFS, on the %@ LUFS target.", r.lufsText, target)
        case .quiet: return SQL10n.format("Voice chain on. Loudness %@ LUFS, %@ LU under the %@ LUFS target (Match Loudness fixes it).", r.lufsText, off, target)
        case .loud: return SQL10n.format("Voice chain on. Loudness %@ LUFS, %@ LU over the %@ LUFS target (Match Loudness fixes it).", r.lufsText, off, target)
        }
    }

    // MARK: Markers on Beat

    /// Decodes and tracks the beat of the selected audio clips (else the Music clips), then writes the "Beat" markers as one
    /// undo step.
    func markersOnBeat(downbeatsOnly: Bool) async {
        guard !session.beatAnalysisTargets.isEmpty else {
            flash("Select an audio clip or tag one as Music first (Clip > Audio Options)."); return
        }
        flash("Finding the beat...")
        let project = session.project
        let grids = await session.beatGrids { clip in project.media(clip.media).map { URL(fileURLWithPath: $0.path) } }
        let n = session.addMarkersOnBeat(grids: grids, downbeatsOnly: downbeatsOnly)
        flash(n == 0 ? "No beat found."
              : SQL10n.plural(n, one: downbeatsOnly ? "Added %@ downbeat marker." : "Added %@ beat marker.",
                              other: downbeatsOnly ? "Added %@ downbeat markers." : "Added %@ beat markers."))
    }

    // MARK: Proposed cuts

    func proposedCuts(_ command: EditorCommand) async {
        let ok: Bool
        switch command {
        case .reviewProposedCuts:
            guard let cuts = session.activeTimeline?.proposedCuts, !cuts.isEmpty else { flash("No proposed cuts."); return }
            await reviewProposedCuts(cuts)
            return
        case .acceptProposedCuts: ok = session.acceptProposedCuts(nil)
        case .rejectProposedCuts: ok = session.rejectProposedCuts(nil)
        case .acceptProposedCutAtPlayhead: ok = session.proposedCutAtPlayhead().map { session.acceptProposedCuts([$0]) } ?? false
        default: ok = session.proposedCutAtPlayhead().map { session.rejectProposedCuts([$0]) } ?? false
        }
        if !ok { flash("No proposed cuts.") }
    }

    /// The form of the review sheet: one check row per cut (all on) and the summary line under them.
    static func reviewForm(_ cuts: [Timeline.ProposedCut]) -> ShellForm {
        let form = ShellForm(cuts.enumerated().map { .check(id: "cut\($0.offset)", title: $0.element.rowTitle, on: true) } + [.text(" ")])
        func again() {
            let on = cuts.enumerated().filter { form.bool("cut\($0.offset)") ?? true }.map(\.element)
            form.setNote(cuts.count, Timeline.ProposedCut.reviewSummary(count: cuts.count, checked: on.count,
                                                                       removed: on.reduce(Time.zero) { $0 + $1.range.duration }), strong: true)
        }
        form.onChange = { _, _ in again() }
        again()
        return form
    }

    /// The ids checked in `reviewForm`.
    static func checkedCuts(_ form: ShellForm, _ cuts: [Timeline.ProposedCut]) -> Set<Marker.ID> {
        Set(cuts.enumerated().filter { form.bool("cut\($0.offset)") ?? true }.map(\.element.id))
    }

    /// Remove Silences' review step: Remove Checked cuts the checked ones and drops the rest, Reject All drops every
    /// proposal, Cancel leaves the markers as they are.
    func reviewProposedCuts(_ cuts: [Timeline.ProposedCut]) async {
        let d = ShellDialog("Review Silences", informative: "Uncheck the pauses you want to keep. Checked ones are cut and the gaps closed.")
        let form = Self.reviewForm(cuts)
        d.form = form
        d.addButton("Remove Checked")
        d.addButton("Cancel", role: .cancel)
        d.addButton("Reject All", leading: true)
        switch await ask(d) {
        case .first: session.reviewProposedCuts(accepted: Self.checkedCuts(form, cuts))
        case .third: _ = session.rejectProposedCuts(nil)
        default: break
        }
    }

    // MARK: Fit Music to Length

    /// Finds the beat of the selected music clip and offers up to three versions; picking one applies it.
    func fitMusic() async {
        guard let clip = session.musicFitClip else { flash("Select one music clip at normal speed first."); return }
        guard let target = session.musicFitTarget(for: clip) else {
            flash("Mark In and Out, or place the clip before the sequence end."); return
        }
        guard let media = session.project.media(clip.media) else { return }
        flash("Finding the beat...")
        guard let grid = await EditorSession.analyzeBeats(url: URL(fileURLWithPath: media.path)) else { flash("No beat found."); return }
        let versions = session.musicFitVersions(grid: grid, target: target)
        guard !versions.isEmpty else { flash("The clip already has that length, or too few bars to fit."); return }
        let d = ShellDialog("Fit Music to Length",
                            informative: String(format: "%@ to %.1f s. Joins sit on bar lines with a short crossfade.", clip.name,
                                                Double(target.value) / Double(target.timescale)))
        let form = ShellForm([.radio(id: "version", options: versions.enumerated().map { EditorSession.musicFitRowTitle($0.element, index: $0.offset) },
                                     selected: 0)])
        d.form = form
        d.addButton("Fit")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let i = form.index("version"), versions.indices.contains(i) else { return }
        if session.applyMusicFit(versions[i], to: clip.id) { flash("Music fitted to length.") }
        else if let e = session.lastError { flash(e) }
    }

    // MARK: Voiceover from Text

    static let voiceoverVoiceKey = "sq.voiceover.voice", voiceoverRateKey = "sq.voiceover.rate"

    /// Where voiceovers and recorded takes are written (the Mac `Sequence Studio/Voiceovers` in Application Support).
    var voiceoverFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sequence Studio/Voiceovers", isDirectory: true)
    }

    /// The sheet asks for text, voice and speed; the voice is made on this computer into a file, imported like any media and
    /// placed at the playhead on a free audio track.
    func voiceoverFromText(defaults: UserDefaults = .standard) async {
        guard session.activeTimeline != nil else { flash("Open a sequence first."); return }
        guard let backend = voiceover else { flash(ShellPlatformText.notAvailable); return }
        let voices = backend.voices()
        let rate0 = defaults.object(forKey: Self.voiceoverRateKey) == nil ? Voiceover.defaultRate
            : Voiceover.clampedRate(defaults.double(forKey: Self.voiceoverRateKey))
        let remembered = defaults.string(forKey: Self.voiceoverVoiceKey)
        let d = ShellDialog("Voiceover from Text", informative: "The voice is made on this Mac and added as an audio clip at the playhead.")
        let form = ShellForm([
            .textBox(id: "text", value: "", height: 80),
            .popup(id: "voice", label: "Voice", options: voices.map(\.title), selected: voices.firstIndex { $0.id == remembered } ?? 0),
            .sliderNumber(label: "Speed", .init(id: "speed", value: Voiceover.speedFactor(rate: rate0), range: 0.5...2, step: 0.05,
                                                decimals: 2, unit: "x", defaultValue: 1)),
            .text(" "),
        ])
        func rate() -> Double { Voiceover.rate(forSpeedFactor: form.number("speed") ?? 1) }
        func again() {
            form.setNote(3, Voiceover.hintText(for: form.text("text") ?? "", rate: rate(), hasVoices: !voices.isEmpty))
        }
        form.onChange = { _, _ in again() }
        again()
        d.form = form
        d.addButton("Insert at Playhead")
        d.addButton("Cancel", role: .cancel)
        d.buttonEnabled = { i in i != 0 || (!voices.isEmpty && !Voiceover.cleaned(form.text("text") ?? "").isEmpty) }
        guard await ask(d) == .first else { return }
        form.commitEditing()
        let text = Voiceover.cleaned(form.text("text") ?? "")
        guard !text.isEmpty, let v = form.index("voice"), voices.indices.contains(v) else { return }
        let voiceID = voices[v].id, speed = rate()
        defaults.set(voiceID, forKey: Self.voiceoverVoiceKey)
        defaults.set(Voiceover.clampedRate(speed), forKey: Self.voiceoverRateKey)
        await insertVoiceover(text: text, voiceID: voiceID, rate: speed, backend: backend)
    }

    private func insertVoiceover(text: String, voiceID: String, rate: Double, backend: ShellVoiceoverBackend) async {
        let start = session.playhead
        let folder = voiceoverFolder
        let taken = Set(session.project.media.map { ($0.path as NSString).lastPathComponent })
            .union((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let file = Voiceover.fileName(for: text, existing: taken)
        let url = folder.appendingPathComponent(file)
        flash("Making the voiceover…")
        let length: Time
        do { length = try await backend.render(text, voiceID, rate, url) }
        catch {
            flash(error as? ShellVoiceoverError == .noAudio ? "This voice made no sound. Pick another voice." : "Could not make the voiceover.")
            return
        }
        guard let id = await importGenerated(url) else { flash("Could not import the voiceover."); return }
        if session.placeVoiceover(media: id, name: Voiceover.clipName(fromFile: file), duration: length, at: start) != nil {
            flash("Voiceover added on a Dialogue track.")
        }
    }

    /// Imports a file the app made itself (a voiceover, a take) like any media and returns its media id.
    func importGenerated(_ url: URL) async -> MediaRef.ID? {
        guard let model = projectModel else { return nil }
        await model.importFiles([url])
        return model.mediaID(forImported: url)
    }

    // MARK: Record Voice-Over

    #if os(macOS)
    /// Record Voice-Over: the status line shows the countdown and the running time. The take is imported like any media and
    /// placed at the playhead where recording began, on a free Dialogue track.
    func recordVoiceOver() {
        let busy = session.voiceRecorder.isBusy
        guard session.activeTimeline != nil || busy else { flash("Open a sequence first."); return }
        session.voiceRecorder.onChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .idle: self.onJob?(nil)
                case .requestingAccess: self.onJob?(SQL10n.string("Voice-over: waiting for the microphone…"))
                case .countdown(let n): self.onJob?(SQL10n.format("Voice-over starts in %@… (press again to cancel)", String(n)))
                case .recording: self.trackVoiceRecordingTime()
                }
            }
        }
        let folder = voiceoverFolder
        spawn { [weak self] in
            guard let self else { return }
            let step = await self.session.toggleVoiceRecording(folder: folder) { [weak self] url in await self?.importGenerated(url) }
            switch step {
            case .started, .canceled: break
            case .placed: self.flash("Voice-over added on a Dialogue track.")
            case .denied: self.flash("The microphone is off for Sequence Studio. Turn it on in System Settings > Privacy & Security > Microphone.")
            case .failed(let why): self.flash(why)
            }
        }
    }

    /// Updates the job line with the recorded time until recording ends.
    private func trackVoiceRecordingTime() {
        spawn { [weak self] in
            while let self, self.session.voiceRecorder.state == .recording {
                let s = Int(self.session.voiceRecorder.elapsed)
                self.onJob?(SQL10n.format("Recording voice-over %@ (press again to stop)", String(format: "%d:%02d", s / 60, s % 60)))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.onJob?(nil)
        }
    }
    #else
    func recordVoiceOver() { flash(ShellPlatformText.notAvailable) }
    #endif
}
