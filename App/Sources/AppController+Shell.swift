import AppKit
import SQCore
import SQDrawLibrary
import SQEditorSession
import SQEditorUI

/// App-level commands (project handling, settings windows) and the rules that enable or disable menu items.
extension AppController {
    /// True when `c` was one of the shell commands and has been handled.
    func executeShellCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .newProject: newProject(nil)
        case .openProject: openProject(nil)
        case .saveAs: saveProjectAs(nil)
        case .saveCopy: Task { await saveDocumentCopy() }
        case .revert: revertProject(nil)
        case .closeProject: closeProjectItem(nil)
        case .sequenceSettings: showSequenceSettings(nil)
        case .projectNotes: showProjectNotes()
        case .setToFrameSize:
            if !session.setToFrameSize() { shell.statusBar.flash("Select clips to scale to the frame size.", seconds: 3) }
        case .setToFillFrame:
            if !session.setToFillFrame() { shell.statusBar.flash("Select clips to fill the frame.", seconds: 3) }
        case .maximizeActivePanel: if let p = focusedPanel { toggleMaximize(p) }
        case .selectNextPanel, .selectPreviousPanel:
            let visible = PanelID.dockable.filter { isFloating($0) || store.current.isVisible($0) }
            if let p = PanelCycle.step(from: focusedPanel, in: visible, forward: c == .selectNextPanel) { showPanel(p) }
        case .resetLayout: resetLayout(nil)
        case .keyboardShortcuts: shortcutsWindow.show()
        case .preferences: showSettings(nil)
        case .quickApply: showQuickApply()
        default: return false
        }
        return true
    }

    /// Enabled state of a command's menu item. Unwired commands are hidden by `MenuBuilder`; this disables the ones that
    /// cannot do anything right now (nothing selected, no In/Out range, no saved file).
    func commandEnabled(_ c: EditorCommand) -> Bool {
        guard CommandRouting.isSupported(c) else { return false }
        switch c {
        case .revert: return session.fileURL != nil && session.isDirty
        case .closeProject: return !session.isEmptyUntitled && window?.sqAttachedSheet == nil
        case .switchAngle: return hasAnglesClip
        case .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO, .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack: return session.activeTimeline != nil
        case .toggleGraphEditor: return panels?.effectModel.clip != nil
        case .lift, .extract, .goToIn, .goToOut, .clearInOut: return session.activeTimeline?.inOut != nil
        case .bleep: return session.activeTimeline?.inOut != nil || !session.selection.isEmpty
        case .toneSettings: return session.selectedTone != nil
        case .placeOnTop: return panels?.source.mediaID != nil || !(panels?.projectView.selectedMediaIDs.isEmpty ?? true)
        case .insert, .overwrite: return panels != nil && placeSource != .nothing
        case .enableClip, .duplicate, .moveSelectionUp, .moveSelectionDown, .group: return !session.selection.isEmpty
        case .ungroup: return !session.selectedGroupClips.isEmpty
        case .bundle: return session.bundleMenuState.canBundle
        case .unbundle: return session.bundleMenuState.canUnbundle
        case .makeSubclip: return panels?.source.mediaID != nil || panels?.projectView.selectedMediaIDs.count == 1
        case .editOriginal: return panels != nil && !editOriginalPaths.isEmpty
        case .saveAsTemplate: return session.canSaveSelectionAsTemplate
        case .toggleAnimationZones: return !session.selectedZoneClips.isEmpty
        case .extendToSequenceEnd: return !session.selectedAdjustmentLayers.isEmpty
        case .setToFrameSize, .setToFillFrame: return session.commandClipsForMenu(kind: .video).contains { session.selection.contains($0.id) }
        case .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly:
            return session.fastCutCommandEnabled(c)
        case .tool(.position): return session.activeTimeline?.isFastCut ?? false
        case .attachBacktimed:
            return session.fastCutCommandEnabled(c) && (panels?.source.mediaID != nil || !(panels?.projectView.selectedMediaIDs.isEmpty ?? true))
        case .link: return session.linkMenuState.enabled
        case .speedDuration: return session.speedDialogModel() != nil
        case .audioGain: return !session.audioGainTargets.isEmpty
        case .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6, .matchLoudness, .removeSilences, .disguiseVoice: return !session.selectedAudioClips.isEmpty
        case .tagDialogue: return !session.selectedAudioClips.isEmpty && session.audioTagMenuState(.dialogue).enabled
        case .tagMusic: return !session.selectedAudioClips.isEmpty && session.audioTagMenuState(.music).enabled
        case .tagSFX: return !session.selectedAudioClips.isEmpty && session.audioTagMenuState(.sfx).enabled
        case .removeFillerWords: return session.activeTimeline != nil    // transcribes first when no captions exist
        case .voiceover: return session.activeTimeline != nil
        case .recordVoiceOver: return session.activeTimeline != nil || isRecordingVoiceOver
        case .voiceChain: return !session.voiceChainTargets.isEmpty
        case .autoDuck: return session.canBakeLiveDuck
        case .addBeatMarkers, .addMarkersOnDownbeats: return !session.beatAnalysisTargets.isEmpty
        case .projectLiveDucking: return true
        case .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead:
            return !(session.activeTimeline?.proposedCuts.isEmpty ?? true)
        case .paste: return session.clipboard != nil || session.canPasteEffectClipboard || canPasteMedia
        case .pasteInsert, .pasteToTargets: return session.clipboard != nil
        case .extendEdit, .toggleTrimType, .trimBackward, .trimForward, .trimBackward5, .trimForward5:
            return panels?.timelineView.interaction.edgeSelection != nil
        case .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation:
            if !(panels?.effectModel.selection.isEmpty ?? true) { return true }
            switch c {
            case .easyEase: return session.speedPointAcceptsEase(.easeInOut, side: .both)
            case .easeIn: return session.speedPointAcceptsEase(.easeIn, side: .in)
            case .easeOut: return session.speedPointAcceptsEase(.easeOut, side: .out)
            default: return false
            }
        case .reverseClip: return session.canReverseSelection
        case .toggleTimeRemapping: return session.canToggleTimeRemapping
        case .removeTimeRemapping: return session.canRemoveTimeRemapping
        case .addSpeedPoint: return session.canAddSpeedPoint
        case .delete, .rippleDelete:
            return !session.selection.isEmpty || !session.captionSelection.isEmpty || session.selectedTransition != nil
                || (panels?.timelineView.interaction.hasDeleteTarget ?? false)      // a selected gap closes on Delete
        case .sequenceSettings: return session.activeTimeline != nil
        case .jumpCutAlternate: return session.jumpCutEnabled
        case .splitEditAudio, .splitEditVideo, .jCutByOffset, .lCutByOffset, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight:
            return session.splitEditEnabled
        case .fitToFill: return panels?.source.mediaID != nil && session.activeTimeline != nil
        case .replaceClipFromSource: return panels?.source.mediaID != nil && session.selection.count == 1
        case .replaceClipFromProject:
            return session.selection.count == 1
                && (panels?.projectView.selectedMediaIDs.count == 1 || panels?.projectView.selectedSequenceIDs.count == 1)
        case .punchInCuts: return session.punchInCutsEnabled
        case .fillReel: return fillReelEnabled
        case .selectNextClip: return session.canSelectAdjacentClip(forward: true)
        case .selectPreviousClip: return session.canSelectAdjacentClip(forward: false)
        case .goToSelectedClipStart, .goToSelectedClipEnd: return session.canGoToSelectedClipEdge
        case .markOverhang: return session.canMarkOverhang
        case .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .nudgeLeft10, .nudgeRight10,
             .slideLeft, .slideRight, .slideLeft5, .slideRight5,
             .slipLeft, .slipRight, .slipLeft5, .slipRight5: return session.canNudgeOrSlideSelection
        case .trimToRange: return session.canTrimSelectionToRange
        case .toggleAllTargets: return session.canToggleAllTargets
        case .toggleTrackTarget(let kind, let n): return session.canToggleTrackTarget(kind, n)
        case .toggleLockOfTargets: return session.canToggleLockOfTargets
        case .toggleVideoTargets: return session.canToggleTargets(of: .video)
        case .toggleAudioTargets: return session.canToggleTargets(of: .audio)
        case .selectLeftEdge, .selectRightEdge: return session.canSelectEdgeOfSelection
        case .editMarker: return session.canEditMarkerAtPlayhead
        case .solo: return session.canSoloSelectedTracks
        case .muteTracks: return session.canMuteSelectedTracks
        case .detachAudio: return session.canDetachAudioSelection
        case .unlink: return session.canUnlinkSelection
        case .joinCuts: return session.canJoinCuts
        case .syncAudioToReference: return session.syncAudioPlan != nil
        default: return true
        }
    }

    // MARK: Project

    @objc func newProject(_ sender: Any?) {
        Task { await createProjectFolder() }
    }

    @objc func revertProject(_ sender: Any?) {
        guard let url = session.fileURL, session.isDirty else { return }
        let alert = SQDialog()
        alert.messageText = SQL10n.format("Revert to the last saved version of “%@”?", session.displayName)
        alert.informativeText = "Your changes since the last save will be lost."
        alert.addButton("Revert", role: .destructive)
        alert.addButton("Cancel", role: .cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .first else { return }
                Task {
                    do {
                        let salvage = try await self.session.open(url: url); self.sweepLeftoverMattes()
                        if let salvage { self.presentMessage(ProjectSalvageNotice.title, ProjectSalvageNotice.detail(fileName: url.lastPathComponent, report: salvage)) }
                    } catch { self.presentError("Could not revert", error) }
                }
            }
        }
    }

    /// Remembers a project in File > Open Recent (and the Dock menu).
    func noteRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentProjects.note(url)
        recentProjects.save()
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentError("“\(url.lastPathComponent)” is no longer there", CocoaError(.fileNoSuchFile))
            return
        }
        Task { await openProject(at: url) }
    }

    @objc func clearRecents(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentProjects.clear()
        recentProjects.save()
    }
}

