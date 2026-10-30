import AppKit
import SQCore
import SQEditorUI

/// Right-click on a track header (Premiere: Add Track, Delete Track, Rename).
extension EditorPanels {
    func trackHeaderItems(for id: Track.ID) -> [SQMenuItem]? {
        guard let track = session.activeTimeline?.track(id) else { return nil }
        return TimelineSideMenus.trackHeader(
            track: track,
            addVideo: { [weak self] in self?.session.addTrack(.video) },
            addAudio: { [weak self] in self?.session.addTrack(.audio) },
            delete: { [weak self] in self?.session.deleteTrack(id) },
            rename: { [weak self] in self?.renameTrack(track) },
            moveUp: { [weak self] in self?.session.moveTrack(id, up: true) },
            moveDown: { [weak self] in self?.session.moveTrack(id, up: false) },
            mix: { [weak self] in self?.presentTrackMix(track) },
            toggleDucking: { [weak self] in self?.session.setTrackExcludedFromLiveDucking(id, !track.isExcludedFromLiveDucking) },
            sequenceVolume: { [weak self] in self?.presentSequenceVolume() },
            selectAll: { [weak self] in self?.session.selectAllClips(on: id) },
            toggle: { [weak self] t in self?.timelineView.onTrackToggle?(id, t) })
    }

    func renameTrack(_ track: Track) {
        guard let window = timelineView.window else { return }
        let alert = SQDialog()
        alert.messageText = "Rename Track"
        let field = SQDialog.makeField(width: 260)
        field.stringValue = track.name
        field.placeholderString = track.kind == .video ? "Video" : "Audio"
        alert.accessoryView = field
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .first { self?.session.renameTrack(track.id, to: field.stringValue) } }
        }
    }
}
