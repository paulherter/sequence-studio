import AppKit
import SQCore
import SQEditorSession
import SQEditorUI
import SQMonitorUI

extension AppController {
    func execute(_ c: EditorCommand) {
        if ProcessInfo.processInfo.environment["SQ_KEYLOG"] == "1" { NSLog("SQKEY execute \(c) playing=\(session.isPlaying)") }
        // A command works on the selection as it is at the playhead: a follow evaluation deferred by a run of frame steps,
        // or not made at all while playing, is applied first. Frame steps keep deferring; the shuttle keys read no
        // selection and must not reload panels during playback.
        if ![.stepBackward, .stepForward, .stepBackward5, .stepForward5, .stepBackward10, .stepForward10, .shuttleReverse, .shuttleStop, .shuttleForward,
             .shuttleSlowReverse, .shuttleSlowForward].contains(c) { session.flushFollowSelection() }
        // Editing text (a field or the timecode box): the standard commands go to the editor.
        if let tv = textResponder, forwardToText(c, tv) { return }
        if CommandRouting.sourceMonitorOffered(focus: focusedPanel), panels.source.handle(c) { return }
        let override = CommandRouting.focusOverride(c, focus: focusedPanel)
        if override == .libraryPreviewPlay, panels.libraryView.handlePlayPause() { return }   // Space plays the previewed Library item
        if executeSourceFlowCommand(c) { return }
        if executeMarkerListCommand(c) { return }
        if executeMonitorViewCommand(c) { return }
        if executeTrimModeCommand(c) { return }
        // Keyframes selected in Effect Controls: the nudge keys (, . and Shift) move them frame by frame instead of the clips.
        // Same for keys picked on the timeline key lane (the timeline keeps focus).
        let laneKeys = focusedPanel == .timeline && panels.timelineView.keyLaneKeysActive
        if let n = c.keyframeNudgeFrames, effectControlsHasFocus || laneKeys, !panels.effectModel.selection.isEmpty {
            if panels.effectModel.nudgeSelectedKeys(frames: n) == .zero { shell.statusBar.flash("Keyframes cannot move further.") }
            return
        }
        // Color panel focused: Cmd-C / Cmd-V copy and paste the whole grade (to every selected clip).
        if override == .copyGrade || override == .pasteGrade {
            let ok = override == .copyGrade ? panels.colorView.copyGrade() : panels.colorView.pasteGrade()
            if !ok { shell.statusBar.flash(c == .copy ? "Select a clip to copy its grade." : "Copy a grade first, then select clips.") }
            return
        }
        if let verb = EditVerb(command: c), executeFocusedEdit(c, verb) { return }
        if executeShellCommand(c) { return }
        if [.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus, executeInEffectControls(c) { return }
        // Timeline operations (clipboard, link, nudge, edge trims...); Effect Controls keeps its own keys while it has focus.
        let ecOwns = [.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus
        if CommandRouting.isTimelineOp(c), !ecOwns, executeTimelineOp(c) { return }
        if CommandRouting.isEffectsLookOp(c), executeEffectsLookOp(c) { return }
        guard CommandRouting.isSupported(c) else {
            shell.statusBar.flash(SQL10n.format("%@ is not available yet.", SQL10n.string(c.title)))
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
        case .stepBackward5: session.stepFrames(-10)
        case .stepForward5: session.stepFrames(10)
        case .stepBackward10: session.stepFrames(-10)
        case .stepForward10: session.stepFrames(10)
        case .playToOut: if !session.playToOut() { shell.statusBar.flash("Move the playhead before the Out point first.") }
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
        case .bleep: session.bleepRange()
        case .newTone:
            if let window {
                ToneDialog.present(on: window, spec: .default, confirm: "Add") { [weak self] spec in self?.session.addToneClip(spec) }
            }
        case .toneSettings:
            if let sel = session.selectedTone, let window {
                ToneDialog.present(on: window, spec: sel.spec) { [weak self] spec in self?.session.setTone(sel.id, spec) }
            } else { shell.statusBar.flash("Select a tone clip first.") }
        case .clearIn: session.clearIn()
        case .clearOut: session.clearOut()
        case .playInToOut: session.playInToOut()
        case .playFromStart: session.playFromStart()
        case .goToTimecode: panels.monitorView.focusTimecodeField()
        case .toggleLoop: session.toggleLoop(); panels.monitorModel.isLooping = session.bounds.loop
        case .exportFrame:
            switch CommandRouting.exportFrameTarget(focus: focusedPanel) {
            case .sourceMonitor: panels.source.exportFrame()
            case .program: exportProgramFrame()
            }
        case .newBin: showPanel(.project); panels.projectView.newBin()
        case .matchFrame: panels.matchFrame()
        case .reverseMatchFrame: panels.reverseMatchFrame()
        case .insert: placeSelectedMedia(.insert)
        case .overwrite: placeSelectedMedia(.overwrite)
        case .placeOnTop: placeSelectedMedia(.overwrite, onTop: true)
        case .addMarker:
            // M on a frame that already has a marker opens its dialog (Premiere).
            if let r = session.markAtPlayhead(), r.openEdit { panels.editMarker(r.id) }
        case .tool(let t): selectTool(t)
        case .slipKeyframesStayTool: selectSlipKeyframesStay()
        case .addEdit: session.addEditAtPlayhead()
        case .addEditAllTracks: session.addEditAtPlayhead(allTracks: true)
        case .jumpCutAlternate:
            if let reason = session.jumpCutRefusal { shell.statusBar.flash(reason) } else { session.jumpCutAlternate() }
        case .splitEditAudio: session.splitEditToPlayhead(.audio)
        case .splitEditVideo: session.splitEditToPlayhead(.video)
        case .cutOut: session.cutOut()
        case .closeGapAtPlayhead: session.closeGapAtPlayhead()
        case .nudgeAudioEditLeft: session.nudgeSplitEdit(.audio, frames: -1)
        case .nudgeAudioEditRight: session.nudgeSplitEdit(.audio, frames: 1)
        case .nudgeVideoEditLeft: session.nudgeSplitEdit(.video, frames: -1)
        case .nudgeVideoEditRight: session.nudgeSplitEdit(.video, frames: 1)
        case .fitToFill: panels.source.edit(.overwrite, fitToFill: true)
        case .replaceClipFromSource: panels.source.replaceSelectedClip()
        case .replaceClipFromProject: replaceClipFromProject()
        case .jCut: session.jlCutToPlayhead(.jCut)
        case .lCut: session.jlCutToPlayhead(.lCut)
        case .jCutByOffset: session.offsetSplitEdit(.jCut)
        case .lCutByOffset: session.offsetSplitEdit(.lCut)
        case .rippleTrimPrevious: session.rippleTrimToPlayhead(.head)
        case .rippleTrimNext: session.rippleTrimToPlayhead(.tail)
        case .delete, .rippleDelete:
            // Effect Controls owns Delete while it has focus: keys, then the selected effect. Never the timeline clips.
            if effectControlsHasFocus && session.selectedTransition == nil { panels.effectModel.deleteSelectionOrEffect() }
            else if session.removeSelectedTransition() { }
            else if c == .delete, focusedPanel == .timeline, panels.timelineView.deleteSelectedWord() { }   // only a word picked inside its caption; a caption alone falls through and is deleted
            else if deleteSelectedGap() { }
            // Delete follows the sequence mode (Normal lifts, Fast Cut closes: deleteSelection decides); Shift+Delete
            // always closes the gap.
            else { session.deleteSelection(ripple: c == .rippleDelete) }
        case .toggleSnapping:
            panels.timelineView.toolState.snapping.toggle()
            panels.timelineView.toolState.storeToggles()
            session.setSnapping(panels.timelineView.toolState.snapping)   // saved with the sequence, one undo step
            shell.statusBar.flash(panels.timelineView.toolState.snapping ? "Snapping on" : "Snapping off", seconds: 2)
        case .speedDuration: requestSpeedDuration()
        case .reverseClip: if !session.toggleReverseSelection() { shell.statusBar.flash("Select a video or audio clip first.") }
        case .toggleTimeRemapping: toggleTimeRemapping()
        case .removeTimeRemapping: removeTimeRemapping()
        case .addSpeedPoint: addSpeedPoint()
        case .undo: session.undo()
        case .redo: session.redo()
        case .videoTracksTaller: panels.timelineView.sizeTracks(.video, direction: 1)
        case .videoTracksShorter: panels.timelineView.sizeTracks(.video, direction: -1)
        case .audioTracksTaller: panels.timelineView.sizeTracks(.audio, direction: 1)
        case .audioTracksShorter: panels.timelineView.sizeTracks(.audio, direction: -1)
        case .allTracksTaller: panels.timelineView.sizeTracks(nil, direction: 1)
        case .allTracksShorter: panels.timelineView.sizeTracks(nil, direction: -1)
        case .toggleFitTracks: panels.timelineView.setFitsTracks(!panels.timelineView.fitsTracks)
        case .minimizeAllTracks: panels.timelineView.minimizeAllTracks()
        case .expandAllTracks: panels.timelineView.expandAllTracks()
        case .trackHeightSmall: panels.timelineView.setHeightMode(.small)
        case .trackHeightMedium: panels.timelineView.setHeightMode(.medium)
        case .trackHeightLarge: panels.timelineView.setHeightMode(.large)
        case .trackHeightAuto: panels.timelineView.setHeightMode(.auto)
        case .zoomIn, .zoomOut, .zoomFit:
            switch CommandRouting.zoomTarget(focus: focusedPanel, effectControlsFocused: effectControlsHasFocus) {
            case .programMonitor, .sourceMonitor:
                if let m = focusedMonitorModel { m.setZoom(c == .zoomFit ? .fit : m.zoom.stepped(zoomIn: c == .zoomIn)) }
            case .effectControls:
                c == .zoomIn ? panels.effectModel.zoomIn() : c == .zoomOut ? panels.effectModel.zoomOut() : panels.effectModel.zoomToFit()
            case .timeline:
                c == .zoomIn ? panels.timelineView.zoomIn() : c == .zoomOut ? panels.timelineView.zoomOut() : panels.timelineView.zoomToFit()
            }
        case .focusPanel(let p): showPanel(p)
        case .createAnglesClip: requestAnglesClip()
        case .switchAngle(let n): switchAngle(n)
        case .maximizePanel:
            if let p = panelUnderMouse() ?? focusedPanel { toggleMaximize(p) }
        case .importMedia: importAnything()
        case .newSequence: requestNewSequence()
        case .importTimeline: importTimeline(nil)
        case .exportEDL: exportEDL(nil)
        case .exportFCPXML: exportFCPXML(nil)
        case .exportFinalCutXML: exportXMEML(nil)
        case .exportOpenTimelineIO: exportOTIO(nil)
        case .importLottie: importLottieAnimation(nil)
        case .importMotionGraphicsTemplate: importMotionGraphicsTemplates(nil)
        case .importPremiereProject: importPremiereProject(nil)
        case .importPremierePresets: importPremierePresets(nil)
        case .importProject: importProjectAsBin(nil)
        case .toggleGraphEditor:
            showPanel(.effectControls)
            panels.effectModel.toggleGraphEditor()
        case .save: Task { await saveDocument() }
        case .export: showExport()
        case .quickExport: exports.quickExport()
        case .applyVideoTransition: applyTransitions(.video)
        case .applyAudioTransition: applyTransitions(.audio)
        case .applyDefaultTransitions: applyTransitions(.both)
        case .audioGain: requestAudioGain()
        case .toggleAudioScrubbing: toggleAudioScrubbing()
        case .audioGainDown: nudgeAudioGain(-1)
        case .audioGainUp: nudgeAudioGain(1)
        case .audioGainDown6: nudgeAudioGain(-6)
        case .audioGainUp6: nudgeAudioGain(6)
        case .matchLoudness: requestMatchLoudness()
        case .autoDuck: requestAutoDuck()
        case .addBeatMarkers: requestMarkersOnBeat(downbeatsOnly: false)
        case .addMarkersOnDownbeats: requestMarkersOnBeat(downbeatsOnly: true)
        case .projectLiveDucking: showSequenceSettings(nil)    // the override is a Sequence Settings row (E9)
        case .removeSilences: requestRemoveSilences()
        case .removeFillerWords: requestRemoveFillerWords()
        case .voiceover: requestVoiceover()
        case .recordVoiceOver: requestRecordVoiceOver()
        case .voiceChain: requestVoiceChain()
        case .disguiseVoice: requestDisguiseVoice()
        case .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead: requestProposedCuts(c)
        case .keywordAtPlayhead:
            if !session.addKeywordAtPlayhead(), let e = session.lastError { shell.statusBar.flash(e, seconds: 3) }
        case .addTitle: addTitleAtPlayhead()
        case .autoCaptions: transcribeAndCreateCaptions()
        case .checkCuts: requestCheckCuts()
        case .syncAudioToReference: requestSyncAudio()
        case .whooshAtCuts: panels.whooshFromSFXBin()
        case .punchInCuts: requestPunchInCuts()
        case .fillReel: requestFillReel()
        case .tagDialogue: tagSelectedAudio(.dialogue)
        case .tagMusic: tagSelectedAudio(.music)
        case .tagSFX: tagSelectedAudio(.sfx)
        case .toggleCaptionsInMonitor: toggleCaptionsInMonitor()
        case .toggleSafeAreas: toggleSafeAreas()
        case .toggleSelectionFollowsPlayhead: toggleSelectionFollowsPlayhead()
        case .deleteProjectItems: panels.projectView.deleteSelectedItems()
        case .easyEase: applyKeyframeEasing(.easeInOut)
        case .easeIn: applyKeyframeEasing(.easeIn, side: .in)
        case .easeOut: applyKeyframeEasing(.easeOut, side: .out)
        case .toggleHoldInterpolation:
            if panels.effectModel.selection.isEmpty { shell.statusBar.flash("Select keyframes in Effect Controls first.") }
            else { panels.effectModel.toggleHold() }
        default: break
        }
    }

    /// Easy Ease / Ease In / Ease Out (F9 family) on the keyframes selected in Effect Controls.
    private func applyKeyframeEasing(_ curve: EasingCurve, side: EaseSide = .both) {
        if !panels.effectModel.selection.isEmpty { panels.effectModel.applyEasing(curve, side: side) }
        else if !session.easeSpeedPointAtPlayhead(curve, side: side) {      // no keyframes selected: the speed point at the playhead
            shell.statusBar.flash("Select keyframes in Effect Controls, or put the playhead on a speed point.")
        }
    }

    /// Apply Video / Audio Transition (Cmd+D, Shift+Cmd+D) and Apply Default Transitions to Selection (Shift+D).
    private func applyTransitions(_ scope: EditorSession.TransitionScope) {
        session.stopPlayback()
        let n = session.applyDefaultTransitions(scope: scope, edges: panels.timelineView.interaction.edgeSelection)
        if n > 0 { shell.statusBar.flash(n == 1 ? "Transition applied." : "\(n) transitions applied.", seconds: 2) }
        else if let m = session.lastError { shell.statusBar.flash(m) }
    }

    private func nudgeShuttle(forward: Bool) {
        if CommandRouting.sourceMonitorOffered(focus: focusedPanel) { panels.source.nudge(forward: forward); return }
        let rate = session.engine.rate.nudged(forward: forward)
        session.apply(shuttle: .setRate(rate))
        router.rateChanged(to: rate)          // the next J / L continues from the nudged speed
        menuShuttle.adopt(rate)
    }

    private func exportProgramFrame() {
        session.stopPlayback()
        let name = (session.activeTimeline?.name ?? "Frame") + ".png"
        // A full-size render (not the viewer quality or a weak Mac's half-size preview decode).
        // The task holds the engine (bounded by its timeout), never this controller.
        let engine = session.engine
        Task { @MainActor in
            await engine.withFullSizeFrame { [weak self] result in
                guard let self else { return }
                FrameExport.run(result, suggestedName: name, on: self.window,
                                status: { [weak self] in self?.shell.statusBar.flash($0) })
            }
        }
    }

    private func shuttle(_ key: ShuttleKey) {
        if CommandRouting.sourceMonitorOffered(focus: focusedPanel) { panels.source.press(key); return }
        session.apply(shuttle: menuShuttle.press(key))
        _ = menuShuttle.release(key)
    }

    private func selectTool(_ t: EditorTool) {
        currentTool = t
        // The Program monitor follows: Hand pans the view, Type places text, everything else is the selection behavior.
        panels.setMonitorTool(t == .hand ? .hand : t == .type ? .type : .select)
        // The mapping from the key-map tool to the timeline tool state is shared with the shell (ToolState.select).
        panels.timelineView.toolState.select(t)
        let mapped = panels.timelineView.toolState.tool
        // The Mask tool works on the Program monitor: same path as a click on its slot (monitor tool + overlay).
        if mapped == .mask { panels.timelineView.onToolChange?(.mask) }
        // The Create slot too: T is Text, the shape keys pick their mode, and the mode decides what the monitor does.
        if mapped == .type { panels.timelineView.onToolChange?(.type) }
        shell.statusBar.flash(EditorCommand.tool(t).title, seconds: 2)
    }

    /// Tools > Slip Tool (Keyframes Stay): the slip tool with the variant flag on.
    private func selectSlipKeyframesStay() {
        selectTool(.slip)
        panels.timelineView.toolState.selectSlipKeyframesStay()
        shell.statusBar.flash(EditorCommand.slipKeyframesStayTool.title, seconds: 2)
    }

    /// Where Insert / Overwrite take their clip from (the menu item and the key share it).
    var placeSource: PlaceSource {
        PlaceSource.resolve(sourceLoaded: panels.source.mediaID != nil, focus: focusedPanel,
                            selectedMedia: panels.projectView.selectedMediaIDs.count, selectedSequences: panels.projectView.selectedSequenceIDs.count)
    }

    /// Insert / Overwrite the Source clip, else the media selected in the Project panel, at the playhead.
    func placeSelectedMedia(_ mode: ThreePointMode, onTop: Bool = false, backtimed: Bool = false) {
        let ids = panels.projectView.selectedMediaIDs
        let seqs = panels.projectView.selectedSequenceIDs
        // Premiere: the clip loaded in the Source monitor (its In/Out, the source patch), else the Project selection.
        switch placeSource {
        case .sourceMonitor: panels.source.edit(mode, placeOnTop: onTop, backtimed: backtimed); return
        case .projectSequences:
            // A sequence nests as one clip on the main track; Place on Top / Attach Backtimed would silently Overwrite.
            if onTop || backtimed {
                shell.statusBar.flash(SQL10n.format("%@ works with clips, not sequences.", SQL10n.string(backtimed ? "Attach Backtimed" : "Place on Top")))
                return
            }
            session.placeSequences(seqs, mode: mode); return    // sequences nest as one clip
        case .nothing:
            shell.statusBar.flash("Open a clip in the Source view first (double-click it in the Project panel).")
            return
        case .projectMedia: break
        }
        session.placeMedia(ids, mode: mode, placeOnTop: onTop, backtimed: backtimed, patched: true)
    }

    /// Shows a panel (unhiding it and selecting its tab) and gives it keyboard focus.
    /// The clip list is up on the Color page.
    var colorClipsShowing: Bool { store.page == .color && store.current.isVisible(.colorClips) }

    func showPanel(_ p: PanelID) {
        // Window > Clips: the clip list lives on the Color page.
        if p == .colorClips, store.page != .color { maximizedPanel = nil; store.setPage(.color); scheduleWorkspaceSave() }
        if maximizedPanel != nil && maximizedPanel != p { maximizedPanel = nil }
        if isFloating(p) { floatingWindows[p]?.bringToFront(); focusedPanel = p; return }
        mutateWorkspace { $0.show(p) }
        focusedPanel = p
        if p == .timeline { window.makeFirstResponder(panels.timelineView) }
    }

    func requestNewSequence() {
        let base = session.activeTimeline?.format ?? SequenceFormat(frameDuration: Time(1001, 30000))
        let suggested = SequenceSettings(name: session.suggestedSequenceName, format: base)
        SequenceSettingsSheet.present(on: window, settings: suggested, isNew: true) { [weak self] r in
            self?.session.addSequence(name: r.name, format: r.format, deliveryTarget: r.deliveryTarget)
        }
    }

    @objc func showSequenceSettings(_ sender: Any?) {
        guard let current = session.activeTimeline?.settings else { return }
        SequenceSettingsSheet.present(on: window, settings: current, isNew: false,
                                      projectDucking: session.project.liveDucking, preferredDucking: LiveDucking.current(),
                                      onDucking: { [weak self] in self?.session.setProjectLiveDucking($0) }) { [weak self] r in
            guard let self, session.applySequenceSettings(r) else { return }
            panels.syncEditMode()
        }
    }

    /// File > Project Notes…: the project's free text in an SQ dialog, one undo step on OK.
    func showProjectNotes() {
        let ui = ProjectNotesDialog.makeView(text: session.project.notes)
        let dialog = SQDialog()
        dialog.messageText = "Project Notes"
        dialog.informativeText = ProjectNotesDialog.hint
        dialog.accessoryView = ui.view
        dialog.initialFirstResponder = ui.textView
        dialog.addButton("OK")
        dialog.addButton("Cancel")
        dialog.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .first else { return }
                self?.session.setProjectNotes(ProjectNotesDialog.notes(from: ui.textView))
            }
        }
    }

