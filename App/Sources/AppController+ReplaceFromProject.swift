import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// Clip > Replace Clip from Project: the one selected clip plays the media item or sequence selected in the Project
    /// panel (media from its In mark; a sequence from its start). Same edit as Option-drop.
    func replaceClipFromProject() {
        guard session.selection.count == 1, let clip = session.selection.first else {
            shell.statusBar.flash("Select one clip in the timeline to replace.", seconds: 3); return
        }
        let media = panels.projectView.selectedMediaIDs, seqs = panels.projectView.selectedSequenceIDs
        let ok: Bool
        if !media.isEmpty { ok = session.replaceMedia(of: clip, withFirstOf: media) }
        else if seqs.count == 1, let s = seqs.first { ok = session.replaceWithSequence(of: clip, with: s) }
        else { shell.statusBar.flash("Select one item in the Project panel to replace with.", seconds: 3); return }
        if let e = session.lastError, !ok || media.count > 1 { shell.statusBar.flash(e, seconds: 3) }
    }
}