// MARK: Sequence match prompt

extension AppController {
    /// "This clip does not match the sequence settings": Change Sequence Settings (adopt) or Keep Existing Settings.
    func askChangeSequenceFormat(_ current: SequenceFormat, _ proposed: SequenceFormat) -> Bool {
        func text(_ f: SequenceFormat) -> String {
            let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
            return "\(f.width)×\(f.height), \(String(format: "%.5g", fps)) fps"
        }
        let alert = SQDialog()
        alert.messageText = "This clip does not match the sequence settings."
        alert.informativeText = SQL10n.format("Sequence: %@. Clip: %@. Change the sequence settings to match the clip?", text(current), text(proposed))
        alert.addButton("Change Sequence Settings")
        alert.addButton("Keep Existing Settings")
        return alert.runModal() == .first
    }
}

// MARK: Panels

extension AppController {
    /// Panel group under the pointer (Premiere: ` maximizes "the panel under the mouse"); nil outside the window.
    func panelUnderMouse() -> PanelID? {
        if let f = floatingPanelUnderMouse() { return f }
        guard let window, let content = window.contentView, panels != nil else { return nil }
        let p = window.mouseLocationOutsideOfEventStream
        guard content.frame.contains(p) else { return nil }
        return panels.panel(containing: content.hitTest(p))
    }

