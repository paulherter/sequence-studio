import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// What the panels know that the menu rules ask about (`AppController.commandEnabled` reads them from the AppKit panels).
/// The Windows host fills in what its panels have; defaults are "nothing there".
public struct ShellPanelFacts: Sendable, Equatable {
    public var panelsLoaded = false
    public var dialogShown = false
    public var hasAnglesClip = false
    public var effectControlsClip = false
    public var effectSelectionEmpty = true
    public var sourceMediaLoaded = false
    public var projectSelectedMedia = 0
    public var projectSelectedSequences = 0
    public var canPlaceSource = false
    public var editOriginalAvailable = false
    public var edgeSelected = false
    public var hasDeleteTarget = false
    public var fillReelEnabled = false
    public var recordingVoiceOver = false
    public var canPasteMedia = false
    /// An Anonymize run is going: the command cancels it and stays enabled.
    public var anonymizing = false
    /// The focus-dependent rows of Edit (`menuEnabled`): the Graphics panel's selection and layers, the Color panels' grade
    /// copy and paste. nil = the host does not report it, the row stays enabled.
    public var graphicsHasSelection: Bool?
    public var graphicsHasLayers: Bool?
    public var canCopyGrade: Bool?
    public var canPasteGrade: Bool?
    /// A text field is open in some panel (the Mac `textResponder`): Edit's text verbs and Undo/Redo belong to it.
    public var textEditing = false
    /// Effect Controls' own Copy / Cut / Paste / Delete (`canCopyFocused`, `canCutFocused`, `canPasteFocused`, selected keys
    /// or a deletable section); nil = the host does not report it.
    public var effectCanCopy: Bool?
    public var effectCanCut: Bool?
    public var effectCanPaste: Bool?
    public var effectCanDelete: Bool?
    public init() {}
}

