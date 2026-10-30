import Foundation
import SQCore
import SQEditorSession
import SQMedia

extension ShellHost {
    /// File > Collect Files into Project Folder and the Project panel's Fix > Collect (the AppKit `collectFiles`): copies the
    /// used media outside the project's Imported folder into it and re-points the project at the copies; not an undo step,
    /// originals stay untouched. The copying is `MediaFileOps.collect`, the same on the Mac and on Windows.
    /// shortcut: no media watcher pause and no deferral while playing (the shared shell runs no MediaPlacement); upgrade
    /// when the shared shell gets the watcher.
    /// `projectURL` stands in for the session's file (the shot harness asks as an untitled project with `unsaved`).
    public func collectFiles(projectURL: URL? = nil, unsaved: Bool = false) async {
        guard let url = unsaved ? nil : (projectURL ?? session.fileURL) else {
            presentError("Save the project first", NSError(domain: "SQ", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Collect Files needs a project folder. Use File > Save As… or create the project with New Project."]))
            return
        }
        let folder = MediaManagement.importedFolder(forProjectAt: url)
        let media = session.project.media, projectID = session.project.id
        flash("Collecting files…")
        let outcome = await Task.detached(priority: .userInitiated) { MediaFileOps.collect(media: media, into: folder) }.value
        guard session.project.id == projectID else { return }   // another project meanwhile
        session.relinkMediaQuietly(Dictionary(outcome.done.map { ($0.id, $0.destination) }, uniquingKeysWith: { a, _ in a }))
        projectModel?.scheduleOfflineRefresh()
        let n = Set(outcome.done.map(\.source)).count
        onStatus?(outcome.failed.isEmpty
            ? (n == 0 ? SQL10n.string("All media is already in the project folder.")
                      : SQL10n.format("Collected %@ files into %@.", String(n), folder.lastPathComponent))
            : SQL10n.format("Collected %@ files; could not copy: %@. Those stay where they are.", String(n),
                            outcome.failed.prefix(3).joined(separator: ", ")))
    }
}