    func requestNest() {
        guard !session.selection.isEmpty else { return }
        NestSheet.present(on: window, existingNames: session.project.timelines.map(\.name)) { [weak self] name in
            guard let self, let name else { return }
            session.nestSelection(name: name)
        }
    }

    /// Panel whose selection Cmd+A/C/X/V and Delete act on: the focused panel, unless the keyboard sits inside another
    /// (non-timeline) panel.
    private var panelWithKeyboard: PanelID? {
        panels?.panel(containing: window?.firstResponder as? NSView) ?? focusedPanel
    }

    /// A graphics clip is selected with layers picked (monitor click, layer list).
    private var monitorLayerSelected: Bool {
        panels.graphics.clip != nil && !panels.graphics.selectedLayers.isEmpty
    }

    var focusedEditTarget: FocusedEditTarget {
        let inside = panels?.panel(containing: window?.firstResponder as? NSView)
        if let inside, inside != .timeline { return FocusedEditTarget(panel: inside) }
        return FocusedEditTarget(panel: focusedPanel)
    }

    /// Edit verbs follow the focused panel (F4). True = handled here, or swallowed because that panel has no such command:
    /// never falls through to the timeline's clips. False = the timeline (or Effect Controls' own Delete path) goes on.
    func executeFocusedEdit(_ c: EditorCommand, _ verb: EditVerb) -> Bool {
        if CommandRouting.deletesMonitorLayers(command: c, panel: panelWithKeyboard, hasLayerSelection: monitorLayerSelected) {
            panels.graphics.deleteSelected()
            return true
        }
        let target = focusedEditTarget
        // The routing table (CommandRouting.editRoute) decides; this only performs the chosen action.
        switch CommandRouting.editRoute(target: target, verb: verb).action {
        case .fallThrough: return false
        case .swallow: break
        case .effectControls: return executeInEffectControls(c)
        case .deleteProjectItems: panels.projectView.deleteSelectedItems()
        case .pasteMedia: pasteMedia()
        case .deleteGraphicsLayers: panels.graphics.deleteSelected()
        case .deleteKeystones: panels.keystonesView.deleteSelection()
        case .deleteCaptions: panels.textView.deleteSelectedCaptions()
        case .selectAllGraphicsLayers: panels.graphics.selectAllLayers(); panels.graphicsView.selectionChanged()
        }
        return true
    }

