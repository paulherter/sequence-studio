import CSQWinApp
import Foundation
import SQCore
import SQAppShell
import SQDrawShell
import SQInspectorUI
import SQUIKit
import WinSDK

/// The Windows file choosers behind the shell's `ShellFilePicker` seam (the Mac uses NSOpenPanel / NSSavePanel; both
/// platforms keep the system file chooser, the one dialog that is not SQ-drawn): the Common Item Dialog
/// (IFileOpenDialog / IFileSaveDialog, FOS_PICKFOLDERS for folders) in CSQWinApp `sq_file_dialog`.
@MainActor
final class WinFilePicker: ShellFilePicker {
    let owner: HWND

    init(owner: HWND) { self.owner = owner }

    func chooseProject() async -> URL? {
        run(save: false, title: "Open Project", filter: [("Projects", "*.\(ProjectFile.fileExtension);*.ssproj;*.prproj"), ("All files", "*.*")],
            name: "", multiple: false).first
    }

    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? {
        run(save: true, title: prompt, filter: [("Sequence Studio project", "*.\(ProjectFile.fileExtension)")],
            name: suggestedName, multiple: false).first
    }

    /// Export Frame's save chooser: a PNG file.
    func choosePNGLocation(suggestedName: String) -> URL? {
        run(save: true, title: "Export Frame", filter: [("PNG image", "*.png")], name: suggestedName, multiple: false,
            defaultExtension: "png").first
    }

    /// File > Project > Style Kit import and export (`.sqstyle`).
    func chooseStyleKit(save: Bool, suggestedName: String) async -> URL? {
        run(save: save, title: save ? "Export Style Kit" : "Import Style Kit",
            filter: [("Sequence Studio style kit", "*.\(StyleKitFile.fileExtension)")], name: suggestedName, multiple: false,
            defaultExtension: StyleKitFile.fileExtension).first
    }

    /// Keyboard Shortcuts > Import: an own set or another editor's shortcut file (`ForeignKeymapFile`).
    func chooseShortcutFile() async -> URL? {
        run(save: false, title: "Import Shortcuts",
            filter: [("Shortcut files", "*.\(KeymapSet.fileExtension);*.kys;*.commandset;*.txt;*.preset"), ("All files", "*.*")],
            name: "", multiple: false).first
    }

    /// Keyboard Shortcuts > Export: the current set as a `.sqkeys` file.
    func chooseShortcutExportLocation(suggestedName: String) async -> URL? {
        run(save: true, title: "Export Shortcuts", filter: [("Sequence Studio shortcuts", "*.\(KeymapSet.fileExtension)")],
            name: suggestedName, multiple: false, defaultExtension: KeymapSet.fileExtension).first
    }

    /// Captions > Import Subtitles… (`.srt`, `.vtt`, `.ass`).
    func chooseSubtitles() -> URL? {
        let pattern = CaptionsTabDraw.subtitleExtensions.map { "*.\($0)" }.joined(separator: ";")
        return run(save: false, title: "Import Subtitles", filter: [("Subtitles", pattern), ("All files", "*.*")], name: "",
                   multiple: false).first
    }

    /// Captions > Export SRT….
    func chooseCSVLocation(suggestedName: String) -> URL? {
        run(save: true, title: "Export Markers as CSV", filter: [("Comma-separated values", "*.csv")], name: suggestedName,
            multiple: false, defaultExtension: "csv").first
    }

    func chooseSRTLocation(suggestedName: String) -> URL? {
        run(save: true, title: "Export SRT", filter: [("SubRip subtitles", "*.srt")], name: suggestedName, multiple: false,
            defaultExtension: "srt").first
    }

    /// Color: LUT files; several for Add LUTs to Library….
    func chooseLUTs(multiple: Bool) -> [URL] {
        let pattern = LUTFileTypes.extensions.map { "*.\($0)" }.joined(separator: ";")
        return run(save: false, title: multiple ? "Add LUTs to Library" : "Choose a LUT", filter: [("LUT files", pattern), ("All files", "*.*")],
                   name: "", multiple: multiple)
    }

    func chooseMedia() async -> [URL] {
        run(save: false, title: "Import", filter: [("All files", "*.*")], name: "", multiple: true)
    }

    /// Reconnect Media's Locate…: one file, opening in the folder the offline file was in.
    func chooseFile(prompt: String, directory: URL?) async -> URL? {
        Self.dialog(owner, mode: Int32(SQ_FILE_DIALOG_OPEN), title: prompt, filter: [("All files", "*.*")], folder: directory).first
    }

    /// File > Export EDL / XML / FCPXML / OpenTimelineIO.
    func chooseExportLocation(suggestedName: String, fileExtension: String, prompt: String) async -> URL? {
        run(save: true, title: prompt, filter: [(fileExtension.uppercased() + " file", "*.\(fileExtension)")], name: suggestedName,
            multiple: false, defaultExtension: fileExtension).first
    }

    /// Reconnect Media's and Preferences' folder chooser (the Mac NSOpenPanel with canChooseDirectories).
    func chooseFolder(prompt: String) async -> URL? {
        Self.dialog(owner, mode: Int32(SQ_FILE_DIALOG_FOLDER), title: prompt, filter: []).first.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private func run(save: Bool, title: String, filter: [(String, String)], name: String, multiple: Bool,
                     defaultExtension: String = ProjectFile.fileExtension) -> [URL] {
        let mode = save ? SQ_FILE_DIALOG_SAVE : multiple ? SQ_FILE_DIALOG_OPEN_MULTIPLE : SQ_FILE_DIALOG_OPEN
        return Self.dialog(owner, mode: Int32(mode), title: title, filter: filter, name: name,
                           defaultExtension: save ? defaultExtension : "")
    }

    static func dialog(_ owner: HWND, mode: Int32, title: String, filter: [(String, String)], folder: URL? = nil,
                       name: String = "", defaultExtension: String = "") -> [URL] {
        var filterText: [UInt16] = []
        for (label, pattern) in filter { filterText += Array(label.utf16) + [0] + Array(pattern.utf16) + [0] }
        filterText.append(0)
        let folderText = folder.map { wide($0.withUnsafeFileSystemRepresentation { String(cString: $0!) }) } ?? [0]
        var buffer = [UInt16](repeating: 0, count: 1 << 20)
        let n = sq_file_dialog(UnsafeMutableRawPointer(owner), mode, wide(title), filterText, folderText, wide(name),
                               wide(defaultExtension), &buffer, Int32(buffer.count))
        guard n > 0 else { return [] }
        return paths(in: buffer).map { URL(fileURLWithPath: $0) }
    }

    /// The paths of "path\0path\0\0".
    static func paths(in buffer: [UInt16]) -> [String] {
        var parts: [String] = []
        var start = 0
        for i in buffer.indices where buffer[i] == 0 {
            if i == start { break }
            parts.append(String(decoding: buffer[start..<i], as: UTF16.self))
            start = i + 1
        }
        return parts
    }
}
