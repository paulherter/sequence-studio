import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI

extension TimelinePanel {
    /// The Mac `EditorPanels` wiring a host gives every timeline: heights kept per sequence (`TrackHeightStore`) and the
    /// live duck curve from the project's ducking setting.
    /// `silences`: the host's dialogue pause provider (`WaveformSilences` fed by its waveform reads); nil = the duck holds
    /// through pauses until the host passes one (the panel never decodes audio itself).
    @MainActor public mutating func connectHostDefaults(session: EditorSession, silences: (any DialogueSilenceProvider)? = nil,
                                                        defaults: UserDefaults = .standard) {
        heightStore = TrackHeightStore(defaults: defaults)
        duckCurve = DuckCurveSource(ducking: { [weak session] in LiveDucking.resolved(project: session?.project.liveDucking) },
                                    silences: silences)
    }

    /// The host's key-up: S ends Hold-S (the Mac `keyUp` → `setSnapInverted(false)`), ` ends the keep-attached hold
    /// whatever mode the sequence is in by then.
    public mutating func keyUp(_ k: InputKey) -> [TimelineAction] {
        switch k {
        case .character("s"): return setSnapInverted(false)
        case .character("`"):
            // A tap without an edit in Fast Cut maximizes the panel under the pointer (the Mac `handleKeepAttachedHold`);
            // in Normal the key-down already ran Maximize Panel through the key map.
            let tapped = toolState.keepAttached && !keepAttachedUsed && gesture == nil && timeline.isFastCut
            keepAttachedUsed = false
            return holdKeepAttached(false) + (tapped ? [.command(.maximizePanel)] : [])
        case .character(let ch):
            // A tool key held past the threshold was a temporary tool: back to the one from before (the Mac key monitor).
            guard let back = toolHold.release(.char(Character(ch.lowercased())), at: clock()) else { return [] }
            toolState.select(back)
            return []
        default: return []
        }
    }

    /// The window lost the keyboard: a held tool key's key-up will not come, so the hold ends as if it came now (the Mac
    /// `releaseHeldKeys`). Also ends Hold-S and the keep-attached hold, whose key-ups are lost the same way.
    public mutating func releaseHeldKeys() -> [TimelineAction] {
        if let back = toolHold.releaseAll(at: clock()) { toolState.select(back) }
        keepAttachedUsed = false
        return setSnapInverted(false) + holdKeepAttached(false)
    }

    /// The Mac `handleKeepAttachedHold`: while ` is held, a Fast Cut move or delete leaves the attached clips on their
    /// frame; a drag in progress is replayed so its ghost shows the change at once. The host mirrors
    /// `toolState.keepAttached` into `EditorSession.keepAttachedHeld` for menu and key deletes.
    public mutating func holdKeepAttached(_ on: Bool) -> [TimelineAction] {
        guard toolState.keepAttached != on else { return [] }
        toolState.keepAttached = on
        guard gesture != nil, let p = lastDrag else { return [] }
        return mouseDragged(p)
    }
}
