import AppKit
import SQCore
import SQEditorUI

/// Edit commands while Effect Controls has focus: copy, cut and paste work on keyframes and effects, never on timeline clips.
extension AppController {
    /// Effect Controls takes the Edit command only when it really has the keyboard (see `EffectControlsEditRouting`).
    func effectControlsTakes(_ c: EditorCommand) -> Bool {
        let m = panels.effectModel
        var inside = false
        var v = window?.firstResponder as? NSView
        while let x = v { if x === panels.effectView { inside = true }; v = x.superview }
        let can: Bool
        switch c {
        case .copy: can = m.canCopyFocused
        case .cut: can = m.canCutFocused
        case .paste: can = m.canPasteFocused
        default: can = true
        }
        return EffectControlsEditRouting.effectControlsHandles(responderInside: inside, panelFocused: focusedPanel == .effectControls, canAct: can)
    }

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
        case .copy: return m.canCopyFocused
        case .cut: return m.canCutFocused
        case .paste: return m.canPasteFocused
        default: return nil
        }
    }
}
