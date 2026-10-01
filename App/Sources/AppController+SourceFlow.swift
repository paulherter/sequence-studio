import AppKit
import SQCore
import SQEditorUI

/// Commands of the Source / Project flow (poster frame, Hover Scrub, Find, Play Around, roll playback).
extension AppController {
    /// True when `c` was one of these and has been handled.
    func executeSourceFlowCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .playInToOutRoll:
            if focusedPanel == .sourceMonitor { panels.source.playInToOut(withRoll: true) }
            else { session.playInToOut(preroll: settings.preroll, postroll: settings.postroll) }
        case .playAround:
            if focusedPanel == .sourceMonitor { panels.source.playAround() }
            else { session.playAround(preroll: settings.preroll, postroll: settings.postroll) }
        case .setPosterFrame: showPanel(.project); panels.projectView.setPosterFrame(clear: false)
        case .clearPosterFrame: showPanel(.project); panels.projectView.setPosterFrame(clear: true)
        case .find: showPanel(.project); panels.projectView.showFind()
        case .toggleHoverScrub:
            settings.hoverScrub.toggle()
            settings.save()
            shell.statusBar.flash(settings.hoverScrub ? "Hover Scrub on" : "Hover Scrub off (hold Shift to scrub)", seconds: 2)
        case .markIn, .markOut:
            // Over a hovered Project thumbnail, I / O mark that clip's Source In / Out instead of the sequence.
            return focusedPanel == .project && panels.projectView.handleHoverMark(isIn: c == .markIn)
        default: return false
        }
        return true
    }
}
