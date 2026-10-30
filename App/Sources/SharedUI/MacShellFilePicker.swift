import AppKit
import SQAppShell
import SQCore
import SQDrawShell
import SQInspectorUI
import SQUIKit
import UniformTypeIdentifiers

/// The Mac file choosers behind the shell's `ShellFilePicker` seam (the system chooser stays native on both platforms, as
/// WinFilePicker keeps the Windows one).
@MainActor
final class MacShellFilePicker: ShellFilePicker, PanelFileChooser {
    private func open(_ title: String, extensions: [String], multiple: Bool = false, folders: Bool = false) -> [URL] {
        let p = NSOpenPanel()
        p.title = title
        p.allowsMultipleSelection = multiple
        p.canChooseDirectories = folders
        p.canChooseFiles = !folders
        p.treatsFilePackagesAsDirectories = false
        if !extensions.isEmpty { p.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) } }
        return p.runModal() == .OK ? p.urls : []
    }

    private func save(_ title: String, name: String, ext: String) -> URL? {
        let p = NSSavePanel()
        p.title = title
        p.nameFieldStringValue = name
        if let t = UTType(filenameExtension: ext) { p.allowedContentTypes = [t] }
        return p.runModal() == .OK ? p.url : nil
    }

    func chooseProject() async -> URL? {
        open("Open Project", extensions: [ProjectFile.fileExtension, "ssproj", "prproj"]).first
    }

    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? {
        save(prompt, name: suggestedName, ext: ProjectFile.fileExtension)
    }

    func chooseMedia() async -> [URL] { open("Import", extensions: [], multiple: true) }

    func chooseShortcutFile() async -> URL? {
        open("Import Shortcuts", extensions: [KeymapSet.fileExtension, "kys", "commandset", "txt", "preset"]).first
    }

    func chooseShortcutExportLocation(suggestedName: String) async -> URL? {
        save("Export Shortcuts", name: suggestedName, ext: KeymapSet.fileExtension)
    }

    func chooseStyleKit(save isSave: Bool, suggestedName: String) async -> URL? {
        isSave ? save("Export Style Kit", name: suggestedName, ext: StyleKitFile.fileExtension)
            : open("Import Style Kit", extensions: [StyleKitFile.fileExtension]).first
    }

    func chooseFolder(prompt: String) async -> URL? { open(prompt, extensions: [], folders: true).first }

    /// Reconnect Media's Locate…, Replace Media… and Import Timeline…: one file, opening in `directory`.
    func chooseFile(prompt: String, directory: URL?) async -> URL? {
        let p = NSOpenPanel()
        p.title = prompt
        p.message = prompt
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.treatsFilePackagesAsDirectories = false
        if let directory { p.directoryURL = directory }
        return p.runModal() == .OK ? p.url : nil
    }

    /// File > Export EDL / XML / FCPXML / OpenTimelineIO.
    func chooseExportLocation(suggestedName: String, fileExtension: String, prompt: String) async -> URL? {
        save(prompt, name: suggestedName, ext: fileExtension)
    }

    // MARK: PanelFileChooser (the shared hosts)

    func chooseSubtitles() -> URL? { open("Import Subtitles", extensions: CaptionsTabDraw.subtitleExtensions).first }
    func chooseSRTLocation(suggestedName: String) -> URL? { save("Export SRT", name: suggestedName, ext: "srt") }
    func choosePNGLocation(suggestedName: String) -> URL? { save("Export Frame", name: suggestedName, ext: "png") }
    func chooseCSVLocation(suggestedName: String) -> URL? { save("Export Markers as CSV", name: suggestedName, ext: "csv") }
    func chooseLUTs(multiple: Bool) -> [URL] {
        open(multiple ? "Add LUTs to Library" : "Choose a LUT", extensions: LUTFileTypes.extensions, multiple: multiple)
    }
}
