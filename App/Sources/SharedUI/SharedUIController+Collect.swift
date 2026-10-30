import Foundation
import SQDrawShell

extension SharedUIController {
    /// The Project panel health line's Collect (the AppKit `collectFiles`): the shared shell does it (`ShellHost.collectFiles`,
    /// `MediaFileOps.collect`), the same on Windows. `unsaved` is the shot harness's way to ask as an untitled project.
    func collectFiles(projectURL: URL? = nil, unsaved: Bool = false) {
        Task { @MainActor [shell] in await shell.collectFiles(projectURL: projectURL, unsaved: unsaved) }
    }
}
