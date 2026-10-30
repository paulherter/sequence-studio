import AppKit
import SQCore
import SQEditorSession
import SQEditorUI

/// Premiere-style timeline commands: clipboard, link, nudge, edge trims, markers. Kept apart from the main switch.
extension AppController {
    /// True when the command was handled here.
    func executeTimelineOp(_ c: EditorCommand) -> Bool {
        let tv = panels.timelineView
        let edges = tv.interaction.edgeSelection
        // Opt+arrows trim the selected edit; with none selected they say so (Slip is Opt+Cmd+arrows), never slip silently.
        func needEdit() { shell.statusBar.flash("Select an edit first (click a clip edge). Opt+Cmd+Left/Right slips the clip.") }
        // Fast Cut: Opt+Left/Right with a main-track clip selected and no edit selected is Move Clip Left / Right.
        func moveInsteadOfTrim(_ step: Int) -> Bool {
            guard session.fastCutCommandEnabled(step < 0 ? .moveClipLeft : .moveClipRight) else { return false }
            shell.statusBar.flash(session.moveSelectedMainClips(step), seconds: 2)
            return true
        }
        switch c {
        case .copy: if !session.copySelection() { shell.statusBar.flash("Select clips to copy.") }
        case .cut:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to cut.") } else { session.cutSelection() }
        case .paste, .pasteInsert, .pasteToTargets:
            if c == .paste, session.builtInClipboard != nil {
                if !session.pasteAttributes() { shell.statusBar.flash("Select a clip of the same kind to paste the copied effect onto.") }
            } else if c == .paste, session.effectClipboard != nil {
                if !session.pasteEffectClipboard() {
                    let audio = session.effectClipboard?.isAudio == true
                    shell.statusBar.flash(audio ? "Select an audio clip (or its linked video clip) that can take the copied effect."
                                                : "Select a video clip that can take the copied effect.")
                }
            } else if session.clipboard == nil {
                if c == .paste, canPasteMedia { pasteMedia() } else { shell.statusBar.flash("Nothing to paste. Copy clips first.") }
            }
            else { session.pasteClipboard(insert: c == .pasteInsert, toTargets: c == .pasteToTargets) }
        case .selectAll: session.selectAllClips()
        case .deselectAll: session.select(clips: [], captions: [])
        case .selectClipAtPlayhead: session.selectClipAtPlayhead()
        case .nextEditPointAnyTrack: session.goToEditPointOnAnyTrack(forward: true)
        case .previousEditPointAnyTrack: session.goToEditPointOnAnyTrack(forward: false)
        case .link: session.toggleLinkSelection()
        case .unlink: if !session.unlinkSelection() { shell.statusBar.flash("Select linked clips first.") }
        case .solo: if session.soloSelectedTracks() == nil { shell.statusBar.flash("Select clips with audio first.") }
        case .muteTracks: if session.muteSelectedTracks() == nil { shell.statusBar.flash("Select clips with audio first.") }
        case .detachAudio: if !session.detachAudioSelection() { shell.statusBar.flash("Select video clips with linked audio first.") }
        case .trimToRange:
            if session.activeTimeline?.inOut == nil { shell.statusBar.flash("Mark In and Out first.") }
            else if session.selection.isEmpty { shell.statusBar.flash("Select clips to trim first.") }
            else if session.trimSelectionToRange() == 0 { shell.statusBar.flash("The selection already lies inside In and Out.") }
        case .nextKeyframe, .previousKeyframe:
            if !session.goToKeyframe(forward: c == .nextKeyframe) { shell.statusBar.flash("No more keyframes that way.", seconds: 2) }
        case .selectLayerAbove, .selectLayerBelow:
            if !panels.graphics.stepLayerSelection(up: c == .selectLayerAbove) { shell.statusBar.flash("No Graphic with layers is open.", seconds: 2) }
            else { panels.graphicsView.selectionChanged() }
        case .toggleLinkedSelection:
            tv.toolState.linkedSelection.toggle()
            session.linkedSelection = tv.toolState.linkedSelection
            session.setLinkedSelection(tv.toolState.linkedSelection)   // saved with the sequence, one undo step
            tv.toolState.storeToggles()
            shell.statusBar.flash(tv.toolState.linkedSelection ? "Linked Selection on" : "Linked Selection off", seconds: 2)
            shell.statusBar.setLinkedSelectionOff(!tv.toolState.linkedSelection)
        case .addVideoTrack: session.addTrack(.video)
        case .addAudioTrack: session.addTrack(.audio)
        case .removeEmptyTracks: session.removeEmptyTracks()
        case .deleteTrack: session.deleteTargetedTracks()
        case .toggleMagnetic:
            panels.toggleEditMode()
        case .pasteAttached:
            if !session.fastCutCommandEnabled(c) {
                shell.statusBar.flash(session.activeTimeline?.editMode == .magnetic ? "Nothing to paste. Copy clips first." : "Switch the sequence to Fast Cut first (Shift+G).", seconds: 2)
            } else {
                session.pasteClipboard(attached: true)
            }
        case .attachBacktimed:
            if session.activeTimeline?.editMode != .magnetic {
                shell.statusBar.flash("Switch the sequence to Fast Cut first (Shift+G).", seconds: 2)
            } else { placeSelectedMedia(.overwrite, onTop: true, backtimed: true) }
        case .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly:
            if !session.fastCutCommandEnabled(c) {
                shell.statusBar.flash(session.activeTimeline?.editMode == .magnetic ? "Select the right clips first." : "Switch the sequence to Fast Cut first (Shift+G).", seconds: 2)
            } else {
                let say: String
                switch c {
                case .appendToMainTrack: say = session.appendToMainTrack(media: appendMediaIDs)
                case .insertSpacer: say = session.insertSpacer()
                case .liftOffMainTrack: say = session.liftOffMainTrack()
                case .putOnMainTrack: say = session.putOnMainTrack()
                case .createStoryline: say = session.createStoryline()
                case .storylineRippleDelete: say = session.storylineRippleDelete()
                case .moveClipLeft: say = session.moveSelectedMainClips(-1)
                case .moveClipRight: say = session.moveSelectedMainClips(1)
                case .deleteSelectionOnly: say = session.deleteSelectionOnly()
                default: say = session.setAttachPoint()
                }
                shell.statusBar.flash(say, seconds: 2)
            }
        case .markSelection: session.markSelection()
        case .nextMarker: session.goToNextMarker()
        case .markOverhang:
            if !session.canMarkOverhang { shell.statusBar.flash("No split edit under the playhead.") } else { session.markOverhang() }
        case .nextSplitPoint: session.goToNextSplitPoint()
        case .previousSplitPoint: session.goToPreviousSplitPoint()
        case .clearMarker: if !session.clearMarkerAtPlayhead() { shell.statusBar.flash("No marker at the playhead.") }
        case .clearAllMarkers: if session.clearAllMarkers() == 0 { shell.statusBar.flash("There are no markers to clear.") }
        case .selectNextClip, .selectPreviousClip:
            if !session.selectAdjacentClip(forward: c == .selectNextClip) {
                shell.statusBar.flash(session.selection.isEmpty ? "Select a clip first." : "No further clip on this track.")
            }
        case .goToSelectedClipStart, .goToSelectedClipEnd:
            if !session.goToSelectedClipEdge(end: c == .goToSelectedClipEnd) { shell.statusBar.flash("Select a clip first.") }
        case .slideLeft, .slideRight, .slideLeft5, .slideRight5:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to slide.") }
            else {
                let n = (c == .slideLeft || c == .slideLeft5 ? -1 : 1) * (c == .slideLeft5 || c == .slideRight5 ? StepStatus.large : StepStatus.small)
                session.slideSelection(frames: n); shell.statusBar.flash(StepStatus.line("Slide", frames: n), seconds: 2)
            }
        case .slipLeft, .slipRight, .slipLeft5, .slipRight5:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to slip.") }
            else {
                let n = (c == .slipLeft || c == .slipLeft5 ? -1 : 1) * (c == .slipLeft5 || c == .slipRight5 ? StepStatus.large : StepStatus.small)
                session.slipSelection(frames: n); shell.statusBar.flash(StepStatus.line("Slip", frames: n), seconds: 2)
            }
        case .previousMarker: session.goToPreviousMarker()
        case .nextWeakTracking:
            switch panels.nextWeakTrackingStart(after: session.playhead) {
            case .found(let t): session.seek(to: t)
            case .none: shell.statusBar.flash("No weak tracking after the playhead.")
            case .noTrackedMask: shell.statusBar.flash("No tracked Magic mask in this sequence.")
            case .pending: shell.statusBar.flash("Checking the tracking. Try again in a moment.")
            }
        case .addKeyframe:
            if let p = panels.effectModel.focusedProperty {
                if panels.effectModel.addKeyAtPlayhead(p) == .unavailable {
                    shell.statusBar.flash("There is already a keyframe here, or the playhead is outside the clip.", seconds: 2)
                }
            } else { shell.statusBar.flash("Select a property in Effect Controls first.", seconds: 2) }
        case .toggleAllTargets: session.toggleAllTargets()
        case .toggleTrackTarget(let kind, let n):
            if !session.toggleTrackTarget(kind, n) { shell.statusBar.flash("There is no \(kind == .video ? "video" : "audio") track \(n).") }
        case .toggleLockOfTargets:
            if !session.toggleLockOfTargets() { shell.statusBar.flash("Target a track first.") }
        case .toggleVideoTargets: session.toggleTargets(of: .video)
        case .toggleAudioTargets: session.toggleTargets(of: .audio)
        case .selectLeftEdge, .selectRightEdge:
            if let sel = session.edgeSelectionOfSelection(c == .selectLeftEdge ? .head : .tail) { tv.selectEdges(sel) }
            else { shell.statusBar.flash("Select a clip first.", seconds: 2) }
        case .editMarker:
            if let id = session.markerAtPlayhead() { panels.editMarker(id) }
            else { shell.statusBar.flash("No marker at the playhead.", seconds: 2) }
        case .addAndEditMarker:
            if let r = session.markAtPlayhead() { panels.editMarker(r.id) }
        case .nudgeLeft: session.nudgeSelection(frames: -StepStatus.small); shell.statusBar.flash(StepStatus.line("Nudge", frames: -StepStatus.small), seconds: 2)
        case .nudgeRight: session.nudgeSelection(frames: StepStatus.small); shell.statusBar.flash(StepStatus.line("Nudge", frames: StepStatus.small), seconds: 2)
        case .nudgeLeft5: session.nudgeSelection(frames: -1*StepStatus.large); shell.statusBar.flash(StepStatus.line("Nudge", frames: -1*StepStatus.large), seconds: 2)
        case .nudgeRight5: session.nudgeSelection(frames: 1*StepStatus.large); shell.statusBar.flash(StepStatus.line("Nudge", frames: 1*StepStatus.large), seconds: 2)
        case .nudgeLeft10: session.nudgeSelection(frames: -1*StepStatus.large); shell.statusBar.flash(StepStatus.line("Nudge", frames: -1*StepStatus.large), seconds: 2)
        case .nudgeRight10: session.nudgeSelection(frames: 1*StepStatus.large); shell.statusBar.flash(StepStatus.line("Nudge", frames: 1*StepStatus.large), seconds: 2)
        case .trimBackward5: if let e = edges { session.trimEdges(e, frames: -1*StepStatus.large); shell.statusBar.flash(StepStatus.line("Trim", frames: -1*StepStatus.large), seconds: 2) } else { needEdit() }
        case .trimForward5: if let e = edges { session.trimEdges(e, frames: 1*StepStatus.large); shell.statusBar.flash(StepStatus.line("Trim", frames: 1*StepStatus.large), seconds: 2) } else { needEdit() }
        case .extendEdit: if let e = edges { session.extendEdit(e) } else { needEdit() }
        case .rollTrimPrevious: session.trimToPlayhead(.head, mode: .roll)
        case .rollTrimNext: session.trimToPlayhead(.tail, mode: .roll)
        case .trimPrevious: session.trimToPlayhead(.head, mode: .plain)
        case .trimNext: session.trimToPlayhead(.tail, mode: .plain)
        case .enableClip:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to enable or disable.") } else { session.toggleEnabledSelection() }
        case .group:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to group.") } else { session.groupSelection() }
        case .ungroup: session.ungroupSelection()
        case .bundle:
            if !session.bundleSelection() { shell.statusBar.flash("Select two or more clips to bundle.") }
        case .unbundle:
            if !session.unbundleSelection() { shell.statusBar.flash("Select a bundled clip to unbundle.") }
        case .joinCuts:
            let n = session.joinCutsInSelection()
            shell.statusBar.flash(n == 0 ? "No through edits to join." : n == 1 ? "Joined 1 cut." : "Joined \(n) cuts.")
        case .makeSubclip: makeSubclipFromSource()
        case .editOriginal: editOriginal()
        case .saveAsTemplate: panels.saveSelectionAsTemplate()
        case .toggleAnimationZones: panels.toggleZonesOfSelection()
        case .extendToSequenceEnd:
            if session.selectedAdjustmentLayers.isEmpty { shell.statusBar.flash("Select Adjustment Layers to extend.") } else { session.toggleExtendToSequenceEndSelection() }
        case .duplicate:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to duplicate.") } else { session.duplicateSelection() }
        case .toggleTrimType: if !tv.cycleTrimType() { needEdit() }
        case .moveSelectionUp, .moveSelectionDown:
            if session.selection.isEmpty { shell.statusBar.flash("Select clips to move.") }
            else if !session.moveSelectionLane(up: c == .moveSelectionUp) { shell.statusBar.flash(c == .moveSelectionUp ? "The clips cannot go further up." : "The clips cannot go further down.") }
        case .trimBackward: if let e = edges { session.trimEdges(e, frames: -1); shell.statusBar.flash(StepStatus.line("Trim", frames: -1), seconds: 2) } else if moveInsteadOfTrim(-1) {} else { needEdit() }
        case .trimForward: if let e = edges { session.trimEdges(e, frames: 1); shell.statusBar.flash(StepStatus.line("Trim", frames: 1), seconds: 2) } else if moveInsteadOfTrim(1) {} else { needEdit() }
        default: return false
        }
        return true
    }

