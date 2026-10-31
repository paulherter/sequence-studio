import AppKit
import SQAnalysis
import SQAudioFX
import SQCore
import SQEditorSession
import SQEditorUI
import SQExport
import SQPlayback
import SQText
import SQUIKit
import SwiftUI

struct ExportSequenceMissing: LocalizedError {
    var errorDescription: String? { "The sequence no longer exists." }
}

/// Export sheet and queue popover. Jobs render the project as it was when the sheet opened: decoded video through
/// the compositor (text, nesting), mixed audio, sidecar SRT (`ExportSourceBuilder`).
@MainActor
final class ExportCoordinator {
    let queue = ExportQueue()
    private(set) lazy var queueModel = ExportQueueModel(queue: queue)
    /// Background tasks shown above the export list in the tasks popover (set by the app controller).
    var jobCenter: JobCenter?
    /// The status-bar job ring, shown first when hidden (set by the app controller): target of the start animation.
    var revealJobIndicator: (() -> NSView?)?
    private(set) lazy var progressPresenter = ExportProgressPresenter(queueModel: queueModel)
    private var popover: SQPopover?
    private var sheet: SQModalSheet?
    private var dialogView: ExportDialogView?
    /// The dialog's picture held in place while the preflight runs (docs/EXPORT-SENDOFF.md).
    private var sendOff: SQFlyToIndicator.SendOff?

    /// Status line (set by the app controller): Quick Export names a partial range.
    var notice: (String) -> Void = { _ in }
    private weak var session: EditorSession?
    private weak var window: NSWindow?

    /// Per-track audio FX presets the playback feeder uses (`ClipSectionsModel.audioPresets`), so the export mix matches
    /// what the user hears. Read when the dialog model is made (jobs keep that snapshot).
    var audioPresets: () -> [Track.ID: TrackAudioPreset] = { [:] }
    /// N8b: builds (or waits for) the dialogue waveforms of the sequence being exported and returns the pause provider
    /// (`TimelineWaveforms.prepareDialogue`), so the export's live duck releases where playback's does, even right after open.
    var prepareDialogueSilences: @MainActor @Sendable (Timeline, Project) async -> (any DialogueSilenceProvider)? = { _, _ in nil }

    /// Targets that are not a render (frame, markers CSV, EDL, FCPXML, Final Cut XML, OpenTimelineIO), shown under "Other Formats…" in the dialog. Set by the app.
    var otherFormats: [(title: String, action: @MainActor () -> Void)] = []

    /// Context for `quickExport()` (the menu command, wired in W2.3, has no arguments). `presentDialog` also sets it.
    func attach(session: EditorSession, window: NSWindow) { self.session = session; self.window = window }

    private enum Keys {
        static let lastPreset = "sq.export.lastPresetID"
        static let lastDirectory = "sq.export.lastDirectory"
        /// JSON of `ExportPreferences`: captions, cover, audio and the other per-export choices.
        static let preferences = "sq.export.preferences"
    }

    /// Where Quick Export writes (decision in `QuickExport.directory`).
    private var quickDirectory: URL {
        QuickExport.directory(projectFile: session?.fileURL,
                              lastDirectory: UserDefaults.standard.string(forKey: Keys.lastDirectory),
                              moviesDirectory: StorageLocations.load().exportFallbackDirectory)
    }

    /// One-click export of the active sequence, no sheet, no folder panel. Preset: the sequence's own platform
    /// (TikTok/Reels/Shorts/YouTube) with its loudness target; a sequence without target uses the last preset exported with.
    func quickExport() {
        guard let session, let window else { NSSound.beep(); return }
        guard let model = makeModel(for: session) else { NSSound.beep(); notice("Nothing to export: there is no sequence."); return }
        QuickExport.applyPreset(to: model, lastPresetID: UserDefaults.standard.string(forKey: Keys.lastPreset))
        if let n = QuickExport.rangeNotice(for: model) { notice(n) }
        quickSubmit(model, window: window)
    }

    private func quickSubmit(_ model: ExportDialogModel, window: NSWindow) {
        guard model.canExport else { NSSound.beep(); notice(model.validationMessages.first ?? "Cannot export this sequence."); return }
        let dir = quickDirectory
        closeSheet(on: window)
        Task { _ = await preflightAndSubmit(model, directory: dir, window: window) }
    }

