import AppKit
import SQCore
import SQEditorUI
import SQDrawShell
import SQLibrary
import SQPremiereImport
import UniformTypeIdentifiers

/// File > Import Motion Graphics Template…: reads .mogrt files into the Library as title templates (Library > Titles),
/// where they are placed and edited like a template saved in the app. A template whose name is already in the library is
/// not added again. Templates that need After Effects are refused with a message; what a template holds beyond text is
/// listed in the import report (docs/ENGINE-NOTES.md "Motion Graphics Templates (.mogrt)"). Source files are never modified.
extension AppController {

    @objc func importMotionGraphicsTemplates(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose Motion Graphics Template files (.mogrt)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.allowedContentTypes = [UTType(filenameExtension: MogrtImporter.fileExtension)].compactMap { $0 }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await importMotionGraphicsTemplates(at: urls) }
    }

    func importMotionGraphicsTemplates(at urls: [URL]) async {
        let out = await LibraryImports.importMogrts(urls, into: LibraryServices.presetStore)
        let (added, dropped, report) = (out.added, out.dropped, out.report)
        if added > 0 { await panels.libraryModel.reloadPresets() }
        if let text = out.statusLine { shell.statusBar.flash(text, seconds: 10) }
        if let first = out.failures.first, let title = out.failureTitle {
            // One alert: the first reason in full, the count of the rest.
            presentError(title, first.error)
        } else if added > 0, dropped > 0, let window {
            dismissAttachedSheets()
            ImportReportSheet.present(report, fileName: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) templates", over: window) {}
        }
    }
}
