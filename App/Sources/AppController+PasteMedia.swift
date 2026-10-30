import AppKit
import SQEditorSession
import SQEditorUI

/// Cmd+V with files or an image on the pasteboard: files go through the normal import into the current bin, an image is
/// written as PNG and imported the same way. Our own clip clipboard keeps priority (see `PasteMedia.route`).
extension AppController {
    private var hasOwnClipData: Bool { session.clipboard != nil || session.effectClipboard != nil }

    /// True when Cmd+V would import something: Project or timeline focused, no clip data of our own, media on the pasteboard.
    var canPasteMedia: Bool {
        guard !hasOwnClipData else { return false }
        let c = PasteMedia.read()
        return PasteMedia.route(target: focusedEditTarget, hasOwnClipData: false,
                                hasFiles: !c.fileURLs.isEmpty, hasImage: c.imageData != nil) != .nothing
    }

    func pasteMedia() {
        let content = PasteMedia.read()
        switch PasteMedia.route(target: focusedEditTarget, hasOwnClipData: hasOwnClipData,
                                hasFiles: !content.fileURLs.isEmpty, hasImage: content.imageData != nil) {
        case .importFiles:
            let n = content.fileURLs.count
            shell.statusBar.flash(SQL10n.plural(n, one: "Importing %@ pasted file…", other: "Importing %@ pasted files…"), seconds: 3)
            Task { await panels.projectModel.importFiles(content.fileURLs) }
        case .importImage:
            guard let png = content.imageData else { return }
            // A saved project copies the file into its Files folder on import, so a temp folder is enough; an unsaved one
            // keeps the file where it is, so it goes somewhere that survives a restart.
            let folder: URL = session.fileURL == nil
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Sequence Studio/Pasted Images", isDirectory: true)
                : (settings.locations.scratchDirectory("Pasted Images")
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("SQPastedImages", isDirectory: true))
            do {
                let url = try PasteMedia.writeImage(png, into: folder)
                shell.statusBar.flash("Importing pasted image\u{2026}", seconds: 3)
                mediaPlacement.markGenerated([url])
                Task { await panels.projectModel.importFiles([url]) }
            } catch { shell.statusBar.flash(SQL10n.format("Could not save the pasted image: %@", SQL10n.errorText(error))) }
        case .ownClipboard, .nothing: break
        }
    }
}