    /// Menu state of an edit verb for the focused panel; nil = the timeline's own rules apply.
    func focusedEditEnabled(_ c: EditorCommand) -> Bool? {
        guard let verb = EditVerb(command: c) else { return nil }
        if CommandRouting.deletesMonitorLayers(command: c, panel: panelWithKeyboard, hasLayerSelection: monitorLayerSelected) { return true }
        let target = focusedEditTarget
        switch CommandRouting.editRoute(target: target, verb: verb).enabled {
        case .timelineRules: return nil
        case .always: return true
        case .never: return false
        case .canPasteMedia: return canPasteMedia
        case .graphicsHasSelection: return !panels.graphics.selectedLayers.isEmpty
        case .graphicsHasLayers: return !(panels.graphics.document?.layers.isEmpty ?? true)
        }
    }

    /// Effect Controls is the focused panel, or something inside it is first responder.
    /// The model of the Program or Source monitor while that panel has keyboard focus.
    var focusedMonitorModel: MonitorPanelModel? {
        switch focusedPanel {
        case .programMonitor: panels.monitorModel
        case .sourceMonitor: panels.source.model
        default: nil
        }
    }

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
        case .selectAll: tv.selectAll(nil); return true
        case .find, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub: return true     // Project-panel commands: not while typing
        default: return false
        }
    }
}