    func toggleMaximize(_ p: PanelID) {
        if isFloating(p) { toggleFloatingZoom(p); return }
        maximizedPanel = maximizedPanel == p ? nil : p
        focusedPanel = p
        applyWorkspace()
    }

    /// Right-click menu of a panel tab.
    func tabContextItems(for p: PanelID) -> [SQMenuItem] {
        var items = [SQMenuItem(title: maximizedPanel == p || floatingWindows[p]?.isZoomed == true ? "Restore Panel Size" : "Maximize Panel", shortcut: "`") { [weak self] in self?.toggleMaximize(p) }]
        if PanelID.dockable.contains(p) { items.append(SQMenuItem(title: "Move to Floating Window") { [weak self] in self?.floatPanel(p) }) }
        // Destructive last.
        items.append(SQMenuItem(title: "Close Panel") { [weak self] in self?.closePanel(p) })
        return items
    }

    func closePanel(_ p: PanelID) {
        floatingState.dock(p, key: floatingKey)
        if maximizedPanel != nil { maximizedPanel = nil }
        mutateWorkspace { $0.hide(p) }
        if focusedPanel == p { focusedPanel = store.current.isVisible(.timeline) ? .timeline : nil }
    }
}

extension AppController: NSMenuDelegate {
    /// Open Recent is rebuilt every time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === autosaveMenu { fillAutosaveMenu(menu); return }
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs.filter(ProjectFile.isProjectURL)
        for url in urls {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.sqHelp = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: SQL10n.string("Clear Menu"), action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }
}

