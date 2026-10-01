import AppKit
import SQCore
import SQEditorUI

/// Premiere-style timeline commands: clipboard, link, nudge, edge trims, markers. Kept apart from the main switch.
extension AppController {
    static func isTimelineOp(_ c: EditorCommand) -> Bool { CommandSupport.isTimelineOp(c) }

    /// True when the command was handled here.
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
        case .deselectAll: session.select(clips: [], captions: [])
        case .selectClipAtPlayhead: session.selectClipAtPlayhead()
        case .nextEditPointAnyTrack: session.goToEditPointOnAnyTrack(forward: true)
        case .previousEditPointAnyTrack: session.goToEditPointOnAnyTrack(forward: false)
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
        case .rollTrimPrevious: session.trimToPlayhead(.head, mode: .roll)
        case .rollTrimNext: session.trimToPlayhead(.tail, mode: .roll)
        case .trimPrevious: session.trimToPlayhead(.head, mode: .plain)
        case .trimNext: session.trimToPlayhead(.tail, mode: .plain)
        case .enableClip:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to enable or disable.") } else { session.toggleEnabledSelection() }
        case .duplicate:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to duplicate.") } else { session.duplicateSelection() }
        case .toggleTrimType: if !tv.cycleTrimType() { needEdit() }
        case .moveSelectionUp, .moveSelectionDown:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to move.") }
            else if !session.moveSelectionLane(up: c == .moveSelectionUp) { shell.statusBar.flash("The clips cannot go further \(c == .moveSelectionUp ? "up" : "down").") }
        case .trimBackward: if let e = edges { session.trimEdges(e, frames: -1) } else { needEdit() }
        case .trimForward: if let e = edges { session.trimEdges(e, frames: 1) } else { needEdit() }
        default: return false
        }
        return true
    }

    /// Hold-S during a clip, edge, marker or playhead drag flips snapping until the key comes up (Premiere's momentary
    /// snap). True when the event was used. Outside a drag S is the plain Snap toggle.
    func handleSnapHold(_ ke: KeyEvent) -> Bool {
        guard ke.key == .char("s"), ke.modifiers.isEmpty, let tv = panels?.timelineView else { return false }
        switch ke.phase {
        case .down:
            guard tv.isDragging else { return false }
            tv.setSnapInverted(true)
            return true
        case .up:
            guard tv.interaction.snapInverted else { return false }
            tv.setSnapInverted(false)
            return true
        }
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
        case .link: item.title = session.linkMenuState.unlink ? "Unlink" : "Link"
        case .toggleSnapping: item.state = panels.timelineView.toolState.snapping ? .on : .off
        case .toggleLinkedSelection: item.state = panels.timelineView.toolState.linkedSelection ? .on : .off
        case .toggleCaptionsInMonitor: item.state = session.engine.showsCaptions ? .on : .off
        default: break
        }
    }
}
