import Foundation
import SQCore

extension EditorSession {
    /// Sets (or clears) an audio track's role (Dialogue / Music / SFX), one undo step. Playback and export give a track
    /// without an explicit preset its role's voiced preset.
    @discardableResult
    public func setTrackAudioRole(_ id: Track.ID, role: AudioTag?) -> Bool {
        guard let tr = activeTimeline?.tracks.first(where: { $0.id == id }), tr.kind == .audio, tr.audioRole != role else { return false }
        return attempt("Track Role") { t in
            guard let i = t.tracks.firstIndex(where: { $0.id == id }) else { return }
            t.tracks[i].audioRole = role
        }
    }
}
