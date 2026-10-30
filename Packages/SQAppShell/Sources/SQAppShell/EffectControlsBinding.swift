import Foundation
import SQEditorSession
import SQInspectorUI

/// Connects an Effect Controls model to the session (edits, gestures, scrubs, sync on change): what the Program monitor's
/// on-picture overlay (transform handles, masks) and the Effect Controls panel (`InspectorHost`) both need.
public enum EffectControlsBinding {
    @MainActor
    public static func connect(_ model: EffectControlsModel, to session: EditorSession) {
        model.onEdit = { [weak session] clip, name, coalescing in
            session?.replaceDisplayedClip(clip, name: name, continuesGesture: coalescing)
        }
        model.onEditMany = { [weak session] clips, name, coalescing in
            session?.replaceDisplayedClips(clips, name: name, continuesGesture: coalescing)
        }
        model.onAudioEdit = { [weak session] clip, name, coalescing in
            session?.replaceClip(clip, name: name, continuesGesture: coalescing)
        }
        model.onGestureEnded = { [weak session] in session?.endGesture() }
        model.onEffectCopied = { [weak session] e in session?.effectClipboard = e }
        model.onBuiltInCopied = { [weak session] s, c in session?.copyBuiltIn(s, of: c) }
        model.canPasteBuiltIn = { [weak session] in session?.canPasteAttributes ?? false }
        model.onPasteBuiltIn = { [weak session] in session?.pasteAttributes() ?? false }
        model.onSeek = { [weak session] t in session?.seek(to: t) }
        model.onPointerDown = { [weak session] in session?.stopPlayback() }
        model.onScrubBegan = { [weak session] in session?.beginScrub() }
        model.onScrub = { [weak session] t in session?.scrub(to: t) }
        model.onScrubEnded = { [weak session] in session?.endScrub() }
        model.timeline = { [weak session] in session?.activeTimeline }
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak model, weak session] change in
            previous?(change)
            guard let model, let session else { return }
            model.sync(with: session, change: change)
        }
        model.sync(with: session, change: [.project, .selection, .playhead])
    }
}
