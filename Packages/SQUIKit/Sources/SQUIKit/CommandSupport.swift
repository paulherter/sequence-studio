import Foundation

/// Which commands the app wires up. Lives here (not in the app target) so tests can walk it against the menus and the key map.
/// The app executes the commands; a command that is not listed here shows "not available yet" and its menu item is hidden.
public enum CommandSupport {
    /// Commands handled by the main switch of `AppController.execute` and by the source/project flow.
    public static func isCore(_ c: EditorCommand) -> Bool {
        switch c {
        case .shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward, .playPause,
             .stepBackward, .stepForward, .stepBackward5, .stepForward5, .stepBackward10, .stepForward10, .playToOut,
             .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd,
             .markIn, .markOut, .markClip, .goToIn, .goToOut, .clearInOut, .clearIn, .clearOut, .lift, .extract, .bleep, .newTone, .toneSettings, .insert, .overwrite, .addMarker,
             .playInToOut, .toggleLoop, .exportFrame, .newBin, .matchFrame, .reverseMatchFrame,
             .tool, .slipKeyframesStayTool, .addEdit, .addEditAllTracks, .jumpCutAlternate, .splitEditAudio, .splitEditVideo, .cutOut, .placeOnTop, .closeGapAtPlayhead, .jCut, .lCut, .jCutByOffset, .lCutByOffset, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight, .fitToFill, .replaceClipFromSource, .replaceClipFromProject, .rippleTrimPrevious, .rippleTrimNext,
             .delete, .rippleDelete, .toggleSnapping, .undo, .redo,
             .zoomIn, .zoomOut, .zoomFit, .focusPanel, .maximizePanel, .maximizeActivePanel, .resetLayout,
             .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter,
             .allTracksTaller, .allTracksShorter, .toggleFitTracks, .minimizeAllTracks, .expandAllTracks, .trackHeightSmall, .trackHeightMedium, .trackHeightLarge, .trackHeightAuto, .speedDuration, .reverseClip, .toggleTimeRemapping, .removeTimeRemapping, .addSpeedPoint,
             .importMedia, .newSequence, .save, .export, .quickExport, .audioGain, .toggleAudioScrubbing, .toggleSelectionFollowsPlayhead, .toggleCaptionsInMonitor, .toggleSafeAreas, .keywordAtPlayhead, .addTitle, .autoCaptions,
             .playInToOutRoll, .playAround, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub, .find,
             .projectListView, .projectIconView, .projectThumbnailSmaller, .projectThumbnailLarger,
             .applyVideoTransition, .applyAudioTransition, .applyDefaultTransitions,
             .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6, .matchLoudness, .autoDuck, .addBeatMarkers, .addMarkersOnDownbeats, .projectLiveDucking, .removeSilences, .removeFillerWords, .voiceover, .recordVoiceOver, .voiceChain, .disguiseVoice, .reviewProposedCuts, .acceptProposedCuts, .rejectProposedCuts, .acceptProposedCutAtPlayhead, .rejectProposedCutAtPlayhead, .tagDialogue, .tagMusic, .tagSFX,
             .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation, .deleteProjectItems, .checkCuts, .whooshAtCuts, .syncAudioToReference, .punchInCuts, .fillReel,
             .createAnglesClip, .switchAngle, .playFromStart, .goToTimecode, .exportMarkersCSV, .thumbnailMode, .toggleOverlays, .viewGamma, .toggleGraphEditor,
             .importTimeline, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
             .importLottie, .importMotionGraphicsTemplate, .importPremiereProject, .importPremierePresets, .importProject:
            true
        default: false
        }
    }

    /// Timeline operations (clipboard, link, nudge, edge trims, markers).
    public static func isTimelineOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .selectClipAtPlayhead, .deselectAll, .nextEditPointAnyTrack, .previousEditPointAnyTrack,
             .copy, .cut, .paste, .pasteInsert, .pasteToTargets, .selectAll, .selectLayerAbove, .selectLayerBelow, .link, .toggleLinkedSelection, .toggleMagnetic, .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .attachBacktimed, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly, .markSelection,
             .nextKeyframe, .previousKeyframe, .solo, .unlink, .muteTracks, .detachAudio, .trimToRange,
             .nextMarker, .previousMarker, .nextWeakTracking, .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .nudgeLeft10, .nudgeRight10,
             .clearMarker, .clearAllMarkers, .selectNextClip, .selectPreviousClip, .goToSelectedClipStart, .goToSelectedClipEnd,
             .markOverhang, .nextSplitPoint, .previousSplitPoint,
             .slideLeft, .slideRight, .slideLeft5, .slideRight5, .slipLeft, .slipRight, .slipLeft5, .slipRight5,
             .trimBackward, .trimForward, .trimBackward5, .trimForward5, .extendEdit, .rollTrimPrevious, .rollTrimNext, .trimPrevious, .trimNext,
             .addKeyframe, .toggleAllTargets, .toggleTrackTarget, .toggleLockOfTargets, .toggleVideoTargets, .toggleAudioTargets, .selectLeftEdge, .selectRightEdge, .editMarker, .addAndEditMarker,
             .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack, .enableClip, .duplicate, .toggleTrimType, .toggleTrimMode, .moveSelectionUp, .moveSelectionDown, .group, .ungroup, .bundle, .unbundle, .joinCuts, .makeSubclip, .editOriginal, .extendToSequenceEnd, .saveAsTemplate, .toggleAnimationZones:
            true
        default:
            false
        }
    }

    /// App-level commands (project handling, windows).
    public static func isShellCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .newProject, .openProject, .saveAs, .saveCopy, .revert, .closeProject, .projectNotes, .sequenceSettings, .setToFrameSize, .setToFillFrame, .keyboardShortcuts, .preferences, .quickApply,
             .maximizeActivePanel, .selectNextPanel, .selectPreviousPanel, .resetLayout, .uiScaleLarger, .uiScaleSmaller, .uiScaleReset: true
        default: false
        }
    }

    /// Clip look commands (fades, frame holds, paste attributes, Auto Reframe, Stabilize).
    public static func isEffectsLookOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .pasteAttributes, .autoReframe, .anonymize, .dynamicZoomIn, .dynamicZoomOut, .editDynamicZoom, .stabilize, .findSceneChanges, .matchColorToClip, .addSubjectMask, .splitScreen, .speedRampPreset, .replaceMode, .cutToBeats, .snapToBeats,
             .fitBlurredFill, .fitCard, .removeBlurredFill, .togglePunchIn, .fitMusicToLength: true
        default: false
        }
    }

    public static func isSupported(_ c: EditorCommand) -> Bool {
        isCore(c) || isShellCommand(c) || isTimelineOp(c) || isEffectsLookOp(c)
    }
}
