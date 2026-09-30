import AppKit
import SSCore
import SSEditorUI

/// Every `EditorCommand` that SSCore and the session already support. Others report "not available yet".
extension AppController {
    static func isSupported(_ c: EditorCommand) -> Bool {
        switch c {
        case .shuttleReverse, .shuttleStop, .shuttleForward, .playPause,
             .stepBackward, .stepForward, .stepBackward5, .stepForward5,
             .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd,
             .markIn, .markOut, .goToIn, .goToOut, .clearInOut, .lift, .extract, .insert, .overwrite, .addMarker,
             .tool, .addEdit, .addEditAllTracks, .rippleTrimPrevious, .rippleTrimNext,
             .delete, .rippleDelete, .toggleSnapping, .undo, .redo,
             .zoomIn, .zoomOut, .zoomFit, .focusPanel, .maximizePanel,
             .importMedia, .newSequence, .save, .export:
            true
        default:
            false
        }
    }

    func execute(_ c: EditorCommand) {
        // Editing text (a field or the timecode box): the standard commands go to the editor.
        if let tv = textResponder, forwardToText(c, tv) { return }
        guard Self.isSupported(c) else {
            shell.statusBar.flash("\(c.title) is not available yet.")
            return
        }
        switch c {
        case .shuttleReverse: shuttle(.j)
        case .shuttleStop: shuttle(.k)
        case .shuttleForward: shuttle(.l)
        case .playPause: session.playPause()
        case .stepBackward: session.stepFrames(-1)
        case .stepForward: session.stepFrames(1)
        case .stepBackward5: session.stepFrames(-5)
        case .stepForward5: session.stepFrames(5)
        case .previousEditPoint: session.goToPreviousEditPoint()
        case .nextEditPoint: session.goToNextEditPoint()
        case .goToStart: session.goToStart()
        case .goToEnd: session.goToEnd()
        case .markIn: session.markIn()
        case .markOut: session.markOut()
        case .goToIn: session.goToIn()
        case .goToOut: session.goToOut()
        case .clearInOut: session.clearInOut()
        case .lift: session.liftRange()
        case .extract: session.extractRange()
        case .insert: placeSelectedMedia(.insert)
        case .overwrite: placeSelectedMedia(.overwrite)
        case .addMarker: session.addMarkerAtPlayhead()
        case .tool(let t): selectTool(t)
        case .addEdit: session.addEditAtPlayhead()
        case .addEditAllTracks: session.addEditAtPlayhead(allTracks: true)
        case .rippleTrimPrevious: session.rippleTrimToPlayhead(.head)
        case .rippleTrimNext: session.rippleTrimToPlayhead(.tail)
        case .delete: session.deleteSelection(ripple: false)
        case .rippleDelete: session.deleteSelection(ripple: true)
        case .toggleSnapping:
            panels.timelineView.toolState.snapping.toggle()
            shell.statusBar.flash(panels.timelineView.toolState.snapping ? "Snapping on" : "Snapping off", seconds: 2)
        case .undo: session.undo()
        case .redo: session.redo()
        case .zoomIn: panels.timelineView.zoomIn()
        case .zoomOut: panels.timelineView.zoomOut()
        case .zoomFit: panels.timelineView.zoomToFit()
        case .focusPanel(let p): showPanel(p)
        case .maximizePanel:
            if let p = focusedPanel { maximizedPanel = maximizedPanel == p ? nil : p; applyWorkspace() }
        case .importMedia:
            showPanel(.project)
            panels.projectView.runImportPanel()
        case .newSequence: session.addSequence()
        case .save: Task { await saveDocument() }
        case .export: showExport()
        default: break
        }
    }

    private func shuttle(_ key: ShuttleKey) {
        session.apply(shuttle: menuShuttle.press(key))
        _ = menuShuttle.release(key)
    }

    private func selectTool(_ t: EditorTool) {
        let mapped: TimelineTool?
        switch t {
        case .selection: mapped = .selection
        case .trackForward, .trackBackward: mapped = .trackSelectForward
        case .ripple: mapped = .rippleEdit
        case .rolling: mapped = .rollEdit
        case .slip: mapped = .slip
        case .slide: mapped = .slide
        case .razor: mapped = .razor
        case .hand: mapped = .hand
        case .zoom, .type: mapped = nil
        }
        guard let mapped else { shell.statusBar.flash("\(EditorCommand.tool(t).title) is not available yet."); return }
        panels.timelineView.toolState.tool = mapped
        shell.statusBar.flash(EditorCommand.tool(t).title, seconds: 2)
    }

    /// Insert / Overwrite the media selected in the Project panel at the playhead.
    private func placeSelectedMedia(_ mode: ThreePointMode) {
        let ids = panels.projectView.selectedMediaIDs
        guard !ids.isEmpty else { shell.statusBar.flash("Select media in the Project panel first."); return }
        session.placeMedia(ids, mode: mode)
    }

    /// Shows a panel (unhiding it and selecting its tab) and gives it keyboard focus.
    func showPanel(_ p: PanelID) {
        if maximizedPanel != nil && maximizedPanel != p { maximizedPanel = nil }
        mutateWorkspace { $0.show(p) }
        focusedPanel = p
        if p == .timeline { window.makeFirstResponder(panels.timelineView) }
    }

    func requestNest() {
        guard !session.selection.isEmpty else { return }
        NestSheet.present(on: window, existingNames: session.project.timelines.map(\.name)) { [weak self] name in
            guard let self, let name else { return }
            session.nestSelection(name: name)
        }
    }

    private func forwardToText(_ c: EditorCommand, _ tv: NSTextView) -> Bool {
        switch c {
        case .undo: tv.undoManager?.undo(); return true
        case .redo: tv.undoManager?.redo(); return true
        case .cut: tv.cut(nil); return true
        case .copy: tv.copy(nil); return true
        case .paste: tv.paste(nil); return true
        case .delete, .deleteProjectItems: tv.deleteBackward(nil); return true
        default: return false
        }
    }
}
