import Foundation
import SQCore
import SQEditorSession
import SQExport
import SQUIKit

/// File > Export helpers shared by the drawn Export sheet (`ShellExportSheet`) and Quick Export: the presets the platform
/// encoder writes, the range choices and the status lines. The host supplies the frame and audio sources
/// (`ShellHost.exportSources`) and the queue with its encoder (`ShellHost.exportQueue`). With `fileOutputs` (the encoder
/// also writes audio-only files, GIFs and image sequences) every Mac preset is offered.
@MainActor
public enum ShellExport {
    /// What one export writes; the form's rows follow it.
    public enum Kind: Equatable, Sendable {
        case video, audio, gif, sequence
        public init(_ s: ExportSettings) {
            if s.audioOnly != nil { self = .audio }
            else if s.frameOutput == .gif { self = .gif }
            else if s.frameOutput != nil { self = .sequence }
            else { self = .video }
        }
    }

    /// The presets an encoder that writes `codecs` can make: the video ones, plus with `fileOutputs` the audio-only, GIF
    /// and image-sequence presets.
    public static func presets(codecs: [VideoCodec], fileOutputs: Bool = false) -> [ExportPreset] {
        ExportPreset.all.filter { p in
            let s = p.settings
            if s.audioOnly != nil || s.frameOutput != nil { return fileOutputs }
            return codecs.contains(s.video.codec)
        }
    }

    /// The PCM depths an audio file format offers (the Mac sheet's choices); empty for AAC.
    public static func bitDepths(_ f: AudioFileFormat?) -> [Int] {
        switch f {
        case .wav: [16, 24, 32]
        case .flac: [16, 24]
        default: []
        }
    }

    /// The range choices the selected sequence offers, as (`ExportDialogModel.rangeMode`, title).
    public static func ranges(_ m: ExportDialogModel) -> [(mode: Int, title: String)] {
        var r: [(Int, String)] = [(0, "Entire sequence")]
        if m.canUseInOut { r.append((1, "In to Out")) }
        if m.canUseSelection { r.append((3, m.selectedClipCount == 1 ? "Selected clip" : "Selected clips")) }
        return r
    }

    /// "1920×1080 · 25 fps · H.264 · 12 Mbit/s · ~ 48 MB".
    public static func summary(_ m: ExportDialogModel) -> String { m.summaryText + " · " + m.estimatedSizeText }

    /// One line per job state for the status bar ("Exporting “Name”: 42%").
    public static func statusLine(_ s: ExportJobStatus) -> String { statusLine(name: s.name, state: s.state, progress: s.progress) }

    static func statusLine(name: String, state: ExportJobState, progress: Double) -> String {
        switch state {
        case .waiting: SQL10n.format("Waiting to export “%@”", name)
        case .running: SQL10n.format("Exporting “%@”: %@%%", name, String(Int((progress * 100).rounded(.down))))
        case .done: SQL10n.format("Exported “%@”", name)
        case .failed(let why): SQL10n.format("Export of “%@” failed: %@", name, why)
        case .cancelled: SQL10n.format("Export of “%@” canceled", name)
        }
    }
}

extension ShellHost {
    static let exportPreferencesKey = "sq.export.preferences"
    static let exportDirectoryKey = "sq.export.lastDirectory"

    /// The commands of the sheet's "Other Formats…" menu (`AppController.exports.otherFormats`).
    static let otherExportFormats: [EditorCommand] = [.exportFrame, .exportMarkersCSV, .exportEDL, .exportFCPXML,
                                                      .exportFinalCutXML, .exportOpenTimelineIO]