// MARK: Keymap

extension AppController {
    /// Saves a changed keymap (`sq.keymap`) and makes it live: key router, menu key equivalents, hint text.
    func applyKeymap(_ config: KeymapConfig) {
        keymapConfig = config
        keymapStore.save(config)
        let map = config.map
        commandMap = map
        CommandMap.current = map
        router.map = map
        menuOwnedKeys = MenuKeys.owned(map, isVisible: CommandRouting.isSupported)
        if let main = NSApp.mainMenu { refreshKeyEquivalents(in: main) }
    }

    /// Rewrites the key equivalent of every command item in place (the menu objects stay, so Open Recent and Workspaces keep working).
    private func refreshKeyEquivalents(in menu: NSMenu) {
        for item in menu.items {
            let command = (item.representedObject as? EditorCommand) ?? (item.representedObject as? PanelID).map(EditorCommand.focusPanel)
            if let command {
                if let b = commandMap.binding(for: command), let k = KeyMapping.keyEquivalent(for: b.key) {
                    item.keyEquivalent = k
                    item.keyEquivalentModifierMask = KeyMapping.modifierMask(b.modifiers)
                } else {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }
            if let sub = item.submenu { refreshKeyEquivalents(in: sub) }
        }
    }
}

extension AppController {
    /// Trim mode (TL-08 / TL-09). Toggle always; while it is on, Left / Right trim 1 frame (Shift: 10) and Ctrl+T cycles the side.
    func executeTrimModeCommand(_ c: EditorCommand) -> Bool {
        if c == .toggleTrimMode {
            if !panels.toggleTrimMode(), !panels.trimModel.isActive { shell.statusBar.flash("Trim mode needs an edit in the sequence.") }
            return true
        }
        guard panels.trimModel.isActive, focusedPanel == .timeline || focusedPanel == .programMonitor else { return false }
        switch c {
        case .stepBackward: panels.trimModel.step(frames: -1)
        case .stepForward: panels.trimModel.step(frames: 1)
        case .stepBackward5: panels.trimModel.step(frames: -10)     // Shift+arrow: 10 frames, like the clip nudge
        case .stepForward5: panels.trimModel.step(frames: 10)
        case .toggleTrimType: panels.trimModel.cycleSide()
        case .shuttleForward: panels.trimModel.dynamicTrim(.l)      // dynamic trim: J / K / L trim the edit, faster on repeat
        case .shuttleReverse: panels.trimModel.dynamicTrim(.j)
        case .shuttleStop: panels.trimModel.dynamicTrim(.k)
        case .playPause, .shuttleSlowForward, .shuttleSlowReverse:
            shell.statusBar.flash("Close Trim mode to play.")   // the two monitors are parked; playing would move only the hidden Program engine
        default: return false
        }
        return true
    }
}
