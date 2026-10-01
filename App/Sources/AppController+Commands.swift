import AppKit
import SQCore
import SQEditorUI

/// Every `EditorCommand` that SQCore and the session already support. Others report "not available yet".
extension AppController {
    static func isSupported(_ c: EditorCommand) -> Bool {
        switch c {
        case .shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward, .playPause,
             .stepBackward, .stepForward, .stepBackward5, .stepForward5,
             .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd,
             .markIn, .markOut, .markClip, .goToIn, .goToOut, .clearInOut, .clearIn, .clearOut, .lift, .extract, .insert, .overwrite, .addMarker,
             .playInToOut, .toggleLoop, .exportFrame, .newBin, .matchFrame, .reverseMatchFrame,
             .tool, .addEdit, .addEditAllTracks, .rippleTrimPrevious, .rippleTrimNext,
             .delete, .rippleDelete, .toggleSnapping, .undo, .redo,
             .zoomIn, .zoomOut, .zoomFit, .focusPanel, .maximizePanel, .maximizeActivePanel, .resetLayout,
             .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter,
             .minimizeAllTracks, .expandAllTracks, .speedDuration,
             .importMedia, .newSequence, .save, .export, .audioGain, .toggleAudioScrubbing, .toggleCaptionsInMonitor:
            true
        case _ where isShellCommand(c):
            true
        default:
            Self.isTimelineOp(c)
        }
    }

    func execute(_ c: EditorCommand) {
        if ProcessInfo.processInfo.environment["SQ_KEYLOG"] == "1" { NSLog("SQKEY execute \(c) playing=\(session.isPlaying)") }
        // Editing text (a field or the timecode box): the standard commands go to the editor.
        if let tv = textResponder, forwardToText(c, tv) { return }
        if focusedPanel == .sourceMonitor, panels.source.handle(c) { return }
        if executeShellCommand(c) { return }
        if [.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus, executeInEffectControls(c) { return }
        // Timeline operations (clipboard, link, nudge, edge trims...); Effect Controls keeps its own keys while it has focus.
        let ecOwns = [.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus
        if Self.isTimelineOp(c) || c == .previousKeyframe || c == .nextKeyframe, !ecOwns, executeTimelineOp(c) { return }
        guard Self.isSupported(c) else {
            shell.statusBar.flash("\(c.title) is not available yet.")
            return
        }
        switch c {
        case .shuttleReverse: shuttle(.j)
        case .shuttleStop: shuttle(.k)
        case .shuttleSlowReverse: nudgeShuttle(forward: false)
        case .shuttleSlowForward: nudgeShuttle(forward: true)
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
        case .clearIn: session.clearIn()
        case .clearOut: session.clearOut()
        case .playInToOut: session.playInToOut()
        case .toggleLoop: session.toggleLoop(); panels.monitorModel.isLooping = session.bounds.loop
        case .exportFrame:
            if focusedPanel == .sourceMonitor { panels.source.exportFrame() } else { exportProgramFrame() }
        case .newBin: showPanel(.project); panels.projectView.newBin()
        case .matchFrame: panels.matchFrame()
        case .reverseMatchFrame: panels.reverseMatchFrame()
        case .insert: placeSelectedMedia(.insert)
        case .overwrite: placeSelectedMedia(.overwrite)
        case .addMarker:
            // M on a frame that already has a marker opens its dialog (Premiere).
            if let r = session.markAtPlayhead(), r.openEdit { panels.editMarker(r.id) }
        case .tool(let t): selectTool(t)
        case .addEdit: session.addEditAtPlayhead()
        case .addEditAllTracks: session.addEditAtPlayhead(allTracks: true)
        case .rippleTrimPrevious: session.rippleTrimToPlayhead(.head)
        case .rippleTrimNext: session.rippleTrimToPlayhead(.tail)
        case .delete, .rippleDelete:
            // Effect Controls owns Delete while it has focus: keys, then the selected effect. Never the timeline clips.
            if effectControlsHasFocus { panels.effectModel.deleteSelectionOrEffect() }
            else if deleteSelectedGap() { }
            else { session.deleteSelection(ripple: c == .rippleDelete) }
        case .toggleSnapping:
            panels.timelineView.toolState.snapping.toggle()
            shell.statusBar.flash(panels.timelineView.toolState.snapping ? "Snapping on" : "Snapping off", seconds: 2)
        case .speedDuration: requestSpeedDuration()
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
            if let p = panelUnderMouse() ?? focusedPanel { toggleMaximize(p) }
        case .importMedia:
            showPanel(.project)
            panels.projectView.runImportPanel()
        case .newSequence: requestNewSequence()
        case .save: Task { await saveDocument() }
        case .export: showExport()
        case .audioGain: requestAudioGain()
        case .toggleAudioScrubbing: toggleAudioScrubbing()
        case .toggleCaptionsInMonitor: toggleCaptionsInMonitor()
        default: break
        }
    }

    private func nudgeShuttle(forward: Bool) {
        if focusedPanel == .sourceMonitor { panels.source.nudge(forward: forward); return }
        session.apply(shuttle: .setRate(session.engine.rate.nudged(forward: forward)))
    }

    private func exportProgramFrame() {
        session.stopPlayback()
        let name = (session.activeTimeline?.name ?? "Frame") + ".png"
        FrameExport.run(texture: session.engine.lastRenderedTexture, suggestedName: name, on: window,
                        status: { [weak self] in self?.shell.statusBar.flash($0) })
    }

    private func shuttle(_ key: ShuttleKey) {
        if focusedPanel == .sourceMonitor { panels.source.press(key); return }
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
        case .rateStretch: mapped = .rateStretch
        case .zoom: mapped = nil
        }
        // The Program monitor follows: Hand pans the view, Type places text, everything else is the selection behaviour.
        panels.setMonitorTool(t == .hand ? .hand : t == .type ? .type : .select)
        guard let mapped else { shell.statusBar.flash("\(EditorCommand.tool(t).title) is not available yet."); return }
        panels.timelineView.toolState.selectBackward = t == .trackBackward
        panels.timelineView.toolState.tool = mapped
        shell.statusBar.flash(EditorCommand.tool(t).title, seconds: 2)
    }

    /// Insert / Overwrite the media selected in the Project panel at the playhead.
    private func placeSelectedMedia(_ mode: ThreePointMode) {
        // Premiere: the clip loaded in the Source monitor (its In/Out, the targeted tracks) ...
        if panels.source.mediaID != nil, focusedPanel != .project { panels.source.edit(mode); return }
        // ... and without one, what is selected in the Project panel.
        let ids = panels.projectView.selectedMediaIDs
        guard !ids.isEmpty else { shell.statusBar.flash("Open a clip in the Source monitor first (double-click it in the Project panel)."); return }
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
