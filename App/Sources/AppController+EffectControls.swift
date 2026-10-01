import AppKit
import SSCore
import SSEditorUI

/// Edit commands while Effect Controls has focus: copy, cut and paste work on keyframes and effects, never on timeline clips.
extension AppController {
    /// True when the command was handled here.
    func executeInEffectControls(_ c: EditorCommand) -> Bool {
        let m = panels.effectModel
        switch c {
        case .copy:
            if !m.copyFocused() { shell.statusBar.flash("Select keyframes or an effect to copy.") }
            return true
        case .cut:
            m.cutFocused()
            return true
        case .paste:
            if !m.pasteFocused() { shell.statusBar.flash("Nothing to paste here. Put the playhead inside the clip.") }
            return true
        default:
            return false
        }
    }

    /// nil = not an Effect Controls command, ask the normal validation.
    func validateInEffectControls(_ c: EditorCommand) -> Bool? {
        let m = panels.effectModel
        switch c {
        case .copy, .cut: return m.canCopyFocused
        case .paste: return m.canPasteFocused
        default: return nil
        }
    }
}