    /// Append to Main Track takes the Source clip, else the media selected in the Project panel (same rule as Insert).
    var appendMediaIDs: [MediaRef.ID] {
        switch placeSource {
        case .sourceMonitor: return panels.source.mediaID.map { [$0] } ?? []
        default: return panels.projectView.selectedMediaIDs
        }
    }

    /// Fast Cut: holding ` (backtick) while editing keeps the attached clips on their frame instead of traveling with
    /// their main clip (FCP's grave-accent hold). A tap without an edit still maximizes the panel under the mouse.
    /// The key-up always ends the hold, whatever modifiers are down or which mode the sequence is in by then (Shift+G
    /// during the hold). True when the event was used.
    func handleKeepAttachedHold(_ ke: KeyEvent) -> Bool {
        guard ke.key == .char("`"), let tv = panels?.timelineView else { return false }
        switch ke.phase {
        case .down:
            guard ke.modifiers.isEmpty, session.activeTimeline?.isFastCut == true else { return false }
            if !ke.isRepeat { keepAttachedUsed = false }
            session.keepAttachedHeld = true
            tv.toolState.keepAttached = true
            if tv.isDragging { keepAttachedUsed = true; tv.refreshGesture() }
            return true
        case .up:
            guard session.keepAttachedHeld || tv.toolState.keepAttached else { return false }
            let used = keepAttachedUsed
            releaseKeepAttached()
            if !tv.isDragging, !used, session.activeTimeline?.isFastCut == true,
               let p = panelUnderMouse() ?? focusedPanel { toggleMaximize(p) }
            return true
        }
    }

