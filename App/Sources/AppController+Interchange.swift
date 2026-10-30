import AppKit
import SQCore
import SQEditorUI
import SQExport
import SQMedia
import SQPremiereImport

/// File > Import Timeline… (CMX3600 EDL, Final Cut Pro 7 XML, FCPXML, OpenTimelineIO) and File > Export EDL… / Final Cut Pro XML… / FCPXML… / OpenTimelineIO….
/// Import opens the result as a new untitled project like the Premiere import; the source file is never modified.
extension AppController {

    @objc func importTimeline(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose an EDL (.edl), Final Cut Pro XML (.xml), FCPXML (.fcpxml) or OpenTimelineIO (.otio) file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importTimeline(at: url) }
    }

    func importTimeline(at url: URL) async {
        guard importGate.enter() else { shell.statusBar.flash("An import is already running.", seconds: 4); return }
        defer { importGate.leave() }
        dismissAttachedSheets()
        guard await confirmDiscardChanges() else { return }
        shell.statusBar.flash(SQL10n.format("Importing %@…", url.lastPathComponent), seconds: 30)
        SQLog.info("timeline import start: \(url.path)")
        do {
            // An EDL has no frame rate: take the open sequence's.
            let fd = session.activeTimeline?.format.frameDuration ?? Time(1, 25)
            let searchFolders = rememberedRelinkFolders
            let (sequences, resolved) = try await Task.detached(priority: .userInitiated) { () -> ([IXSequence], [String: String]) in
                // Every sequence of the file becomes a sequence of the new project (the first one is open).
                let s = try InterchangeReader.readAll(url: url, defaultFrameDuration: fd)
                return (s, Self.locateInterchangeMedia(InterchangeMapper.mediaPaths(s), nextTo: url, searchFolders: searchFolders))
            }.value
            let found = resolved.sorted { $0.key < $1.key }
            let probed = await MediaImporter.probeAll(found.map { URL(fileURLWithPath: $0.value) })
            var refs = [String: MediaRef]()
            for (f, r) in zip(found, probed) {
                switch r {
                case .success(let p): refs[f.key] = p.0
                case .failure(let error): SQLog.error("timeline import: cannot read \(f.value): \(error)")
                }
            }
            let result = InterchangeMapper.map(sequences, name: url.deletingPathExtension().lastPathComponent, media: refs)
            session.newProject(result.project)
            sweepLeftoverMattes()
            closeStartWindow()
            autoPickWorkspace()
            SQLog.info("timeline import ok: \(url.lastPathComponent)")
            let dropped = result.report.entries.filter { $0.status == .dropped }.reduce(0) { $0 + $1.count }
            let approx = result.report.entries.filter { $0.status == .approximated }.reduce(0) { $0 + $1.count }
            shell.statusBar.flash(SQL10n.format("Imported %@: %@ approximated, %@ dropped items.", url.lastPathComponent, String(approx), String(dropped)), seconds: 10)
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

    /// Stored path if the file is there, else the same file name next to the interchange file or in a Locate folder.
    nonisolated static func locateInterchangeMedia(_ paths: [String], nextTo file: URL, searchFolders: [URL]) -> [String: String] {
        let fm = FileManager.default
        let folders = [file.deletingLastPathComponent()] + searchFolders
        var out = [String: String]()
        for p in paths where !p.isEmpty {
            if p.hasPrefix("/"), fm.fileExists(atPath: p) { out[p] = p; continue }
            let name = p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? p
            guard !name.isEmpty else { continue }
            if let hit = folders.map({ $0.appendingPathComponent(name).path }).first(where: { fm.fileExists(atPath: $0) }) {
                out[p] = hit
            }
        }
        return out
    }

    @objc func exportEDL(_ sender: Any?) {
        exportInterchange(ext: "edl", label: "EDL", render: { EDLWriter.render($0, media: $1) },
                          extraFiles: { tl, media in
                              EDLWriter.layerFiles(tl, media: media).map { (suffix: " " + $0.label, export: $0.export) }
                          })
    }

    @objc func exportFCPXML(_ sender: Any?) {
        guard session.activeTimeline != nil else { shell.statusBar.flash("There is no sequence to export."); return }
        InterchangeExportSheet.present(over: window) { [weak self] version, target in
            guard let target else { return }
            self?.exportInterchange(ext: "fcpxml", label: "FCPXML") {
                FCPXMLWriter.render($0, media: $1, version: version, target: target)
            }
        }
    }

    @objc func exportXMEML(_ sender: Any?) {
        exportInterchange(ext: "xml", label: "Final Cut Pro XML") { XMEMLWriter.render($0, media: $1) }
    }

    @objc func exportOTIO(_ sender: Any?) {
        guard session.activeTimeline != nil else { shell.statusBar.flash("There is no sequence to export."); return }
        // One sequence: no question to ask.
        guard session.project.timelines.count > 1 else {
            exportInterchange(ext: "otio", label: "OpenTimelineIO") { OTIOWriter.render($0, media: $1) }
            return
        }
        OTIOScopeSheet.present(over: window) { [weak self] scope in
            guard let self, let scope else { return }
            let all = scope.timelines(in: self.session.project)
            self.exportInterchange(ext: "otio", label: "OpenTimelineIO") { _, media in OTIOWriter.render(all, media: media) }
        }
    }

    /// `extraFiles`: more files written next to the chosen one (EDL: one per video layer above V1, "Name V2.edl").
    private func exportInterchange(ext: String, label: String, render: (Timeline, [MediaRef]) -> InterchangeExport,
                                   extraFiles: ((Timeline, [MediaRef]) -> [(suffix: String, export: InterchangeExport)])? = nil) {
        guard let tl = session.activeTimeline else { shell.statusBar.flash("There is no sequence to export."); return }
        let out = render(tl, session.project.media)
        let extras = extraFiles?(tl, session.project.media) ?? []
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = "\(tl.name).\(ext)"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            do {
                try out.text.write(to: url, atomically: true, encoding: .utf8)
                for e in extras {
                    let name = url.deletingPathExtension().lastPathComponent + e.suffix
                    try e.export.text.write(to: url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext),
                                            atomically: true, encoding: .utf8)
                }
                for w in out.warnings { SQLog.info("\(label) export: \(w)") }
                let more = extras.isEmpty ? "" : " " + SQL10n.plural(extras.count, one: "Plus %@ layer file.", other: "Plus %@ layer files.")
                let skipped = more + (out.warnings.isEmpty ? "" : " " + SQL10n.format("%@ notes: %@", String(out.warnings.count), out.warnings.prefix(2).joined(separator: "; ")))
                self?.shell.statusBar.flash(SQL10n.format("Exported %@.", url.lastPathComponent) + skipped, seconds: out.warnings.isEmpty ? 4 : 12)
            } catch { self?.shell.statusBar.flash(SQL10n.format("Could not write the %@ file: %@", label, SQL10n.errorText(error))) }
        }
    }
}