    /// Pre-flight (offline media, untracked masks, files that already exist), then the queue. The user decides before
    /// anything runs. Returns false when the export was canceled at a question.
    private func preflightAndSubmit(_ model: ExportDialogModel, directory dir: URL, window: NSWindow) async -> Bool {
        let (notes, title) = await preflightWarnings(model, directory: dir)
        if !notes.isEmpty {
            let go = await ask(title, notes.joined(separator: "\n\n"), options: ["Export Anyway"], window: window)
            guard go == 0 else { return false }
        }
        var replace = false
        let existing = ExportPreflight.existingTargets(of: model.buildJobs(outputDirectory: dir))
        if !existing.isEmpty {
            let q = ExportPreflightReport.existingFilesQuestion(existing)!
            let choice = await ask(q.title, q.message, options: ["Keep Both", "Replace"], window: window)
            guard let choice else { return false }
            replace = choice == 1
        }
        endSendOff(launch: true)
        queueModel.start()
        progressPresenter.watch()
        await model.submit(to: queue, outputDirectory: dir, replaceExisting: replace)
        return true
    }

    private func endSendOff(launch: Bool) {
        if launch { sendOff?.send(to: revealJobIndicator?()) } else { sendOff?.cancel() }
        sendOff = nil
    }

    private func ask(_ title: String, _ message: String, options: [String], window: NSWindow) async -> Int? {
        endSendOff(launch: false)  // the held picture must not sit behind a question
        return await withCheckedContinuation { cont in
            SQDialog.choice(title, message: message, options: options, in: window) { cont.resume(returning: $0) }
        }
    }

