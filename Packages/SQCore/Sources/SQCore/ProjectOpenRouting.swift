import Foundation

/// What to do with a file the user asked to open (Open panel, Finder, Dock drop, start window).
public enum ProjectOpenRoute: Equatable, Sendable {
    case sequenceStudioProject
    case premiereImport
    case unsupported
}

public enum ProjectOpenRouting {
    public static let premiereExtension = "prproj"

    public static func route(for url: URL) -> ProjectOpenRoute {
        if ProjectFile.isProjectURL(url) { return .sequenceStudioProject }
        if url.pathExtension.lowercased() == premiereExtension { return .premiereImport }
        return .unsupported
    }

    /// The project a folder chosen in a folder chooser stands for: the folder itself or its nearest ancestor that is a
    /// project (by extension), so a user who navigated into a `.sqproj` still opens it. A folder holding `project.json`
    /// counts too. `nil` when the choice is no project. `hasProjectJSON` is injected to keep this free of file access.
    public static func projectFolder(chosen: URL, hasProjectJSON: (URL) -> Bool) -> URL? {
        var url = chosen.standardizedFileURL
        while true {
            if ProjectFile.isProjectURL(url) || url.pathExtension.lowercased() == premiereExtension { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path || url.pathComponents.count <= 1 { break }
            url = parent
        }
        return hasProjectJSON(chosen) ? chosen : nil
    }

    /// Plain-language dialog text for a failed open. `nil` when the error is not a project-file error.
    public static func message(for error: Error, fileName: String) -> (title: String, detail: String)? {
        let title = "Could not open “\(fileName)”"
        guard let e = error as? ProjectFileError else { return nil }
        switch e {
        case .missing:
            return (title, "This file is not a Sequence Studio project. Choose a .\(ProjectFile.fileExtension) project, or use File > Import Premiere Project for a .\(premiereExtension) file.")
        case .corrupt:
            return (title, "“\(fileName)” is damaged. If Sequence Studio saved an autosave of it, you are offered to recover it the next time the app starts.")
        case .newerVersion:
            return (title, "“\(fileName)” was saved by a newer version of Sequence Studio. Update the app to open it.")
        }
    }
}
