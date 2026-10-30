import SQCore
import SQEditorSession
import SQEditorUI

/// "Go to Next Weak Tracking" (Option+Shift+M, Markers menu): the playhead jumps to where the next weak stretch of a
/// tracked Magic mask begins (the portable `MagicTrackHealthCache`, shared with the shared window).
extension EditorPanels {
    typealias WeakTrackingJump = MagicTrackHealthCache.Jump

    func nextWeakTrackingStart(after t: Time) -> WeakTrackingJump { magicHealth.nextWeakStart(after: t, in: session.activeTimeline) }
}
