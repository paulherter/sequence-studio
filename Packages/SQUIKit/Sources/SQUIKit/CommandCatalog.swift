import Foundation
import SQCore

/// Every plain command plus the parametrised ones (tools, panels), for audits and tests. Commands added later that are
/// bound to a key or listed in a menu are picked up by `audited` even before they are added here.
public enum CommandCatalog {
    public static let plain: [EditorCommand] = [
        .shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward, .playPause, .stepBackward,
        .stepForward, .stepBackward5, .stepForward5, .stepBackward10, .stepForward10, .playToOut, .nextKeyframe, .previousKeyframe, .solo, .unlink, .muteTracks, .detachAudio, .trimToRange, .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd, .markIn,
        .markOut, .goToIn, .goToOut, .clearInOut, .markClip, .clearIn, .clearOut, .playInToOut, .toggleLoop, .exportFrame,
        .newBin, .lift, .extract, .bleep, .newTone, .toneSettings, .insert, .overwrite, .addMarker, .addEdit, .addEditAllTracks, .jumpCutAlternate, .splitEditAudio, .splitEditVideo, .cutOut, .placeOnTop, .closeGapAtPlayhead, .jCut, .lCut, .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .attachBacktimed, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly, .rippleTrimPrevious,
        .rippleTrimNext, .extendEdit, .rollTrimPrevious, .rollTrimNext, .trimPrevious, .trimNext, .enableClip, .group, .ungroup, .bundle, .unbundle, .joinCuts, .makeSubclip, .editOriginal, .extendToSequenceEnd, .saveAsTemplate, .toggleAnimationZones, .duplicate,
        .toggleTrimType, .toggleTrimMode, .moveSelectionUp, .moveSelectionDown, .delete, .rippleDelete, .deleteProjectItems, .toggleSnapping,
        .matchFrame, .reverseMatchFrame, .link, .speedDuration, .reverseClip, .toggleTimeRemapping, .removeTimeRemapping, .addSpeedPoint, .copy,
        .cut, .paste, .pasteAttributes, .undo, .redo, .selectClipAtPlayhead, .deselectAll, .nextEditPointAnyTrack,
        .previousEditPointAnyTrack, .pasteInsert, .pasteToTargets, .selectAll, .selectLayerAbove, .selectLayerBelow, .toggleLinkedSelection, .toggleMagnetic, .markSelection, .nextMarker,
        .previousMarker, .nextWeakTracking, .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .nudgeLeft10, .nudgeRight10, .trimBackward, .trimForward, .trimBackward5, .trimForward5, .zoomIn, .zoomOut,
        .zoomFit, .allTracksTaller, .allTracksShorter, .toggleFitTracks, .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter, .minimizeAllTracks,
        .expandAllTracks, .trackHeightSmall, .trackHeightMedium, .trackHeightLarge, .trackHeightAuto, .maximizePanel, .maximizeActivePanel, .selectNextPanel, .selectPreviousPanel, .resetLayout, .importMedia, .newSequence, .save, .export, .quickExport,
        .newProject, .openProject, .saveAs, .saveCopy, .revert, .closeProject, .projectNotes, .sequenceSettings, .setToFrameSize, .setToFillFrame, .keyboardShortcuts, .preferences, .quickApply,
        .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation,
        .audioGain, .toggleAudioScrubbing, .toggleSelectionFollowsPlayhead, .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6,
        .matchLoudness, .autoDuck, .removeSilences, .removeFillerWords, .addBeatMarkers, .addMarkersOnDownbeats, .cutToBeats, .snapToBeats, .fitMusicToLength, .projectLiveDucking, .voiceChain, .disguiseVoice, .tagDialogue, .tagMusic, .tagSFX, .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .autoReframe, .anonymize, .dynamicZoomIn, .dynamicZoomOut, .editDynamicZoom, .stabilize, .findSceneChanges, .matchColorToClip, .addSubjectMask, .togglePunchIn,
        .playInToOutRoll, .playAround, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub, .find, .applyVideoTransition,
        .applyAudioTransition, .applyDefaultTransitions, .toggleCaptionsInMonitor, .toggleSafeAreas, .toggleOverlays, .keywordAtPlayhead, .addTitle, .autoCaptions, .checkCuts, .whooshAtCuts, .syncAudioToReference, .punchInCuts, .fillReel, .slipKeyframesStayTool,
        .addKeyframe, .playFromStart, .toggleAllTargets, .goToTimecode, .toggleVideoTargets, .toggleAudioTargets, .selectLeftEdge, .selectRightEdge, .editMarker, .addAndEditMarker,
        .jCutByOffset, .lCutByOffset,
        .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight, .fitToFill, .replaceClipFromSource, .replaceClipFromProject, .exportMarkersCSV,
        .uiScaleLarger, .uiScaleSmaller, .uiScaleReset, .placeOnTop, .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack, .toggleGraphEditor,
        .importTimeline, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
        .importLottie, .importMotionGraphicsTemplate, .importPremiereProject, .importPremierePresets, .importProject,
        // Menu items that were only reachable through `audited` until the parity test (audit D25) listed them here.
        .acceptProposedCutAtPlayhead, .acceptProposedCuts, .rejectProposedCutAtPlayhead, .rejectProposedCuts, .reviewProposedCuts,
        .fitBlurredFill, .fitCard, .removeBlurredFill, .recordVoiceOver, .voiceover,
        .selectNextClip, .selectPreviousClip, .clearAllMarkers, .clearMarker, .goToSelectedClipStart, .goToSelectedClipEnd,
        .markOverhang, .nextSplitPoint, .previousSplitPoint,
        .slideLeft, .slideRight, .slipLeft, .slipRight, .slideLeft5, .slideRight5, .slipLeft5, .slipRight5, .projectListView, .projectIconView, .projectThumbnailLarger, .projectThumbnailSmaller,
    ]

    public static var all: [EditorCommand] {
        plain + EditorTool.allCases.map(EditorCommand.tool) + PanelID.allCases.map(EditorCommand.focusPanel)
            + [.createAnglesClip, .toggleLockOfTargets]
            + [TrackKind.video, .audio].flatMap { k in (1...9).map { EditorCommand.toggleTrackTarget(k, $0) } } + (1...9).map(EditorCommand.switchAngle)
            + ThumbnailModeChoice.allCases.map(EditorCommand.thumbnailMode)
            + ReplaceMode.allCases.map(EditorCommand.replaceMode)
            + ViewGammaChoice.allCases.map(EditorCommand.viewGamma)
    }

    /// The catalog united with everything the map binds and the menus list.
    public static func audited(_ map: CommandMap) -> [EditorCommand] {
        var seen = Set<EditorCommand>()
        var out: [EditorCommand] = []
        for c in all + map.entries.map(\.command) + EditorMenus.all.flatMap(\.commands) where seen.insert(c).inserted { out.append(c) }
        return out
    }
}