/// `AppController.commandEnabled` and the session-only part of `AppController.execute` translated line for line into the
/// portable shell: the menu rules and the commands that need nothing but the session. Commands that open a panel, a
/// dialog or a picker return false from `run` so the host handles them (or reports them as not available yet).
@MainActor
public enum ShellCommands {
    /// Enabled state of a command's menu item (unwired commands are hidden by `ShellMenuBar.isVisible`).
    public static func enabled(_ c: EditorCommand, session: EditorSession, panels p: ShellPanelFacts) -> Bool {
        guard CommandRouting.isSupported(c) else { return false }
        switch c {
        case .revert: return session.fileURL != nil && session.isDirty
        case .closeProject: return !session.isEmptyUntitled && !p.dialogShown
        case .switchAngle: return p.hasAnglesClip
        case .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO, .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack: return session.activeTimeline != nil
        case .toggleGraphEditor: return p.effectControlsClip
        case .lift, .extract, .goToIn, .goToOut, .clearInOut: return session.activeTimeline?.inOut != nil
        case .bleep: return session.activeTimeline?.inOut != nil || !session.selection.isEmpty
        case .toneSettings: return session.selectedTone != nil
        case .placeOnTop: return p.sourceMediaLoaded || p.projectSelectedMedia > 0
        case .insert, .overwrite: return p.panelsLoaded && p.canPlaceSource
        case .enableClip, .duplicate, .moveSelectionUp, .moveSelectionDown, .group: return !session.selection.isEmpty
        case .ungroup: return !session.selectedGroupClips.isEmpty
        case .bundle: return session.bundleMenuState.canBundle
        case .unbundle: return session.bundleMenuState.canUnbundle
        case .makeSubclip: return p.sourceMediaLoaded || p.projectSelectedMedia == 1
        case .editOriginal: return p.panelsLoaded && p.editOriginalAvailable
        case .saveAsTemplate: return session.canSaveSelectionAsTemplate
        case .toggleAnimationZones: return !session.selectedZoneClips.isEmpty
        case .extendToSequenceEnd: return !session.selectedAdjustmentLayers.isEmpty
        case .setToFrameSize, .setToFillFrame: return session.commandClipsForMenu(kind: .video).contains { session.selection.contains($0.id) }
        case .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly:
            return session.fastCutCommandEnabled(c)
        case .tool(.position): return session.activeTimeline?.isFastCut ?? false
        case .attachBacktimed:
            return session.fastCutCommandEnabled(c) && (p.sourceMediaLoaded || p.projectSelectedMedia > 0)
        case .link: return session.linkMenuState.enabled
        case .speedDuration: return session.speedDialogModel() != nil
        case .audioGain: return !session.audioGainTargets.isEmpty
        case .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6, .matchLoudness, .removeSilences, .disguiseVoice: return !session.selectedAudioClips.isEmpty
        case .tagDialogue: return !session.selectedAudioClips.isEmpty && session.audioTagMenuState(.dialogue).enabled
        case .tagMusic: return !session.selectedAudioClips.isEmpty && session.audioTagMenuState(.music).enabled
        case .tagSFX: return !session.selectedAudioClips.isEmpty && session.audioTagMenuState(.sfx).enabled
        case .removeFillerWords: return session.activeTimeline != nil
        case .voiceover: return session.activeTimeline != nil
        case .recordVoiceOver: return session.activeTimeline != nil || p.recordingVoiceOver
        case .voiceChain: return !session.voiceChainTargets.isEmpty
        case .autoDuck: return session.canBakeLiveDuck
        case .addBeatMarkers, .addMarkersOnDownbeats: return !session.beatAnalysisTargets.isEmpty
        case .projectLiveDucking: return true
        case .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead:
            return !(session.activeTimeline?.proposedCuts.isEmpty ?? true)
        case .paste: return session.clipboard != nil || session.canPasteEffectClipboard || p.canPasteMedia
        case .pasteInsert, .pasteToTargets: return session.clipboard != nil
        case .extendEdit, .toggleTrimType, .trimBackward, .trimForward, .trimBackward5, .trimForward5: return p.edgeSelected
        case .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation:
            if !p.effectSelectionEmpty { return true }
            switch c {
            case .easyEase: return session.speedPointAcceptsEase(.easeInOut, side: .both)
            case .easeIn: return session.speedPointAcceptsEase(.easeIn, side: .in)
            case .easeOut: return session.speedPointAcceptsEase(.easeOut, side: .out)
            default: return false
            }
        case .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .splitScreen, .fitBlurredFill, .fitCard, .removeBlurredFill,
             .togglePunchIn, .dynamicZoomIn, .dynamicZoomOut, .addSubjectMask:
            return EditorLookCommands.enabled(c, session: session) ?? false
        case .reverseClip: return session.canReverseSelection
        case .toggleTimeRemapping: return session.canToggleTimeRemapping
        case .removeTimeRemapping: return session.canRemoveTimeRemapping
        case .addSpeedPoint: return session.canAddSpeedPoint
        case .delete, .rippleDelete:
            return !session.selection.isEmpty || !session.captionSelection.isEmpty || session.selectedTransition != nil || p.hasDeleteTarget
        case .sequenceSettings: return session.activeTimeline != nil
        case .jumpCutAlternate: return session.jumpCutEnabled
        case .splitEditAudio, .splitEditVideo, .jCutByOffset, .lCutByOffset, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight:
            return session.splitEditEnabled
        case .fitToFill: return p.sourceMediaLoaded && session.activeTimeline != nil
        case .replaceClipFromSource: return p.sourceMediaLoaded && session.selection.count == 1
        case .replaceClipFromProject:
            return session.selection.count == 1 && (p.projectSelectedMedia == 1 || p.projectSelectedSequences == 1)
        case .punchInCuts: return session.punchInCutsEnabled
        case .anonymize: return session.anonymizeTarget != nil || p.anonymizing
        case .pasteAttributes: return session.canPasteAttributes
        case .fillReel: return p.fillReelEnabled
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

    /// The commands of `AppController.execute` that need only the session. Returns a status line to flash, "" when done
    /// quietly, nil when the command is not one of these (the host's panels or dialogs handle it).
    public static func run(_ c: EditorCommand, session: EditorSession) -> String? {
        switch c {
        case .playPause: session.playPause()
        case .stepBackward: session.stepFrames(-1)
        case .stepForward: session.stepFrames(1)
        case .stepBackward5, .stepBackward10: session.stepFrames(-10)
        case .stepForward5, .stepForward10: session.stepFrames(10)
        case .playToOut: if !session.playToOut() { return "Move the playhead before the Out point first." }
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
        case .clearIn: session.clearIn()
        case .clearOut: session.clearOut()
        case .playInToOut: session.playInToOut()
        case .playFromStart: session.playFromStart()
        case .toggleLoop: session.toggleLoop()
        case .addEdit: session.addEditAtPlayhead()
        case .addEditAllTracks: session.addEditAtPlayhead(allTracks: true)
        case .splitEditAudio: session.splitEditToPlayhead(.audio)
        case .splitEditVideo: session.splitEditToPlayhead(.video)
        case .cutOut: session.cutOut()
        case .closeGapAtPlayhead: session.closeGapAtPlayhead()
        case .nudgeAudioEditLeft: session.nudgeSplitEdit(.audio, frames: -1)
        case .nudgeAudioEditRight: session.nudgeSplitEdit(.audio, frames: 1)
        case .nudgeVideoEditLeft: session.nudgeSplitEdit(.video, frames: -1)
        case .nudgeVideoEditRight: session.nudgeSplitEdit(.video, frames: 1)
        case .jCut: session.jlCutToPlayhead(.jCut)
        case .lCut: session.jlCutToPlayhead(.lCut)
        case .jCutByOffset: session.offsetSplitEdit(.jCut)
        case .lCutByOffset: session.offsetSplitEdit(.lCut)
        case .rippleTrimPrevious: session.rippleTrimToPlayhead(.head)
        case .rippleTrimNext: session.rippleTrimToPlayhead(.tail)
        case .delete, .rippleDelete:
            // shortcut: the Mac first offers Delete to Effect Controls, a picked caption word and a selected gap; the
            // Windows timeline has none of those yet. Upgrade when those panels land (route them before this line).
            if session.removeSelectedTransition() { break }
            session.deleteSelection(ripple: c == .rippleDelete)
        case .reverseClip: if !session.toggleReverseSelection() { return "Select a video or audio clip first." }
        case .setToFrameSize: if !session.setToFrameSize() { return "Select clips to scale to the frame size." }
        case .setToFillFrame: if !session.setToFillFrame() { return "Select clips to fill the frame." }
        case .undo: _ = session.undo()
        case .redo: _ = session.redo()
        default: return EditorLookCommands.run(c, session: session) ?? runTimelineOp(c, session: session)
        }
        return ""
    }
}