/// Option+Space palette: what Return applies to the current selection.
extension AppController {
    func showQuickApply() {
        if quickApply.isShown { quickApply.close(); return }
        quickApply.model.setItems(QuickApplyCatalog.items(presets: panels.libraryModel.presets))
        quickApply.show(over: window)
    }

    /// The selected clips the highlighted transition row can go to: video clips for a video transition, audio clips for an
    /// audio one. The start/end popup only appears when there are any.
    func quickApplySelectedClipsForTransition() -> Set<Clip.ID> {
        guard let item = quickApply.model.selected, case .transition(let kind) = item.action else { return [] }
        return Set(session.commandClipsForMenu(kind: kind.trackKind).map(\.id)).intersection(session.selection)
    }

    func applyQuickApply(_ item: QuickApplyItem, end: TransitionEnd? = nil) {
        session.flushFollowSelection()           // while playing the selection is not followed: catch up first
        let videoIDs = Set(session.commandClipsForMenu(kind: .video).map(\.id)).intersection(session.selection)
        let audioTargets = session.audioEffectTargets(for: Set(session.commandClipsForMenu(kind: .video).map(\.id)
            + session.commandClipsForMenu(kind: .audio).map(\.id)).intersection(session.selection))
        switch QuickApplyTarget.resolve(item, selectedVideoClips: videoIDs, audioTargets: audioTargets) {
        case .effect(let kind, let clips):
            session.addEffect(kind: kind, to: clips)
            if let m = session.lastError, !m.isEmpty { shell.statusBar.flash(m) }
        case .transition(let kind):
            session.stopPlayback()
            let clips = quickApplySelectedClipsForTransition()
            let edges = end.map { QuickApplyTarget.edges(for: clips, end: $0) } ?? panels.timelineView.interaction.edgeSelection
            let n = session.applyDefaultTransitions(scope: kind.trackKind == .video ? .video : .audio, edges: edges, kind: kind)
            if n > 0 { shell.statusBar.flash(SQL10n.format("%@ applied.", SQL10n.string(kind.name)), seconds: 2) }
            else if let m = session.lastError { shell.statusBar.flash(m) }
        case .preset(let id, let kind):
            guard let preset = panels.libraryModel.presets.first(where: { $0.id == id }) else { return }
            session.stopPlayback()
            let ok = kind == .transition
                ? session.applyTransitionPreset(preset, edges: panels.timelineView.interaction.edgeSelection)
                : session.applyPreset(preset, mode: PresetApplyModeSetting.load())
            if ok { shell.statusBar.flash(SQL10n.format("%@ applied.", SQL10n.string(preset.name)), seconds: 2) }
            else if let m = session.lastError, !m.isEmpty { shell.statusBar.flash(m) }
        case .builtInPreset(let id):
            session.stopPlayback()
            if session.applyStackPreset(id) { shell.statusBar.flash(SQL10n.format("%@ applied.", SQL10n.string(item.title)), seconds: 2) }
            else if let m = session.lastError, !m.isEmpty { shell.statusBar.flash(m) }
        case .command(let c): execute(c)
        case .saveStackAsPreset: panels.saveSelectedClipAsPreset()
        case .macro(let macro): runQuickApplyMacro(macro)
        case .refused(let message): shell.statusBar.flash(message, seconds: 3)
        }
    }

    /// A palette macro: its steps run in order and the undo steps they leave fold into one named step. Voice Chain is a toggle,
    /// so a step that would switch it off is skipped; Match Loudness is awaited so its result lands inside the fold.
    func runQuickApplyMacro(_ macro: QuickApplyMacro) {
        let rows = Dictionary(quickApply.model.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let steps = macro.steps.compactMap { rows[$0] }
        let depth = session.undoStepDepth
        Task { @MainActor [weak self] in
            guard let self else { return }
            for step in steps {
                switch step.action {
                case .command(.voiceChain) where session.voiceChainActive: continue
                case .command(.matchLoudness): await requestMatchLoudness()?.value
                default: applyQuickApply(step)
                }
            }
            if session.undoStepDepth > depth + 1 { session.foldUndo(fromDepth: depth, name: macro.name) }
        }
    }
}
