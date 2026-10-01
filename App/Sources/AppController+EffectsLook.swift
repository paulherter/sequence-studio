import AppKit
import SQCore
import SQEditorUI

/// Clip look commands: Fade In / Fade Out (video), Frame Hold, Paste Attributes. Kept apart from the main switch.
extension AppController {
    static func isEffectsLookOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .pasteAttributes: true
        default: false
        }
    }

    /// True when the command was handled here.
    func executeEffectsLookOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .videoFadeIn:
            if !session.fadeVideo(.head) { shell.statusBar.flash("Select a video clip to fade in.") }
        case .videoFadeOut:
            if !session.fadeVideo(.tail) { shell.statusBar.flash("Select a video clip to fade out.") }
        case .addFrameHold:
            if !session.addFrameHold() { shell.statusBar.flash("Put the playhead on a video clip to hold its frame.") }
        case .insertFrameHold:
            if !session.insertFrameHold() { shell.statusBar.flash("Put the playhead on a video clip to insert a frame hold.") }
        case .pasteAttributes:
            if session.clipboard == nil { shell.statusBar.flash("Copy a clip first, then select the clips to paste its attributes onto.") }
            else if !session.pasteAttributes() { shell.statusBar.flash("Select clips of the same kind as the copied clip.") }
        default: return false
        }
        return true
    }

    /// Menu enabling for these commands; nil = not one of them.
    func effectsLookEnabled(_ c: EditorCommand) -> Bool? {
        switch c {
        case .videoFadeIn, .videoFadeOut: return !session.commandClipsForMenu(kind: .video).isEmpty
        case .addFrameHold, .insertFrameHold:
            return session.commandClipsForMenu(kind: .video).contains { $0.timeline.contains(session.playhead) }
        case .pasteAttributes: return session.canPasteAttributes
        default: return nil
        }
    }
}
