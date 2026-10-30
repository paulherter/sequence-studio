import Foundation
import SQCore
import SQUIKit
import SQEditorSession
import SQExport
import SQPremiereImport

/// File > Import Timeline… and File > Export EDL… / Final Cut Pro XML… / FCPXML… / OpenTimelineIO… (the Mac
/// `AppController+Interchange`, `InterchangeExportSheet`, `OTIOScopeSheet`) on the portable readers and writers.
/// Import opens the result as a new untitled project like the Premiere import; the source file is never modified.
extension ShellHost {
    /// The Mac sheets' remembered choices (same keys, so both shells share them).
    static let fcpxmlVersionKey = "sq.export.fcpxmlVersion", fcpxmlTargetKey = "sq.export.fcpxmlTarget"
    static let otioScopeKey = "sq.export.otioScope"
    static let fcpxmlTargetTitles = ["DaVinci Resolve", "Final Cut Pro"]

    /// One interchange file to write: the main text plus EDL layer files ("Name V2.edl" next to it).
    struct InterchangeFile {
        var ext: String
        var label: String
        var main: InterchangeExport
        var extras: [(suffix: String, export: InterchangeExport)] = []
    }

    /// The FCPXML form: version and target, preset from the remembered choice. nil = canceled.
    func askFCPXMLOptions() async -> (FCPXMLWriter.Version, FCPXMLWriter.Target)? {
        let d = startDefaults
        let versions = FCPXMLWriter.Version.allCases, targets = FCPXMLWriter.Target.allCases
        let v = d.string(forKey: Self.fcpxmlVersionKey).flatMap(FCPXMLWriter.Version.init(rawValue:)) ?? .v1_8
        let t = d.string(forKey: Self.fcpxmlTargetKey).flatMap(FCPXMLWriter.Target.init(rawValue:)) ?? .resolve
        let form = ShellForm([
            .popup(id: "version", label: "Version", options: versions.map(\.rawValue), selected: versions.firstIndex(of: v) ?? 0),
            .popup(id: "target", label: "Target", options: Self.fcpxmlTargetTitles, selected: targets.firstIndex(of: t) ?? 0),
        ])
        let dlg = ShellDialog("Export FCPXML",
                              informative: "Final Cut Pro 10.4 reads 1.8, 10.6 reads 1.10, 11 reads 1.13. DaVinci Resolve reads all three.")
        dlg.width = 420
        dlg.form = form
        dlg.addButton("Export…")
        dlg.addButton("Cancel", role: .cancel)
        guard await ask(dlg) == .first else { return nil }
        let version = versions[min(form.index("version") ?? 0, versions.count - 1)]
        let target = targets[min(form.index("target") ?? 0, targets.count - 1)]
        d.set(version.rawValue, forKey: Self.fcpxmlVersionKey)
        d.set(target.rawValue, forKey: Self.fcpxmlTargetKey)
        return (version, target)
    }

    /// The OpenTimelineIO scope; asked only when the project has more than one sequence. nil = canceled.
    func askOTIOScope() async -> OTIOWriter.Scope? {
        guard session.project.timelines.count > 1 else { return .activeSequence }
        let d = startDefaults
        let all = OTIOWriter.Scope.allCases
        let saved = d.string(forKey: Self.otioScopeKey).flatMap(OTIOWriter.Scope.init(rawValue:)) ?? .activeSequence
        let form = ShellForm([.radio(id: "scope", options: ["Open sequence", "All sequences"], selected: all.firstIndex(of: saved) ?? 0)])
        let dlg = ShellDialog("Export OpenTimelineIO",
                              informative: "All sequences are written to one file; importing it opens each of them as a sequence.")
        dlg.width = 400
        dlg.form = form
        dlg.addButton("Export…")
        dlg.addButton("Cancel", role: .cancel)
        guard await ask(dlg) == .first else { return nil }
        let scope = all[min(form.index("scope") ?? 0, all.count - 1)]
        d.set(scope.rawValue, forKey: Self.otioScopeKey)
        return scope
    }

    /// Renders the file `c` asks for (after its options form); nil = no sequence or canceled.
    func interchangeFile(for c: EditorCommand) async -> InterchangeFile? {
        guard let tl = session.activeTimeline else { flash("There is no sequence to export."); return nil }
        let media = session.project.media
        switch c {
        case .exportEDL:
            return InterchangeFile(ext: "edl", label: "EDL", main: EDLWriter.render(tl, media: media),
                                   extras: EDLWriter.layerFiles(tl, media: media).map { (suffix: " " + $0.label, export: $0.export) })
        case .exportFinalCutXML:
            return InterchangeFile(ext: "xml", label: "Final Cut Pro XML", main: XMEMLWriter.render(tl, media: media))
        case .exportFCPXML:
            guard let (version, target) = await askFCPXMLOptions() else { return nil }
            return InterchangeFile(ext: "fcpxml", label: "FCPXML", main: FCPXMLWriter.render(tl, media: media, version: version, target: target))
        case .exportOpenTimelineIO:
            guard let scope = await askOTIOScope() else { return nil }
            return InterchangeFile(ext: "otio", label: "OpenTimelineIO", main: OTIOWriter.render(scope.timelines(in: session.project), media: media))
        default: return nil
        }
    }

