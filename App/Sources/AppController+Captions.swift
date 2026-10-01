import AppKit
import SQCore
import SQEditorUI
import SQExport

/// Caption wiring: double-click a caption in the timeline types into it in the Text panel, SRT export, and the
/// right-click menu of captions in the timeline.
extension AppController {
    func wireCaptions() {
        panels.timelineView.onEditCaptionText = { [weak self] id in
            guard let self else { return }
            showPanel(.text)
            panels.textView.editCaption(id)
        }
        panels.textView.onExportSRT = { [weak self] in self?.exportSRT() }
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
                self?.shell.statusBar.flash("Exported \(cues.count) captions.")
            } catch { self?.shell.statusBar.flash("Could not write the SRT file: \(error.localizedDescription)") }
        }
    }
}
