import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// Clip > Beat Edits > Fit Music to Length…: finds the beat of the selected music clip, offers up to three versions.
    func requestFitMusic() {
        guard let clip = session.musicFitClip else { shell.statusBar.flash("Select one music clip at normal speed first."); return }
        guard let target = session.musicFitTarget(for: clip) else {
            shell.statusBar.flash("Mark In and Out, or place the clip before the sequence end."); return
        }
        guard let media = session.project.media(clip.media) else { return }
        shell.statusBar.flash("Finding the beat...", seconds: 30)
        let url = URL(fileURLWithPath: media.path)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let grid = await EditorSession.analyzeBeats(url: url) else { shell.statusBar.flash("No beat found.", seconds: 4); return }
            let versions = session.musicFitVersions(grid: grid, target: target)
            guard !versions.isEmpty else {
                shell.statusBar.flash("The clip already has that length, or too few bars to fit.", seconds: 4); return
            }
            MusicFitDialog.present(on: window, clipName: clip.name, target: target, versions: versions) { [weak self] v in
                guard let self, let v else { return }
                if session.applyMusicFit(v, to: clip.id) { shell.statusBar.flash("Music fitted to length.", seconds: 3) }
            }
        }
    }

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

    /// Clip > Add Speed Point: a point that changes nothing at the playhead (no default key). Drag it sideways on the
    /// speed band to make the span before it faster or slower; E / Shift+E ease it like any keyframe.
    func addSpeedPoint() {
        guard session.addSpeedPointAtPlayhead() else {
            shell.statusBar.flash("Select a video clip and put the playhead inside it, off an existing point.")
            return
        }
        let ids = Set(session.remappableSelection.map(\.id))
        panels.timelineView.setSpeedBand(panels.timelineView.speedBandClips.union(ids))
    }

    /// Clip > Remove Time Remapping: back to 100 % over the source the clip used.
    func removeTimeRemapping() {
        let ids = Set(session.retimableSelection.filter { $0.speedKeys != nil }.map(\.id))
        guard session.removeTimeRemapping() else { shell.statusBar.flash("The selected clips have no time remapping."); return }
        panels.timelineView.setSpeedBand(panels.timelineView.speedBandClips.subtracting(ids))
    }
}

extension AppController {
    /// Clip > Speed Ramp Presets: applies the preset to the selected video clips and shows the speed band so the ramp can be edited.
    func applySpeedPreset(_ preset: SpeedRampPreset, onBeat: Bool) {
        let ids = Set(session.remappableSelection.map(\.id))
        switch session.applySpeedPreset(preset, onBeat: onBeat) {
        case .noClip: shell.statusBar.flash("Select a video clip first.")
        case .noBeat: shell.statusBar.flash("No beat marker inside the clip. Run Markers on Beat on the music first.", seconds: 4)
        case .applied:
            panels.timelineView.setSpeedBand(panels.timelineView.speedBandClips.union(ids))
        }
    }

    /// Clip > Beat Edits > Cut to Beats / Snap to Beats on the selected clips.
    func requestBeatEdit(cut: Bool) {
        guard session.hasBeatMarkers else { shell.statusBar.flash("Run Markers on Beat on the music first.", seconds: 4); return }
        guard !session.selection.isEmpty else { shell.statusBar.flash("Select the clips to edit first."); return }
        guard let n = cut ? session.cutToBeats() : session.snapToBeats() else { return }      // a refused edit reports itself
        if cut { shell.statusBar.flash(n == 0 ? "No beat falls inside the selection." : "Cut at \(n) beat\(n == 1 ? "" : "s").", seconds: 3) }
        else { shell.statusBar.flash(n == 0 ? "The selected clips already end on beats." : "Snapped \(n) clip end\(n == 1 ? "" : "s") to beats.", seconds: 3) }
    }
}