    func makeModel(for session: EditorSession) -> ExportDialogModel? {
        let items = ExportDialogModel.sequenceItems(for: session)
        guard !items.isEmpty else { return nil }
        let timelines = Dictionary(uniqueKeysWithValues: session.project.timelines.map { ($0.id, $0) })
        let project = session.project
        let resolver = session.media
        let mediaIDs = session.project.media.map(\.id)
        let legacyFont = session.project.usesLegacyBuiltInFont   // old projects keep the Helvetica built-in captions
        let styleKit = session.project.styleKit      // this project's kit, not the process-wide one (two open projects)
        let presets = audioPresets()
        let prepareSilences = prepareDialogueSilences
        let useProxies = AppSettings.load().useProxiesForExport   // global switch (Settings > Storage), off by default
        let renderCache = session.renderCache
        let model = ExportDialogModel(sequences: items, initialPreset: nil) { id, settings in
            guard timelines[id] != nil else { throw ExportSequenceMissing() }
            // A format variant job (W5.1) renders the sequence materialised in that variant (nil = its own format).
            guard let view = project.variantView(of: id, variant: settings.variant) else { throw ExportSequenceMissing() }
            var all = timelines
            for (k, v) in view.sequences { all[k] = v }
            await resolver.prepare(mediaIDs)
            let silences = await prepareSilences(view.timeline, project)    // N8b: the dialogue pauses playback ducks with
            await CaptionLookLibrary.shared.reload()      // saved caption looks must resolve in the burn-in
            // Preview render cache: the export reads the segments playback reads (only when the settings give that picture).
            let timeline = view.timeline, nested = all
            let spans = settings.variant == nil
                ? await MainActor.run { renderCache?.exportSpans(for: timeline, sequences: nested) ?? [] } : []
            return try ExportSourceBuilder.make(timeline: view.timeline, sequences: all, settings: settings, resolver: resolver,
                                                presets: presets, liveDucking: project.liveDucking, dialogueSilences: silences, captionLibrary: CaptionLookRegistry.shared.library(for: styleKit, legacyFont: legacyFont),
                                                useProxies: useProxies, renderCache: spans)
        }
        // The picture in the dialog: the same compositor as the export, small, no audio.
        model.previewSource = { id, settings in
            guard timelines[id] != nil else { throw ExportSequenceMissing() }
            guard let view = project.variantView(of: id, variant: settings.variant) else { throw ExportSequenceMissing() }
            var all = timelines
            for (k, v) in view.sequences { all[k] = v }
            await resolver.prepare(mediaIDs)
            await CaptionLookLibrary.shared.reload()
            return try ExportSourceBuilder.make(timeline: view.timeline, sequences: all, settings: settings, resolver: resolver,
                                                pixelFormat: .bgra8,
                                                captionLibrary: CaptionLookRegistry.shared.library(for: styleKit, legacyFont: legacyFont)).video
        }
        // Stems: one plan per sequence (audio roles + M&E); the audio is the sequence with the other roles muted.
        model.stemPlans = timelines.mapValues { StemPlan.stems(for: $0) }.filter { !$0.value.isEmpty }
        model.stemPresetStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            StemPresetStore(url: $0.appendingPathComponent("Sequence Studio/stem-presets.json"))
        }
        let stemPresets = presets, stemDucking = project.liveDucking
        // shortcut: stems skip the dialogue-silence ducking pass (async); upgrade when the provider can be async.
        model.stemAudio = { _, stem, range in
            TimelineAudioSource(timeline: stem.timeline, sequences: timelines, range: range, presets: stemPresets,
                                liveDucking: stemDucking, resolver: resolver)
        }
        model.outputDirectory = quickDirectory
        model.onExportCutDowns = { [weak self, weak model] in
            guard let self, let model, let dir = model.outputDirectory else { return }
            self.queueModel.start()
            self.progressPresenter.watch()
            Task { _ = await model.submitCutDowns(to: self.queue, outputDirectory: dir) }
        }
        model.encoderSpeed = AppSettings.load().exportEncoderSpeed   // per-Mac choice (Export dialog, sq.export.encoderSpeed)
        if let id = session.activeTimelineID, items.contains(where: { $0.id == id }) {
            model.selectedID = id
            model.checkedIDs = [id]
        }
        return model
    }

    func presentDialog(for session: EditorSession, on window: NSWindow) {
        attach(session: session, window: window)
        guard let model = makeModel(for: session) else { NSSound.beep(); return }
        if let p = ExportPreferences.decode(UserDefaults.standard.data(forKey: Keys.preferences)) { model.applyPreferences(p) }
        present(model: model, on: window)
    }

    private func present(model: ExportDialogModel, on window: NSWindow) {
        let view = ExportDialogView(model: model,
                                    onExport: { [weak self] in self?.submitFromDialog(model, window: window) },
                                    onCancel: { [weak self] in self?.closeSheet(on: window) })
        view.otherFormats = otherFormats.map { f in (f.title, { [weak self] in self?.closeSheet(on: window); f.action() }) }
        let w = SQModalSheet(card: view, size: ExportDialogView.size) { [weak self] in self?.closeSheet(on: window) }
        sheet = w
        dialogView = view
        w.present(over: window)
    }

    private func closeSheet(on window: NSWindow) {
        dialogView?.close()
        dialogView = nil
        sheet?.dismiss()
        sheet = nil
    }

    /// Return in the dialog: the folder is already chosen (footer), so this goes straight to the queue.
    private func submitFromDialog(_ model: ExportDialogModel, window: NSWindow) {
        guard model.canExport, let dir = model.outputDirectory else { return }
        UserDefaults.standard.set(dir.path, forKey: Keys.lastDirectory)
        UserDefaults.standard.set(model.presetID, forKey: Keys.lastPreset)
        UserDefaults.standard.set(model.preferences.encoded(), forKey: Keys.preferences)
        // Visual only: the card's picture stays where the card was until the export is queued, then folds into the ring.
        sendOff?.cancel()
        sendOff = dialogView.flatMap { SQFlyToIndicator.snapshot(of: $0) }.flatMap { SQFlyToIndicator.hold($0, in: window) }
        closeSheet(on: window)
        Task { [weak self] in
            guard let self else { return }
            // Canceled at a question: the dialog comes back with the same settings.
            if await !preflightAndSubmit(model, directory: dir, window: window) {
                endSendOff(launch: false)
                present(model: model, on: window)
            }
        }
    }

    /// Things the user should know before the export starts (`ExportPreflightReport`, shared with the shared shell).
    private func preflightWarnings(_ model: ExportDialogModel, directory dir: URL) async -> (lines: [String], title: String) {
        guard let project = session?.project else { return ([], "") }
        let r = await ExportPreflightReport.build(model: model, project: project, directory: dir) { tl, sequences in
            MagicMatteStore.shared.untrackedFrames(in: tl, sequences: sequences)
        }
        return (r.lines, r.title)
    }

    func showQueue(relativeTo rect: CGRect, of view: NSView) {
        if let p = popover, p.isShown { p.close(); return }
        queueModel.start()
        let host = NSHostingView(rootView: ExportQueueView(model: queueModel, jobs: jobCenter))
        host.frame.size = host.fittingSize
        let p = SQPopover(contentView: host)
        p.mode = .transient
        p.onClose = { [weak self] in self?.popover = nil }
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = p
    }
}
