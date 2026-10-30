import AppKit
import SQCore
import SQEditorUI
import SQExport
import SQTranscribe

/// Caption wiring: double-click a caption in the timeline types into it in the Captions panel, SRT export, and the
/// right-click menu of captions in the timeline.
extension AppController {
    /// View > Show Captions in Program Monitor (Premiere: Closed Captions Display). Only the monitor: the export burn-in
    /// has its own switch. Remembered between launches.
    func toggleCaptionsInMonitor() {
        let on = !session.engine.showsCaptions
        session.engine.showsCaptions = on
        UserDefaults.standard.set(on, forKey: "sq.showCaptionsInMonitor")
        shell.statusBar.flash(on ? "Captions shown in the Program view" : "Captions hidden in the Program view", seconds: 2)
    }

    /// View > Safe Margins: action (90 %) and title (80 %) frames in the Program monitor, also snap targets. Remembered.
    func toggleSafeAreas() {
        panels.toggleSafeMargins()    // the monitor model is the one stored value
    }

    /// Sequence > Add Title (Cmd+T): two lines + emoji, each its own text clip with its In animation, at the playhead.
    func addTitleAtPlayhead() {
        session.stopPlayback()
        guard !session.addTitle().isEmpty else {
            if let e = session.lastError { shell.statusBar.flash(e, seconds: 3) }
            return
        }
        session.seek(to: session.playhead)    // show the new title at once
        shell.statusBar.flash("Title added. Double-click a line to type.", seconds: 2)
    }

    /// Sequence > Transcribe and Create Captions (Cmd+Option+C): transcribes the whole sequence unless the transcript is
    /// current, then creates captions with the default caption look. Undo removes the captions in one step.
    /// Returns the running task (nil when nothing started) with the number of captions created, so a caller can continue.
    @discardableResult
    func transcribeAndCreateCaptions() -> Task<Int, Never>? {
        guard let model = panels.textView.captionsModel else { shell.statusBar.flash("Open a sequence first."); return nil }
        if case .transcribing = model.state { shell.statusBar.flash("Transcription is already running."); return nil }
        model.useDefaultCaptionLook(kit: session.project.styleKit)
        showPanel(.text)
        shell.statusBar.flash("Transcribing the sequence…", seconds: 3)
        return Task { [weak self] in
            let made = await model.transcribeAndCreateCaptions()
            guard let self, made.isEmpty else { return made.count }
            if case .failed(let message) = model.state { self.shell.statusBar.flash(message, seconds: 4) }
            else { self.shell.statusBar.flash("No speech found: no captions were created.", seconds: 3) }
            return 0
        }
    }

    func restoreCaptionsInMonitor() {
        if let v = UserDefaults.standard.object(forKey: "sq.showCaptionsInMonitor") as? Bool { session.engine.showsCaptions = v }
    }

    func wireCaptions() {
        restoreCaptionsInMonitor()
        // Load the speech model now so the first Transcribe and Create Captions does not pay ~9 s for it.
        let warmLanguage = AppSettings.captionLanguage(forProject: session.project.id)
        Task.detached(priority: .utility) { await SpeechAnalyzerTranscriber.warmUp(locale: Locale(identifier: warmLanguage)) }
        panels.timelineView.onEditCaptionText = { [weak self] id in
            guard let self else { return }
            showPanel(.text)
            panels.textView.editCaption(id)
        }
        panels.timelineView.onToggleCaptionTrackVisibility = { [weak self] id in
            guard let self, let track = session.activeTimeline?.captionTrack(id) else { return }
            try? session.performTimeline(track.isVisible ? "Hide Caption Track" : "Show Caption Track") { t in
                guard let i = t.captionTracks.firstIndex(where: { $0.id == id }) else { return }
                t.captionTracks[i].isVisible.toggle()
            }
        }
        panels.textView.onExportSRT = { [weak self] in self?.exportSRT() }
        panels.textView.onImportSRT = { [weak self] in self?.importSRT() }
    }

    /// Reads an SRT file the user picks onto the caption track of the active sequence.
    func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleReader.fileExtensions.compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            guard let data = try? Data(contentsOf: url) else { shell.statusBar.flash("Could not open the subtitle file."); return }
            let format = SubtitleReader.format(forExtension: url.pathExtension) ?? .srt
            if let n = session.importSRT(data: data, format: format) { shell.statusBar.flash(SQL10n.plural(n, one: "Imported %@ caption.", other: "Imported %@ captions.")) }
            else { shell.statusBar.flash(session.lastError ?? "Could not import the subtitle file.") }
        }
    }

    /// Writes the captions of the active sequence as an SRT file the user picks (all visible caption tracks).
    func exportSRT() {
        guard let tl = session.activeTimeline else { return }
        let cues = tl.captionTracks.filter(\.isVisible).flatMap(\.items)
            .sorted { $0.range.start < $1.range.start }
            .map { SRTCue(lines: $0.lines, range: $0.range) }
        guard !cues.isEmpty else { shell.statusBar.flash("There are no captions to export."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(tl.name).srt"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            do {
                try SRTWriter.write(cues, range: .entireSequence, to: url)
                self?.shell.statusBar.flash(SQL10n.plural(cues.count, one: "Exported %@ caption.", other: "Exported %@ captions."))
            } catch { self?.shell.statusBar.flash(SQL10n.format("Could not write the SRT file: %@", SQL10n.errorText(error))) }
        }
    }
}
