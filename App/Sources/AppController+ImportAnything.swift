import AppKit
import SQCore
import SQEditorUI
import SQUIKit

/// File > Import…: one entry for everything. The panel takes any file; each file goes to the importer its extension names
/// (timeline interchange, Premiere project or presets, Motion Graphics Template, Lottie, Sequence Studio project, media).
/// The single-kind commands (Import Timeline, Import Lottie, ...) stay in Quick Apply and call their own panels.
extension AppController {

    enum ImportKind: Equatable {
        case timeline, premiereProject, premierePresets, motionGraphicsTemplate, lottie, media

        static func of(_ url: URL) -> ImportKind {
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

    func importAnything() {
        showPanel(.project)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Choose video, audio, images, projects, timelines, LUTs, captions or templates"
        guard panel.runModal() == .OK else { return }
        importMixed(panel.urls)
    }

    /// Splits the picked files by kind; interchange and project files each get their own import (they replace the project).
    func importMixed(_ urls: [URL]) {
        var media: [URL] = []
        for url in urls {
            if ProjectFile.isProjectURL(url) { media.append(url); continue }
            switch ImportKind.of(url) {
            case .timeline: Task { await importTimeline(at: url) }
            case .premiereProject: Task { await importPremiereProject(at: url) }
            case .premierePresets: Task { await importPremierePresets(at: url, showReport: true) }
            case .motionGraphicsTemplate: Task { await importMotionGraphicsTemplates(at: [url]) }
            case .lottie: importLottie(at: url)
            case .media: media.append(url)
            }
        }
        if !media.isEmpty { panels.projectView.importURLs(media) }
    }
}
