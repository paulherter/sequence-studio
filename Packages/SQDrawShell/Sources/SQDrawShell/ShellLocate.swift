import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Project panel > Locate… on one offline item and Reconnect Media… / Replace Media… on one item (the Mac
/// `locateOffline`/`finishLocate` and `replaceFootage` of the Project panel), as shell flows.
extension ShellHost {
    /// Locate…: choose the file of the offline item `id` (the chooser opens at the folder it was in), relink that item
    /// only, then offer the other offline items whose files sit in the same folder.
    func locateOffline(_ id: MediaRef.ID) async {
        guard let ref = session.project.media(id), ref.status() == .missing else { return }
        guard let files else { flash(ShellPlatformText.notAvailable); return }
        let old = URL(fileURLWithPath: ref.path).deletingLastPathComponent()
        let start = FileManager.default.fileExists(atPath: old.path) ? old : nil
        guard let url = await files.chooseFile(prompt: SQL10n.format("Locate “%@”.", ref.name), directory: start) else { return }
        guard session.locateMedia(id, at: url) else { return }
        projectModel?.scheduleOfflineRefresh()
        onStatus?(SQL10n.format("Located %@.", url.lastPathComponent))
        let folder = url.deletingLastPathComponent()
        let siblings = await session.missingSiblings(in: folder, excluding: id)
        guard !siblings.isEmpty else { return }
        let n = siblings.count
        let d = ShellDialog(SQL10n.plural(n, one: "Reconnect %@ more file in this folder?", other: "Reconnect %@ more files in this folder?"),
                            informative: SQL10n.format(n == 1 ? "%@ other offline file is in “%@”." : "%@ other offline files are in “%@”.",
                                                       String(n), folder.lastPathComponent))
        d.addButton("Reconnect")
        d.addButton("Not Now", role: .cancel)
        guard await ask(d) == .first else { return }
        session.relinkSiblings(siblings)
        projectModel?.scheduleOfflineRefresh()
        onStatus?(SQL10n.plural(n, one: "Reconnected %@ more file.", other: "Reconnected %@ more files."))
    }

    /// Reconnect Media… (offline) / Replace Media… (online): choose a file, probe it, and let it take over the item
    /// (clips, marks, label stay). One undo step.
    func replaceMedia(_ id: MediaRef.ID) async {
        guard let ref = session.project.media(id) else { return }
        guard let files, let probe else { flash(ShellPlatformText.notAvailable); return }
        let dir = URL(fileURLWithPath: ref.path).deletingLastPathComponent()
        let start = FileManager.default.fileExists(atPath: dir.path) ? dir : nil
        guard let url = await files.chooseFile(prompt: SQL10n.format("Choose the file that replaces “%@”.", ref.name),
                                               directory: start) else { return }
        guard let probed = try? await probe(url) else { onStatus?(SQL10n.format("Could not read %@.", url.lastPathComponent)); return }
        session.replaceFootage(id, with: probed)
        projectModel?.scheduleOfflineRefresh()
        onStatus?(SQL10n.format("Replaced footage with %@.", url.lastPathComponent))
    }
}

extension ShellFilePicker {
    /// Default of the protocol requirement: no file chooser (nil).
    public func chooseFile(prompt: String, directory: URL?) async -> URL? { nil }
}