    /// File > Export (Cmd+M): the Mac Export sheet (`ShellExportSheet` over `ExportDialogModel`), the offline-media
    /// question, then the queue. The status bar follows the jobs; a finished file offers Show in Finder/Explorer.
    public func showExport(defaults: UserDefaults = .standard) async {
        guard let sources = exportSources, let queue = exportQueue else { flash("Export is not available."); return }
        let items = ExportDialogModel.sequenceItems(for: session)
        guard !items.isEmpty else { flash("There is no sequence to export."); return }
        let model = ExportDialogModel(sequences: items, initialPreset: nil, sources: sources)
        if let id = session.activeTimelineID, items.contains(where: { $0.id == id }) {
            model.selectedID = id
            model.checkedIDs = [id]
        }
        // `ExportCoordinator.makeModel` / `presentDialog`: the last preset and choices, the per-Mac encoder speed.
        QuickExport.applyPreset(to: model, lastPresetID: defaults.string(forKey: Self.lastPresetKey))
        if let p = ExportPreferences.decode(defaults.data(forKey: Self.exportPreferencesKey)) { model.applyPreferences(p) }
        model.encoderSpeed = AppSettings.load().exportEncoderSpeed
        let offered = ShellExport.presets(codecs: exportCodecs, fileOutputs: exportFileOutputs)
        if !offered.contains(where: { $0.id == model.presetID }), model.presetID != ExportDialogModel.customPresetID,
           let p = offered.first { model.presetID = p.id }
        // `ExportCoordinator.quickDirectory`: a saved project exports into its Exports folder, else the last folder.
        model.outputDirectory = session.fileURL == nil ? exportDirectory
            : QuickExport.directory(projectFile: session.fileURL, lastDirectory: exportDirectory.path, moviesDirectory: exportDirectory)
        model.onExportCutDowns = { [weak model] in
            guard let model, let dir = model.outputDirectory else { return }
            Task { @MainActor in _ = await model.submitCutDowns(to: queue, outputDirectory: dir) }
        }
        configureExport?(model)

        // Canceled at a preflight question: the sheet opens again over the same model.
        while true {
            let sheet = ShellExportSheet(model: model, codecs: exportCodecs, fileOutputs: exportFileOutputs)
            if let files {
                sheet.chooseFolder = { [weak files] in await files?.chooseFolder(prompt: SQL10n.string("Choose")) }
            }
            sheet.copyText = copyText
            sheet.preview.frameImage = exportFrameImage
            sheet.rebuild()
            let d = ShellDialog("Export")
            d.headerless = true
            d.width = ShellDialog.M.widthL
            d.cardHeight = ShellDialog.M.heightL
            d.content = sheet
            d.footerNote = { model.outputSummaryText }
            d.addButton("Export", role: .default)
            d.addButton("Cancel", role: .cancel)
            d.addButton("Other Formats\u{2026}")
            d.buttonEnabled = { i in i != 0 || model.canExport }
            var pending: EditorCommand?
            d.canClose = { [weak d] r in
                switch r.rawValue {
                case 0: sheet.commitEditing(); return model.canExport
                case 2:
                    guard let d, let below = d.buttonFrames[2] else { return false }
                    d.menu.popUp(items: Self.otherExportFormats.map { c in
                        SQMenuItem(title: SQL10n.string(c.title)) { [weak d] in pending = c; d?.press(.second) }
                    }, below: below)
                    return false
                default: return true
                }
            }
            let answer = await ask(d)
            sheet.preview.close()
            if let c = pending { _ = execute(c); return }
            guard answer == .first, let dir = model.outputDirectory else { return }
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                presentError("Could not create the export folder", error); return
            }
            exportDirectory = dir
            defaults.set(dir.path, forKey: Self.exportDirectoryKey)
            defaults.set(model.presetID, forKey: Self.lastPresetKey)
            defaults.set(model.preferences.encoded(), forKey: Self.exportPreferencesKey)
            // Canceled at a question: the dialog comes back with the same settings (ExportCoordinator.submitFromDialog).
            guard let ids = await preflightAndSubmit(model, directory: dir, queue: queue) else { continue }
            guard !ids.isEmpty else { return }
            await followExports(ids, in: queue)
            return
        }
    }

    /// `ExportCoordinator.preflightAndSubmit`: the notes of `ExportPreflightReport` (one question, "Export Anyway"), the
    /// question about files already in the folder (Keep Both / Replace), then the queue. nil = canceled at a question.
    func preflightAndSubmit(_ model: ExportDialogModel, directory dir: URL, queue: ExportQueue) async -> [UUID]? {
        let report = await ExportPreflightReport.build(model: model, project: session.project, directory: dir,
                                                       untrackedMagicFrames: untrackedMagicFrames)
        if !report.isEmpty {
            let q = ShellDialog(SQL10n.string(report.title), informative: report.lines.joined(separator: "\n\n"))
            q.addButton(SQL10n.string("Export Anyway"))
            q.addButton(SQL10n.string("Cancel"), role: .cancel)
            guard await ask(q) == .first else { return nil }
        }
        var replace = false
        if let question = ExportPreflightReport.existingFilesQuestion(ExportPreflight.existingTargets(of: model.buildJobs(outputDirectory: dir))) {
            let q = ShellDialog(question.title, informative: question.message)
            q.addButton(SQL10n.string("Keep Both"))
            q.addButton(SQL10n.string("Replace"))
            q.addButton(SQL10n.string("Cancel"), role: .cancel)
            switch await ask(q) {
            case .first: replace = false
            case .second: replace = true
            default: return nil
            }
        }
        return await model.submit(to: queue, outputDirectory: dir, run: true, replaceExisting: replace)
    }

    /// Status lines while the jobs run; the outcome as a dialog at the end.
    func followExports(_ ids: [UUID], in queue: ExportQueue) async {
        var last = ""
        while true {
            let all = await queue.allStatuses().filter { ids.contains($0.id) }
            exportProgress = Self.overallProgress(all.map { ($0.state, $0.progress) })
            guard let current = all.first(where: { if case .running = $0.state { true } else { false } })
                ?? all.first(where: { $0.state == .waiting }) else {
                finishExports(all)
                return
            }
            let line = ShellExport.statusLine(current)
            if line != last { onStatus?(line); last = line }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func finishExports(_ all: [ExportJobStatus]) {
        exportProgress = nil
        let failed = all.compactMap { s -> String? in if case .failed(let why) = s.state { "“\(s.name)”: \(why)" } else { nil } }
        let done = all.compactMap { s -> URL? in if case .done(let url) = s.state { url } else { nil } }
        onExportsFinished?(done, failed)
        if !failed.isEmpty {
            presentMessage("Export failed", failed.joined(separator: "\n"))
            return
        }
        guard let url = done.first else { return }
        onStatus?(SQL10n.format("Exported “%@”", url.lastPathComponent))
        spawn { await self.presentExportFinished(done, url: url) }
    }

    /// "Export finished": the files, Show in Explorer/Finder, and the quiet support reminder of the Mac progress window
    /// (at most once per 7 days, off for good with "Don’t show again").
    func presentExportFinished(_ done: [URL], url: URL, defaults: UserDefaults = .standard) async {
        let remind = SupportReminder.mayShow(exportSucceeded: true, lastShown: defaults.object(forKey: SupportReminder.defaultsKey) as? Date,
                                             now: Date(), turnedOff: defaults.bool(forKey: SupportReminder.offKey))
        let d = ShellDialog("Export finished", informative: done.map(\.path).joined(separator: "\n"))
        d.addButton("OK")
        let reveal = revealFile != nil ? d.addButton("Show in Explorer") : nil
        var support: SQDialogModel.Button?
        if remind {
            support = d.addButton("Enjoying Sequence Studio? Support it")
            d.addButton("Don’t show again", leading: true)
            defaults.set(Date(), forKey: SupportReminder.defaultsKey)
        }
        let answer = await ask(d)
        let idx = answer.rawValue
        if reveal != nil, idx == 1 { revealFile?(url) }
        else if support != nil, idx == (reveal != nil ? 2 : 1) { openURL?(SupportLinks.url) }
        else if support != nil, idx == (reveal != nil ? 3 : 2) { defaults.set(true, forKey: SupportReminder.offKey) }
    }
}
