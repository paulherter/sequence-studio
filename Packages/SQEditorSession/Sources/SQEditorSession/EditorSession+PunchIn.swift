import Foundation
import SQCore

/// W8.2 Punch-in toggle (SQCore PunchIn.swift): one undo step for all affected clips.
extension EditorSession {
    /// Punches the selected (or playhead) video clips in, or out when all already are. Returns whether anything changed.
    @discardableResult
    public func togglePunchIn() -> Bool {
        guard let t = activeTimeline else { return false }
        let clips = commandClips(kind: .video)
        guard !clips.isEmpty else { return false }
        let ids = clips.map(\.id)
        let out = clips.allSatisfy { t.isPunchedIn($0) }
        return attempt(out ? "Punch Out" : "Punch In") { tl in try tl.togglePunchIn(ids) }
    }

    public var punchInEnabled: Bool { !commandClips(kind: .video).isEmpty }
}
