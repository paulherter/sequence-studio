import AppKit
import SQCore
import SQExport
import SQTimelineUI
import SQUIKit
import UniformTypeIdentifiers

/// File > Export Markers as CSV… and View > Timeline Thumbnails.
extension AppController {
    /// True when `c` was one of these and has been handled.
    func executeMarkerListCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .exportMarkersCSV: exportMarkersCSV()
        case .thumbnailMode(let choice):
            if let mode = ThumbnailMode(rawValue: choice.rawValue) { ThumbnailPrefs.mode = mode }
        default: return false
        }
        return true
    }

    /// Check mark of the thumbnail mode items (`validateTimelineOpItem`).
    func thumbnailModeState(_ choice: ThumbnailModeChoice) -> NSControl.StateValue {
        ThumbnailPrefs.mode.rawValue == choice.rawValue ? .on : .off
    }

    private func exportMarkersCSV() {
        guard let tl = session.activeTimeline else { shell.statusBar.flash("There is no sequence to export."); return }
        guard !MarkerCSV.rows(for: tl).isEmpty else { shell.statusBar.flash("There are no markers to export."); return }
        let out = MarkerCSV.export(tl)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "csv") ?? .plainText]
        panel.nameFieldStringValue = "\(tl.name) Markers.csv"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            do {
                try out.text.write(to: url, atomically: true, encoding: .utf8)
                self?.shell.statusBar.flash(SQL10n.format("Exported %@.", url.lastPathComponent), seconds: 4)
            } catch { self?.shell.statusBar.flash(SQL10n.format("Could not write the CSV file: %@", SQL10n.errorText(error))) }
        }
    }
}
