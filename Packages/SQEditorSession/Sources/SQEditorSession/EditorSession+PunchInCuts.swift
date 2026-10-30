import Foundation
import SQCore

/// "Punch In Cuts" (SQCore PunchInCuts.swift): zoom levels alternating or cycling over consecutive shots.
extension EditorSession {
    /// The shots the command works on: the selected video clips when two or more are selected, else every video clip
    /// of the targeted video track (the first video track when none is targeted).
    func punchInCutsClips() -> [Clip] {
        guard let t = activeTimeline else { return [] }
        let selected = t.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { selection.contains($0.id) && !$0.isGenerator }
        if selected.count >= 2 { return selected }
        let videos = t.tracks.filter { $0.kind == .video }
        guard let track = videos.first(where: \.isTargeted) ?? videos.first else { return [] }
        return track.clips.filter { $0.isEnabled && !$0.isGenerator }
    }

    public var punchInCutsEnabled: Bool { punchInCutsClips().count >= 2 }

    /// Applies the pattern to the shots (one undo step). Returns whether anything changed.
    @discardableResult
    public func punchInCuts(_ options: PunchInCutsOptions) -> Bool {
        let ids = punchInCutsClips().map(\.id)
        guard ids.count >= 2 else { setError("Select two or more video clips, or target a video track with several shots."); return false }
        return attempt("Punch In Cuts") { _ = try $0.punchInCuts(ids, options) }
    }
}
