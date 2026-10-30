import AppKit
import SQCore
import SQEditorUI
import SQUIKit

extension AppController {
    /// Clip > Replace and Fit > Replace at Playhead / from Start / from End / with Retime (Fast Cut): the one selected
    /// main-track clip plays the clip open in the Source monitor. A clip too short for the old one is not refused;
    /// the status line says so.
    func replaceClipWithMode(_ mode: ReplaceMode) {
        guard let media = panels.source.mediaID else {
            shell.statusBar.flash("Open a clip in the Source monitor first (double-click it in the Project panel).", seconds: 3); return
        }
        guard session.selection.count == 1, let clip = session.selection.first else {
            shell.statusBar.flash("Select one clip in the timeline to replace.", seconds: 3); return
        }
        panels.source.pause()
        session.replaceOnMainTrack(clip, withMedia: media, mode: mode, sourceAnchor: panels.source.currentTime)
        if let e = session.lastError { shell.statusBar.flash(e, seconds: 4) }
    }

    /// Menu enabling: a Fast Cut sequence, a Source clip and one selected clip.
    var replaceModesEnabled: Bool {
        session.activeTimeline?.isFastCut == true && panels?.source.mediaID != nil && session.selection.count == 1
    }
}