    /// Ends a backtick hold (its key-up, or focus loss where the key-up never arrives).
    func releaseKeepAttached() {
        let wasHeld = session.keepAttachedHeld
        session.keepAttachedHeld = false
        keepAttachedUsed = false
        guard let tv = panels?.timelineView else { return }
        let toolHeld = tv.toolState.keepAttached
        tv.toolState.keepAttached = false
        if wasHeld || toolHeld, tv.isDragging { tv.refreshGesture() }
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
        // Fast Cut: Delete closes the gap already, so the second item would only repeat it. Shift+Delete still works.
        case .rippleDelete: item.isHidden = session.activeTimeline?.isFastCut == true
        case .stabilize: item.title = isStabilizing ? "Cancel Stabilize" : c.title
        case .findSceneChanges: item.title = isFindingSceneChanges ? "Cancel Find Scene Changes" : c.title
        case .autoReframe: item.title = isReframing ? "Cancel Auto Reframe" : c.title
        case .anonymize: item.title = isAnonymizing ? "Cancel Anonymize" : c.title
        case .recordVoiceOver: item.title = session.voiceRecorder.state == .recording ? "Stop Voice-Over Recording" : c.title
        case .thumbnailMode(let m): item.state = thumbnailModeState(m)
        case .toggleSnapping: item.state = panels.timelineView.toolState.snapping ? .on : .off
        case .toggleLinkedSelection: item.state = panels.timelineView.toolState.linkedSelection ? .on : .off
        case .toggleMagnetic: item.state = session.activeTimeline?.editMode == .magnetic ? .on : .off
        case .toggleGraphEditor: item.state = panels.effectModel.graphEditor ? .on : .off
        case .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .attachBacktimed, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly: break
        case .extendToSequenceEnd:
            let layers = session.selectedAdjustmentLayers
            item.state = !layers.isEmpty && layers.allSatisfy(\.extendsToSequenceEnd) ? .on : .off
        case .toggleAnimationZones: item.state = session.selectedZoneClips.allSatisfy { $0.zones != nil } && !session.selectedZoneClips.isEmpty ? .on : .off
        case .toggleCaptionsInMonitor: item.state = session.engine.showsCaptions ? .on : .off
        case .toggleSelectionFollowsPlayhead: item.state = session.selectionFollowsPlayhead ? .on : .off
        case .toggleSafeAreas: item.state = EditorPanels.showsSafeAreas ? .on : .off
        case .toggleOverlays, .viewGamma: item.state = monitorViewState(c) ?? .off
        case .tagDialogue, .tagMusic, .tagSFX:
            let tag: AudioTag = c == .tagDialogue ? .dialogue : c == .tagMusic ? .music : .sfx
            let state = session.audioTagMenuState(tag)
            item.state = state.checked ? .on : .off
            item.title = state.title(for: tag)
        default: break
        }
    }
}
