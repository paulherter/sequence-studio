import Foundation

/// Color group of a command on the keyboard picture.
public enum KeyGroup: String, CaseIterable, Sendable {
    case transport, marking, tools, editing, clipboard, view, file, audio, keyframes, other

    public var title: String {
        switch self {
        case .transport: "Playback"
        case .marking: "In / Out and markers"
        case .tools: "Tools"
        case .editing: "Editing and trimming"
        case .clipboard: "Clipboard and undo"
        case .view: "Zoom, tracks and panels"
        case .file: "File and app"
        case .audio: "Audio"
        case .keyframes: "Keyframes"
        case .other: "Other"
        }
    }

    public static func of(_ c: EditorCommand) -> KeyGroup {
        switch c {
        case .shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward, .playPause, .stepBackward,
             .stepForward, .stepBackward5, .stepForward5, .playToOut, .nextKeyframe, .previousKeyframe, .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd, .playInToOut,
             .playInToOutRoll, .playAround, .playFromStart, .goToTimecode, .toggleLoop, .nextEditPointAnyTrack, .previousEditPointAnyTrack:
            .transport
        case .markIn, .markOut, .goToIn, .goToOut, .clearInOut, .markClip, .clearIn, .clearOut, .addMarker, .nextMarker,
             .previousMarker, .nextWeakTracking, .markSelection, .editMarker, .addAndEditMarker:
            .marking
        case .tool, .slipKeyframesStayTool: .tools
        case .addEdit, .addEditAllTracks, .jumpCutAlternate, .splitEditAudio, .splitEditVideo, .cutOut, .placeOnTop, .closeGapAtPlayhead, .jCut, .lCut, .jCutByOffset, .lCutByOffset, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight, .fitToFill, .replaceClipFromSource, .replaceClipFromProject, .appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .attachBacktimed, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly, .rippleTrimPrevious, .rippleTrimNext, .extendEdit, .rollTrimPrevious, .rollTrimNext,
             .trimPrevious, .trimNext, .toggleTrimType, .lift, .extract, .bleep, .newTone, .toneSettings, .insert, .overwrite, .delete, .rippleDelete, .nudgeLeft,
             .nudgeRight, .nudgeLeft10, .nudgeRight10, .trimBackward, .trimForward, .trimBackward5, .trimForward5, .moveSelectionUp,
             .moveSelectionDown, .toggleSnapping, .selectLayerAbove, .selectLayerBelow, .toggleLinkedSelection, .toggleTrackTarget, .toggleLockOfTargets, .addVideoTrack, .addAudioTrack, .removeEmptyTracks, .deleteTrack, .link, .solo, .unlink, .muteTracks, .detachAudio, .trimToRange, .enableClip, .duplicate, .speedDuration, .reverseClip, .selectClipAtPlayhead,
             .matchFrame, .reverseMatchFrame, .applyVideoTransition, .applyAudioTransition, .applyDefaultTransitions:
            .editing
        case .copy, .cut, .paste, .pasteAttributes, .pasteInsert, .pasteToTargets, .undo, .redo, .selectAll, .deselectAll, .deleteProjectItems:
            .clipboard
        case .zoomIn, .zoomOut, .zoomFit, .focusPanel, .maximizePanel, .maximizeActivePanel, .selectNextPanel, .selectPreviousPanel, .resetLayout, .videoTracksTaller,
             .videoTracksShorter, .audioTracksTaller, .audioTracksShorter, .minimizeAllTracks, .expandAllTracks, .allTracksTaller, .allTracksShorter, .toggleFitTracks, .toggleGraphEditor:
            .view
        case .importMedia, .newSequence, .save, .export, .quickExport, .exportFrame, .exportMarkersCSV, .newProject, .openProject, .saveAs, .saveCopy,
             .keyboardShortcuts, .preferences, .quickApply, .newBin, .find,
             .importTimeline, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
             .importLottie, .importMotionGraphicsTemplate, .importPremiereProject, .importPremierePresets, .importProject:
            .file
        case .audioGain, .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6, .toggleAudioScrubbing:
            .audio
        case .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation, .addKeyframe: .keyframes
        default: .other
        }
    }
}
