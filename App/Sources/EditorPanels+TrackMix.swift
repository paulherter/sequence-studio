import AppKit
import SQCore
import SQEditorUI

/// Right-click on an audio track header: Volume and Pan… (fader and constant-power pan, one undo step).
extension EditorPanels {
    func presentTrackMix(_ track: Track) {
        guard let window = timelineView.window else { return }
        let name = track.name.isEmpty ? "Audio" : track.name
        TrackMixDialog.present(on: window, trackName: name, volumeDB: track.volumeDB, pan: track.pan) { [weak self] db, pan in
            self?.session.setTrackMix(track.id, volumeDB: db, pan: pan)
        }
    }
}
