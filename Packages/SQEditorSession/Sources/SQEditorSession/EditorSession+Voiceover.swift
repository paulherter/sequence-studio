import Foundation
import SQCore

extension EditorSession {
    /// Places a rendered voiceover (`media` already in the project, `duration` long) at `time` (default the playhead) on a free
    /// audio track with the Dialogue role, as one undo step. The new clip ends up selected. Nil when refused (`lastError` says why).
    @discardableResult
    public func placeVoiceover(media: MediaRef.ID, name: String, duration: Time, at time: Time? = nil) -> VoiceoverPlacement? {
        guard activeTimelineID != nil else { setError("Open a sequence first."); return nil }
        let start = time ?? playhead
        var placed: VoiceoverPlacement?
        guard attempt("Insert Voiceover", { t in placed = try t.placeVoiceover(media: media, name: name, duration: duration, at: start) }),
              let placed else { return nil }
        select(clips: [placed.clip])
        return placed
    }
}