    /// Writes `file` to `url` (and its layer files next to it); the status line the Mac shows.
    static func write(_ file: InterchangeFile, to url: URL) throws -> String {
        try file.main.write(to: url)
        for e in file.extras {
            let name = url.deletingPathExtension().lastPathComponent + e.suffix
            try e.export.write(to: url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(file.ext))
        }
        for w in file.main.warnings { SQLog.info("\(file.label) export: \(w)") }
        let more = file.extras.isEmpty ? "" : " " + SQL10n.plural(file.extras.count, one: "Plus %@ layer file.", other: "Plus %@ layer files.")
        let notes = file.main.warnings.isEmpty ? ""
            : " " + SQL10n.format("%@ notes: %@", String(file.main.warnings.count), file.main.warnings.prefix(2).joined(separator: "; "))
        return SQL10n.format("Exported %@.", url.lastPathComponent) + more + notes
    }

    func exportInterchange(_ c: EditorCommand) async {
        guard let file = await interchangeFile(for: c), let tl = session.activeTimeline else { return }
        guard let url = await files?.chooseExportLocation(suggestedName: "\(tl.name).\(file.ext)", fileExtension: file.ext,
                                                         prompt: "Export \(file.label)") else { return }
        do { flash(try Self.write(file, to: url)) }
        catch { flash(SQL10n.format("Could not write the %@ file: %@", file.label, SQL10n.errorText(error))) }
    }

    /// Stored path if the file is there, else the same file name next to the interchange file or in a Reconnect folder.
    nonisolated static func locateInterchangeMedia(_ paths: [String], nextTo file: URL, searchFolders: [URL]) -> [String: String] {
        let fm = FileManager.default
        let folders = [file.deletingLastPathComponent()] + searchFolders
        var out = [String: String]()
        for p in paths where !p.isEmpty {
            if fm.fileExists(atPath: p) { out[p] = p; continue }
            let name = MediaPathResolver.fileName(of: p)
            guard !name.isEmpty else { continue }
            if let hit = folders.map({ $0.appendingPathComponent(name).path }).first(where: { fm.fileExists(atPath: $0) }) {
                out[p] = hit
            }
        }
        return out
    }

    func chooseAndImportTimeline() async {
        guard let url = await files?.chooseFile(
            prompt: "Choose an EDL (.edl), Final Cut Pro XML (.xml), FCPXML (.fcpxml) or OpenTimelineIO (.otio) file", directory: nil)
        else { return }
        await importTimeline(at: url)
    }

    /// The Mac `importTimeline(at:)`: read every sequence, find the media, probe it, map, open; then the checklist.
    public func importTimeline(at url: URL) async {
        guard !importRunning else { flash("An import is already running."); return }
        importRunning = true
        defer { importRunning = false }
        guard await confirmDiscardChanges() else { return }
        flash(SQL10n.format("Importing %@…", url.lastPathComponent))
        SQLog.info("timeline import start: \(url.path)")
        do {
            // An EDL has no frame rate: take the open sequence's.
            let fd = session.activeTimeline?.format.frameDuration ?? Time(1, 25)
            let folders = (startDefaults.stringArray(forKey: Self.relinkFoldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
            let (sequences, resolved) = try await Task.detached(priority: .userInitiated) { () -> ([IXSequence], [String: String]) in
                let s = try InterchangeReader.readAll(url: url, defaultFrameDuration: fd)
                return (s, Self.locateInterchangeMedia(InterchangeMapper.mediaPaths(s), nextTo: url, searchFolders: folders))
            }.value
            var refs = [String: MediaRef]()
            if let probe {
                for f in resolved.sorted(by: { $0.key < $1.key }) {
                    do { refs[f.key] = try await probe(URL(fileURLWithPath: f.value)) }
                    catch { SQLog.error("timeline import: cannot read \(f.value): \(error)") }
                }
            }
            let result = InterchangeMapper.map(sequences, name: url.deletingPathExtension().lastPathComponent, media: refs)
            session.newProject(result.project)
            importChecklist = ShellImportChecklist(report: result.report, project: result.project, fileName: url.lastPathComponent)
            onProjectChanged?()
            SQLog.info("timeline import ok: \(url.lastPathComponent)")
            let dropped = result.report.entries.filter { $0.status == .dropped }.reduce(0) { $0 + $1.count }
            let approx = result.report.entries.filter { $0.status == .approximated }.reduce(0) { $0 + $1.count }
            flash(SQL10n.format("Imported %@: %@ approximated, %@ dropped items.", url.lastPathComponent, String(approx), String(dropped)))
            if approx + dropped > 0 || session.canRelink {
                spawn {
                    if await !self.showImportChecklist(), self.session.canRelink { await self.relinkMedia() }
                }
            }
        } catch {
            presentError(SQL10n.format("Could not import “%@”", url.lastPathComponent), error)
        }
    }
}

extension ShellFilePicker {
    /// File > Export EDL / XML / FCPXML / OpenTimelineIO: where the file goes. Default: not offered.
    public func chooseExportLocation(suggestedName: String, fileExtension: String, prompt: String) async -> URL? { nil }
}
