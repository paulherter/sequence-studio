import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// Clip > Speed/Duration (Cmd+R): sheet for the selected clips; one undo step.
    func requestSpeedDuration() {
        guard let model = session.speedDialogModel(), let tl = session.activeTimeline else {
            shell.statusBar.flash("Select a clip first.")
            return
        }
        let fd = tl.frameDuration
        let tc = Timecode(frameDuration: fd, dropFrame: fd == Time(1001, 30000) || fd == Time(1001, 60000))
        SpeedDurationSheet.present(on: window, model: model, timecode: tc) { [weak self] change in
            guard let self, let change else { return }
            session.applySpeed(change)
        }
    }

    /// Clip > Show Time Remapping: shows or hides the speed band on the selected video clips.
    func toggleTimeRemapping() {
        let ids = Set(session.remappableSelection.map(\.id))
        guard !ids.isEmpty else { shell.statusBar.flash("Select a video clip first."); return }
        let shown = panels.timelineView.speedBandClips
        panels.timelineView.setSpeedBand(ids.isSubset(of: shown) ? shown.subtracting(ids) : shown.union(ids))
    }

    /// Clip > Remove Time Remapping: back to 100 % over the source the clip used.
    func removeTimeRemapping() {
        let ids = Set(session.retimableSelection.filter { $0.speedKeys != nil }.map(\.id))
        guard session.removeTimeRemapping() else { shell.statusBar.flash("The selected clips have no time remapping."); return }
        panels.timelineView.setSpeedBand(panels.timelineView.speedBandClips.subtracting(ids))
    }
}
