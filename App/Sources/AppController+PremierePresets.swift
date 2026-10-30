import AppKit
import SQCore
import SQEditorUI
import SQDrawShell
import SQLibrary
import SQPremiereImport

/// File > Import Premiere Presets…: reads an effect preset file (.prfpset) into the user preset library (Library >
/// Presets, Effects panel). Also runs once on first launch when Premiere's own preset file is found. Presets whose name
/// is already in the library are not added again. The source file is never modified (docs/PRPROJ-IMPORT.md).
extension AppController {
    static let premierePresetsAutoImportKey = "sq.premierePresets.autoImportDone"

    /// The File menu item is the `importPremierePresets` command; this only runs the first-launch import.
    func installPremierePresetImport() {
        autoImportPremierePresetsOnce()
    }

    @objc func importPremierePresets(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a Premiere Pro effect preset file (.prfpset)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.directoryURL = Self.premierePresetFiles().first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importPremierePresets(at: url, showReport: true) }
    }

    /// First launch only: Premiere's preset file of the newest version, if there is one. Silent apart from the status bar.
    private func autoImportPremierePresetsOnce() {
        let d = UserDefaults.standard
        guard !RenderPanels.isRequested, !d.bool(forKey: Self.premierePresetsAutoImportKey) else { return }
        d.set(true, forKey: Self.premierePresetsAutoImportKey)
        guard let url = Self.premierePresetFiles().first else { return }
        Task { await importPremierePresets(at: url, showReport: false) }
    }

    /// `~/Documents/Adobe/Premiere Pro/<version>/Profile-*/Effect Presets and Custom Items.prfpset`, best first: highest
    /// version, then the most recently changed (the user's own profile over a stock one).
    static func premierePresetFiles() -> [URL] { LibraryImports.premierePresetFiles() }

    func importPremierePresets(at url: URL, showReport: Bool) async {
        do {
            let out = try await LibraryImports.importPremierePresets(at: url, into: LibraryServices.presetStore)
            await panels.libraryModel.reloadPresets()
            NSLog("Premiere presets import %@:\n%@\n%@", url.lastPathComponent, out.report.summary, out.mapperSummary)
            shell.statusBar.flash(out.statusLine(fileName: url.lastPathComponent), seconds: 10)
            let report = out.report
            if showReport, let window, !report.entries.isEmpty {
                dismissAttachedSheets()
                ImportReportSheet.present(report, fileName: url.lastPathComponent, over: window) {}
            }
        } catch {
            SQLog.error("premiere presets import failed: \(error)")
            if showReport { presentError("Could not import “\(url.lastPathComponent)”", error) }
        }
    }
}
