import AppKit
import SQCore
import SQEditorUI

/// Clip > Make Subclip (Cmd+U) and Clip > Edit Original (Cmd+E).
extension AppController {
    /// The Source monitor's clip (its In/Out) unless the Project panel has focus; there, the one selected media item.
    func makeSubclipFromSource() {
        let media: MediaRef.ID?
        if let m = panels.source.mediaID, focusedPanel != .project { media = m }
        else {
            let ids = panels.projectView.selectedMediaIDs
            media = ids.count == 1 ? ids.first : nil
        }
        guard let m = media else { shell.statusBar.flash("Open a clip in the Source view and set In and Out first."); return }
        if session.makeSubclip(of: m) == nil { shell.statusBar.flash(session.lastError ?? "Could not make a subclip.", seconds: 3) }
        else { shell.statusBar.flash("Subclip added to the Project panel.", seconds: 2) }
    }

    /// Files to open: the Project panel's selection when it has focus, else the selected timeline clips, else the Source clip.
    var editOriginalPaths: [String] {
        func paths(_ ids: [MediaRef.ID]) -> [String] {
            var seen = Set<String>()
            return ids.compactMap { session.project.media($0)?.path }.filter { seen.insert($0).inserted }
        }
        if focusedPanel == .project { return paths(Array(panels.projectView.selectedMediaIDs)) }
        let timeline = session.originalFilesOfSelection
        if !timeline.isEmpty { return timeline }
        if let m = panels.source.mediaID { return paths([m]) }
        return []
    }

    /// Opens each original file in its default app. Missing files say so instead.
    func editOriginal() {
        let all = editOriginalPaths
        guard !all.isEmpty else { shell.statusBar.flash("Select a clip with a media file to open."); return }
        let present = all.filter { FileManager.default.fileExists(atPath: $0) }
        guard !present.isEmpty else { shell.statusBar.flash("The original file is missing. Reconnect the media first.", seconds: 3); return }
        for p in present { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }
}
