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
