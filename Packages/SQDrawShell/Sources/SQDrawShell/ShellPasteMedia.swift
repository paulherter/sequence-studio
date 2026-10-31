import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Paste with files or an image on the system clipboard (the Mac `AppController+PasteMedia`): the host reads the clipboard
/// through `mediaClipboard`; our own clip clipboard keeps priority.
extension ShellHost {
    private var hasOwnClipData: Bool { session.clipboard != nil || session.effectClipboard != nil }

    func mediaRoute(_ content: PasteMedia.Content? = nil) -> PasteMedia.Route {
        guard let read = mediaClipboard else { return .nothing }
        let target = FocusedEditTarget(panel: focus)
        guard target == .timeline || target == .project else { return .nothing }
        if hasOwnClipData { return .ownClipboard }
        let c = content ?? read()
        return PasteMedia.route(target: target, hasOwnClipData: false, hasFiles: !c.fileURLs.isEmpty, hasImage: c.imageData != nil)
    }

    /// Where a pasted image is written (the Mac `AppController.pasteMedia`): an unsaved project keeps the file where it is, so
    /// it goes somewhere that survives a restart; a saved one copies it on import, so the Preferences scratch folder (or temp) does.
    static func pastedImageFolder(saved: Bool, locations: StorageLocations = AppSettings.load().locations) -> URL {
        if !saved {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sequence Studio/Pasted Images", isDirectory: true)
        }
        return locations.scratchDirectory("Pasted Images")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("SQPastedImages", isDirectory: true)
    }

    /// True when Paste imported something from the clipboard.
    func pasteMedia() -> Bool {
        guard let read = mediaClipboard else { return false }
        let content = read()
        switch mediaRoute(content) {
        case .importFiles:
            let n = content.fileURLs.count
            flash(SQL10n.plural(n, one: "Importing %@ pasted file…", other: "Importing %@ pasted files…"))
            importMixed(content.fileURLs)
            return true
        case .importImage:
            guard let png = content.imageData else { return false }
            // A saved project copies the file into its Files folder on import, so the temp folder is enough; an unsaved one
            // keeps the file where it is, so it goes somewhere that survives a restart.
            let folder = Self.pastedImageFolder(saved: session.fileURL != nil)
            do {
                let url = try PasteMedia.writeImage(png, into: folder)
                flash("Importing pasted image…")
                importMixed([url])
            } catch { flash(SQL10n.format("Could not save the pasted image: %@", SQL10n.errorText(error))) }
            return true
        case .ownClipboard, .nothing: return false
        }
    }
}
