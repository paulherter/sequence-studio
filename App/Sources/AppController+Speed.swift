import AppKit
import SSCore
import SSEditorUI

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
}
