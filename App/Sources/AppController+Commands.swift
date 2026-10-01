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
             .markIn, .markOut, .markClip, .goToIn, .goToOut, .clearInOut, .lift, .extract, .insert, .overwrite, .addMarker,
             .tool, .addEdit, .addEditAllTracks, .rippleTrimPrevious, .rippleTrimNext,
             .delete, .rippleDelete, .toggleSnapping, .undo, .redo,
             .zoomIn, .zoomOut, .zoomFit, .focusPanel, .maximizePanel,
             .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter,
             .minimizeAllTracks, .expandAllTracks,
             .importMedia, .newSequence, .save, .export:
            true
        default:
            false
        }
    }

    func execute(_ c: EditorCommand) {
        if ProcessInfo.processInfo.environment["SS_KEYLOG"] == "1" { NSLog("SSKEY execute \(c) playing=\(session.isPlaying)") }
        // Editing text (a field or the timecode box): the standard commands go to the editor.
        if let tv = textResponder, forwardToText(c, tv) { return }
        if [.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus, executeInEffectControls(c) { return }
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
        case .markClip: session.markClip()
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
        case .delete, .rippleDelete:
            // Effect Controls owns Delete while it has focus: keys, then the selected effect. Never the timeline clips.
            if effectControlsHasFocus { panels.effectModel.deleteSelectionOrEffect() }
            else { session.deleteSelection(ripple: c == .rippleDelete) }
        case .toggleSnapping:
            panels.timelineView.toolState.snapping.toggle()
            shell.statusBar.flash(panels.timelineView.toolState.snapping ? "Snapping on" : "Snapping off", seconds: 2)
        case .undo: session.undo()
        case .redo: session.redo()
        case .videoTracksTaller: panels.timelineView.sizeTracks(.video, direction: 1)
        case .videoTracksShorter: panels.timelineView.sizeTracks(.video, direction: -1)
        case .audioTracksTaller: panels.timelineView.sizeTracks(.audio, direction: 1)
        case .audioTracksShorter: panels.timelineView.sizeTracks(.audio, direction: -1)
        case .minimizeAllTracks: panels.timelineView.minimizeAllTracks()
        case .expandAllTracks: panels.timelineView.expandAllTracks()
        case .zoomIn: if effectControlsHasFocus { panels.effectModel.zoomIn() } else { panels.timelineView.zoomIn() }
        case .zoomOut: if effectControlsHasFocus { panels.effectModel.zoomOut() } else { panels.timelineView.zoomOut() }
        case .zoomFit: if effectControlsHasFocus { panels.effectModel.zoomToFit() } else { panels.timelineView.zoomToFit() }
        case .focusPanel(let p): showPanel(p)
        case .maximizePanel:
            if let p = focusedPanel { maximizedPanel = maximizedPanel == p ? nil : p; applyWorkspace() }
        case .importMedia:
            showPanel(.project)
            panels.projectView.runImportPanel()
        case .newSequence: requestNewSequence()
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
        case .type: mapped = .type
        case .zoom: mapped = nil
        }
        // The Program monitor follows: Hand pans the view, Type places text, everything else is the selection behaviour.
        panels.setMonitorTool(t == .hand ? .hand : t == .type ? .type : .select)
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

    func requestNewSequence() {
        let base = session.activeTimeline?.format ?? SequenceFormat(frameDuration: Time(1001, 30000))
        let n = session.project.timelines.count + 1
        SequenceSettingsSheet.present(on: window, format: base, name: String(format: "Sequence %02d", n)) { [weak self] name, format in
            self?.session.addSequence(name: name, format: format)
        }
    }

    @objc func showSequenceSettings(_ sender: Any?) {
        guard let f = session.activeTimeline?.format else { return }
        SequenceSettingsSheet.present(on: window, format: f, name: nil) { [weak self] _, format in
            self?.session.setSequenceFormat(format)
        }
    }

    func requestNest() {
        guard !session.selection.isEmpty else { return }
        NestSheet.present(on: window, existingNames: session.project.timelines.map(\.name)) { [weak self] name in
            guard let self, let name else { return }
            session.nestSelection(name: name)
        }
    }

    /// Effect Controls is the focused panel, or something inside it is first responder.
    var effectControlsHasFocus: Bool {
        if focusedPanel == .effectControls { return true }
        var v = window?.firstResponder as? NSView
        while let x = v { if x === panels.effectView { return true }; v = x.superview }
        return false
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
