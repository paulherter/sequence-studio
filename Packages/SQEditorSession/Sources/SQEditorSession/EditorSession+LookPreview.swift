import Foundation
import SQCore
import SQPlayback
import SQText

extension EditorSession {
    /// Shows the Look on the selection in the Program monitor without applying it (hover over a Look tile). Display
    /// only: no undo step, no project change, no timeline rebuild. Nothing while the sequence plays. Nil clears it.
    /// Returns whether a preview is showing.
    @discardableResult
    public func previewLook(_ ref: LookRef?, store: LookStore = .shared) -> Bool {
        #if os(macOS)
        guard let ref, !isPlaying, let target = lookTarget, let look = look(ref, store: store) else {
            engine.setLookPreview(nil)
            return false
        }
        switch target {
        case .textClip, .graphicText:
            guard let (template, anims) = textContent(target), let stored = storedTextRef(target) else {
                engine.setLookPreview(nil)
                return false
            }
            let given = Self.givingLook(look, token: ref.token, to: template, animations: anims)
            guard let to = try? TextGenerator.makeRef(template: given.template, animations: given.animations) else {
                engine.setLookPreview(nil)
                return false
            }
            engine.setLookPreview(.text(container: stored.container, layer: stored.layer, from: stored.ref, to: to))
        case .captions:
            // What the click applies: the Look's style, its animation (also `.none`, which removes the captions' own) and its highlight.
            engine.setLookPreview(.captions(style: look.style, animation: look.animation, karaoke: look.karaoke))
        }
        return true
        #else
        return false   // shortcut: the monitor preview is Mac-only (SQPlayback `LookPreview`); upgrade with the Windows monitor.
        #endif
    }

    /// Removes any Look preview from the monitor.
    public func clearLookPreview() { engine.clearLookPreview() }
}
