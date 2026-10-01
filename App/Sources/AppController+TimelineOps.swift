import AppKit
import SSCore
import SSEditorUI

/// Premiere-style timeline commands: clipboard, link, nudge, edge trims, markers. Kept apart from the main switch.
extension AppController {
    static func isTimelineOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .copy, .cut, .paste, .pasteInsert, .selectAll, .link, .toggleLinkedSelection, .markSelection,
             .nextMarker, .previousMarker, .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5,
             .trimBackward5, .trimForward5, .extendEdit:
            true
        default:
            false
        }
    }

    /// True when the command was handled here. Opt+Left/Right (bound to keyframe navigation) trims the selected
    /// edit by one frame when an edge is selected, like Premiere's Trim Backward/Forward.
    func executeTimelineOp(_ c: EditorCommand) -> Bool {
        let tv = panels.timelineView
        let edges = tv.interaction.edgeSelection
        func needEdit() { shell.statusBar.flash("Select an edit first (click a clip edge).") }
        switch c {
        case .copy: if !session.copySelection() { shell.statusBar.flash("Select clips to copy.") }
        case .cut:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to cut.") } else { session.cutSelection() }
        case .paste, .pasteInsert:
            if session.clipboard == nil { shell.statusBar.flash("Nothing to paste. Copy clips first.") }
            else { session.pasteClipboard(insert: c == .pasteInsert) }
        case .selectAll: session.selectAllClips()
        case .link: session.toggleLinkSelection()
        case .toggleLinkedSelection:
            tv.toolState.linkedSelection.toggle()
            shell.statusBar.flash(tv.toolState.linkedSelection ? "Linked Selection on" : "Linked Selection off", seconds: 2)
        case .markSelection: session.markSelection()
        case .nextMarker: session.goToNextMarker()
        case .previousMarker: session.goToPreviousMarker()
        case .nudgeLeft: session.nudgeSelection(frames: -1)
        case .nudgeRight: session.nudgeSelection(frames: 1)
        case .nudgeLeft5: session.nudgeSelection(frames: -5)
        case .nudgeRight5: session.nudgeSelection(frames: 5)
        case .trimBackward5: if let e = edges { session.trimEdges(e, frames: -5) } else { needEdit() }
        case .trimForward5: if let e = edges { session.trimEdges(e, frames: 5) } else { needEdit() }
        case .extendEdit: if let e = edges { session.extendEdit(e) } else { needEdit() }
        case .previousKeyframe:
            guard let e = edges else { return false }
            session.trimEdges(e, frames: -1)
        case .nextKeyframe:
            guard let e = edges else { return false }
            session.trimEdges(e, frames: 1)
        default: return false
        }
        return true
    }

    /// Delete / Shift+Delete on a selected gap closes it (ripple). False when no gap is selected.
    func deleteSelectedGap() -> Bool {
        guard let gap = panels.timelineView.interaction.gapSelection else { return false }
        session.closeGap(gap)
        return true
    }

    /// Menu state: check marks for Snap and Linked Selection.
    func validateTimelineOpItem(_ c: EditorCommand, _ item: NSMenuItem) {
        switch c {
        case .toggleSnapping: item.state = panels.timelineView.toolState.snapping ? .on : .off
        case .toggleLinkedSelection: item.state = panels.timelineView.toolState.linkedSelection ? .on : .off
        default: break
        }
    }
}
