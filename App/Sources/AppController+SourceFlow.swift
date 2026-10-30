import AppKit
import SQCore
import SQEditorSession
import SQEditorUI
import SQUIKit

/// Commands of the Source / Project flow (poster frame, Hover Scrub, Find, Play Around, roll playback).
extension AppController {
    /// True when `c` was one of these and has been handled.
    func executeSourceFlowCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .playInToOutRoll:
            if CommandRouting.sourceMonitorOffered(focus: focusedPanel) { panels.source.playInToOut(withRoll: true) }
            else { session.playInToOut(preroll: settings.preroll, postroll: settings.postroll) }
        case .playAround:
            if CommandRouting.sourceMonitorOffered(focus: focusedPanel) { panels.source.playAround() }
            else { session.playAround(preroll: settings.preroll, postroll: settings.postroll) }
        case .setPosterFrame: showPanel(.project); panels.projectView.setPosterFrame(clear: false)
        case .clearPosterFrame: showPanel(.project); panels.projectView.setPosterFrame(clear: true)
        case .find:
            // With the timeline focused, Find searches the captions (find and replace on the caption track).
            if CommandRouting.findTarget(focus: focusedPanel) == .captionsThenProject, panels.timelineView.showCaptionSearch() { break }
            showPanel(.project); panels.projectView.showFind()
        case .projectListView: panels.projectView.setViewMode(.list)
        case .projectIconView: panels.projectView.setViewMode(.icons)
        case .projectThumbnailSmaller, .projectThumbnailLarger: panels.projectView.stepThumbnailSize(larger: c == .projectThumbnailLarger)
        case .uiScaleLarger, .uiScaleSmaller, .uiScaleReset:
            switch c {
            case .uiScaleLarger: UIScale.increase()
            case .uiScaleSmaller: UIScale.decrease()
            default: UIScale.reset()
            }
            let pct = Int((UIScale.current * 100).rounded())
            _ = SQToast.show("Interface size \(pct) %", in: window?.contentView)
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
