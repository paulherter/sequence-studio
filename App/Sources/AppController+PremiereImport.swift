import AppKit
import SQCore
import SQEditorUI
import SQMedia
import SQPremiereImport

/// File > Import Premiere Project…: reads a .prproj, probes its media, opens the result as a new untitled project.
/// The source file is never modified (docs/PRPROJ-IMPORT.md).
extension AppController {

    @objc func importPremiereProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a Premiere Pro project (.prproj)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importPremiereProject(at: url) }
    }

    func importPremiereProject(at url: URL) async {
        guard url.pathExtension.lowercased() == "prproj" else {
            presentError("“\(url.lastPathComponent)” is not a Premiere project", PRImportError.notPremiereProject)
            return
        }
        // One import at a time, and never with an old report/relink sheet still on the window (a stacked sheet
        // plus the app-modal "Save changes?" dialog can leave the window unresponsive).
        guard importGate.enter() else { shell.statusBar.flash("An import is already running.", seconds: 4); return }
        defer { importGate.leave() }
        dismissAttachedSheets()
        guard await confirmDiscardChanges() else { return }
        shell.statusBar.flash(SQL10n.format("Importing %@…", url.lastPathComponent), seconds: 30)
        SQLog.info("premiere import start: \(url.path)")
        do {
            let searchFolders = rememberedRelinkFolders
            // Stored paths are often from another Mac/volume or Windows: resolve next to the project and in Locate folders.
            let (doc, resolved) = try await Task.detached(priority: .userInitiated) {
                let doc = try PRReader.read(url: url)
                return (doc, PRMapper.resolveMedia(doc, projectFile: url, searchFolders: searchFolders))
            }.value
            var refs = [String: MediaRef]()
            let stored = PRMapper.mediaPaths(doc)
            var found: [(path: String, file: String)] = []
            for path in stored {
                guard let hit = resolved[path] else { SQLog.info("premiere import: not found \(path)"); continue }
                if hit.method != .storedPath { SQLog.info("premiere import: \(path) -> \(hit.path) (\(hit.method))") }
                found.append((path, hit.path))
            }
            // Several files at once (PLAYBACK-PERF "Import speed"); results come back in order.
            let probed = await MediaImporter.probeAll(found.map { URL(fileURLWithPath: $0.file) })
            for (f, r) in zip(found, probed) {
                switch r {
                case .success(let p): refs[f.path] = p.0
                case .failure(let error): SQLog.error("premiere import: cannot read \(f.file): \(error)")
                }
            }
            SQLog.info("premiere import media: \(refs.count) of \(stored.count) found")
            let result = PRMapper.map(doc, name: url.deletingPathExtension().lastPathComponent, media: refs)
            session.newProject(result.project)
            sweepLeftoverMattes()
            closeStartWindow()
            autoPickWorkspace()
            NSLog("Premiere import %@:\n%@", url.lastPathComponent, result.report.summary)
            SQLog.info("premiere import ok: \(url.lastPathComponent)")
            let dropped = result.report.entries.filter { $0.status == .dropped }.reduce(0) { $0 + $1.count }
            let approx = result.report.entries.filter { $0.status == .approximated }.reduce(0) { $0 + $1.count }
            shell.statusBar.flash(SQL10n.format("Imported %@: %@ approximated, %@ dropped items.", url.lastPathComponent, String(approx), String(dropped)), seconds: 10)
            // The report first; the relink offer follows when it is closed (both are sheets).
            dismissAttachedSheets()
            importChecklistState = ImportChecklistState(report: result.report, project: result.project, fileName: url.lastPathComponent)
            if window != nil, approx + dropped > 0 || !session.missingMedia.isEmpty {
                presentImportChecklist()
            } else {
                offerRelinkIfNeeded()
            }
        } catch {
            presentError("Could not import “\(url.lastPathComponent)”", error)
        }
    }
}

extension AppController {
    /// Ends every sheet still attached to the main window (old import report, relink offer) before a new one replaces the project.
    func dismissAttachedSheets() {
        guard let window else { return }
        // Bounded: a sheet that stays attached after endSheet must not spin the main thread forever.
        for _ in 0..<8 {
            guard let sheet = window.sqAttachedSheet else { return }
            window.endSheet(sheet); sheet.orderOut(nil)
        }
    }
}
