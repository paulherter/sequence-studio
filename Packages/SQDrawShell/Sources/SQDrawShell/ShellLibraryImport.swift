import Foundation
import SQCore
import SQEditorSession
import SQPremiereImport

/// File > Import Lottie Animation…, Import Motion Graphics Template… and Import Premiere Presets… on the shared shell (the
/// Mac `AppController+Lottie`, `+TemplateImport`, `+PremierePresets`; the reading is `LibraryImports`, shared with them).
/// shortcut: the file chooser takes one file at a time (`ShellFilePicker.chooseFile`), so Motion Graphics Templates are
/// imported one by one (dropping several on the window imports all); upgrade when the picker has a multi-file chooser.
extension ShellHost {
    func runLibraryImportCommand(_ c: EditorCommand) -> Bool {
        guard files != nil else { return false }
        switch c {
        case .importLottie: spawn { await self.chooseAndImportLottie() }
        case .importMotionGraphicsTemplate: spawn { await self.chooseAndImportTemplate() }
        case .importPremierePresets: spawn { await self.chooseAndImportPresets() }
        default: return false
        }
        return true
    }

    func chooseAndImportLottie() async {
        guard let url = await files?.chooseFile(prompt: SQL10n.string("Choose a Lottie animation (.json). It is stored inside the project."),
                                                directory: nil) else { return }
        importLottie(at: url)
    }

    /// Places a Lottie .json at the playhead; a file that cannot be used says why (the Mac alert).
    public func importLottie(at url: URL) {
        if session.addLottieClip(contentsOf: url) == nil, let message = session.lastError {
            presentMessage(SQL10n.format("Could not import “%@”", url.lastPathComponent), message)
        }
    }

    func chooseAndImportTemplate() async {
        guard let url = await files?.chooseFile(prompt: SQL10n.string("Choose Motion Graphics Template files (.mogrt)"), directory: nil)
        else { return }
        await importMotionGraphicsTemplates(at: [url])
    }

    public func importMotionGraphicsTemplates(at urls: [URL]) async {
        let out = await LibraryImports.importMogrts(urls, into: presetStore)
        if out.added > 0 { await presetsChanged?() }
        if let line = out.statusLine { flash(line) }
        if let first = out.failures.first, let title = out.failureTitle {
            presentError(title, first.error)
        } else if out.added > 0, out.dropped > 0 {
            await showImportReport(out.report, fileName: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) templates")
        }
    }

    func chooseAndImportPresets() async {
        guard let url = await files?.chooseFile(prompt: SQL10n.string("Choose a Premiere Pro effect preset file (.prfpset)"),
                                                directory: LibraryImports.premierePresetFiles().first?.deletingLastPathComponent())
        else { return }
        await importPremierePresets(at: url, showReport: true)
    }

    public func importPremierePresets(at url: URL, showReport: Bool) async {
        do {
            let out = try await LibraryImports.importPremierePresets(at: url, into: presetStore)
            await presetsChanged?()
            flash(out.statusLine(fileName: url.lastPathComponent))
            if showReport, !out.report.entries.isEmpty { await showImportReport(out.report, fileName: url.lastPathComponent) }
        } catch {
            SQLog.error("premiere presets import failed: \(error)")
            if showReport { presentError(SQL10n.format("Could not import “%@”", url.lastPathComponent), error) }
        }
    }
}
