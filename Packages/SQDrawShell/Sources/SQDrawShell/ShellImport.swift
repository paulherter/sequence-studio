import Foundation
import SQCore
import SQEditorSession
import SQPremiereImport
import SQUIKit

/// File > Import… and the Premiere project import, translated from the Mac `AppController+ImportAnything` and
/// `AppController+PremiereImport`: one entry for every file kind, media into the Project panel's model (the probe is the
/// platform's: `MediaImporter` on the Mac, `FFmpegMediaProbe` on Windows), a .prproj through SQPremiereImport.
public enum ShellImportKind: Equatable, Sendable {
    case timeline, premiereProject, premierePresets, motionGraphicsTemplate, lottie, media

    /// `AppController.ImportKind.of` unchanged.
    public static func of(_ url: URL) -> ShellImportKind {
        switch url.pathExtension.lowercased() {
        case "edl", "fcpxml", "fcpxmld", "xml", "otio": .timeline
        case "prproj": .premiereProject
        case "prfpset": .premierePresets
        case "mogrt": .motionGraphicsTemplate
        case "json": .lottie
        default: .media
        }
    }
}

extension ShellHost {
    /// File > Import… (Ctrl+I): the chooser, then `importMixed`.
    public func importAnything() async {
        guard let urls = await files?.chooseMedia(), !urls.isEmpty else { return }
        importMixed(urls)
    }

    /// Splits the files by kind (the Mac `importMixed`); also the target of Explorer drops on the window.
    public func importMixed(_ urls: [URL]) {
        var media: [URL] = []
        for url in urls {
            if ProjectFile.isProjectURL(url) { media.append(url); continue }
            switch ShellImportKind.of(url) {
            case .premiereProject: spawn { await self.importPremiereProject(at: url) }
            case .media: media.append(url)
            case .timeline: spawn { await self.importTimeline(at: url) }
            case .premierePresets: spawn { await self.importPremierePresets(at: url, showReport: true) }
            case .motionGraphicsTemplate: spawn { await self.importMotionGraphicsTemplates(at: [url]) }
            case .lottie: importLottie(at: url)
            }
        }
        guard !media.isEmpty else { return }
        guard let model = projectModel else { flash("Import is not available yet."); return }
        spawn {
            await model.importFiles(media)
            self.onProjectChanged?()
        }
    }

    /// The Mac `importPremiereProject(at:)`: read, resolve the stored media paths, probe what was found, map, open.
    /// The checklist shows as a dialog with a row list (the Mac sheet's grouped rows and per-row buttons are one Show button);
    /// Reconnect Media follows when files are missing.
    public func importPremiereProject(at url: URL) async {
        guard url.pathExtension.lowercased() == "prproj" else {
            presentError(SQL10n.format("“%@” is not a Premiere project", url.lastPathComponent), PRImportError.notPremiereProject)
            return
        }
        guard !importRunning else { flash("An import is already running."); return }
        importRunning = true
        defer { importRunning = false }
        guard await confirmDiscardChanges() else { return }
        flash(SQL10n.format("Importing %@…", url.lastPathComponent))
        SQLog.info("premiere import start: \(url.path)")
        do {
            let (doc, resolved) = try await Task.detached(priority: .userInitiated) {
                let doc = try PRReader.read(url: url)
                return (doc, PRMapper.resolveMedia(doc, projectFile: url))
            }.value
            var refs = [String: MediaRef]()
            let stored = PRMapper.mediaPaths(doc)
            var found: [(path: String, file: String)] = []
            for path in stored {
                guard let hit = resolved[path] else { SQLog.info("premiere import: not found \(path)"); continue }
                found.append((path, hit.path))
            }
            if let probe {
                for f in found {
                    do { refs[f.path] = try await probe(URL(fileURLWithPath: f.file)) }
                    catch { SQLog.error("premiere import: cannot read \(f.file): \(error)") }
                }
            }
            SQLog.info("premiere import media: \(refs.count) of \(stored.count) found")
            let result = PRMapper.map(doc, name: url.deletingPathExtension().lastPathComponent, media: refs)
            session.newProject(result.project)
            importChecklist = ShellImportChecklist(report: result.report, project: result.project, fileName: url.lastPathComponent)
            onProjectChanged?()
            SQLog.info("premiere import ok: \(url.lastPathComponent)")
            let dropped = result.report.entries.filter { $0.status == .dropped }.reduce(0) { $0 + $1.count }
            let approx = result.report.entries.filter { $0.status == .approximated }.reduce(0) { $0 + $1.count }
            let line = SQL10n.format("Imported %@: %@ approximated, %@ dropped items.", url.lastPathComponent, String(approx),
                                     String(dropped))
            flash(line)
            // The Mac shows the checklist when something needs a look, then offers Reconnect Media for what is missing.
            if importChecklist?.checklist.needsAttention == true || session.canRelink {
                spawn {
                    if await !self.showImportChecklist(), self.session.canRelink { await self.relinkMedia() }
                }
            }
        } catch {
            presentError(SQL10n.format("Could not import “%@”", url.lastPathComponent), error)
        }
    }
}
