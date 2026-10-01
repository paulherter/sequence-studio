import Foundation

/// Which commands the app wires up. Lives here (not in the app target) so tests can walk it against the menus and the key map.
/// The app executes the commands; a command that is not listed here shows "not available yet" and its menu item is hidden.
public enum CommandSupport {
    /// Commands handled by the main switch of `AppController.execute` and by the source/project flow.
    public static func isCore(_ c: EditorCommand) -> Bool {
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
             .minimizeAllTracks, .expandAllTracks, .speedDuration, .toggleTimeRemapping, .removeTimeRemapping,
             .importMedia, .newSequence, .save, .export, .audioGain, .toggleAudioScrubbing, .toggleCaptionsInMonitor,
             .playInToOutRoll, .playAround, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub, .find,
             .applyVideoTransition, .applyAudioTransition, .applyDefaultTransitions,
             .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation, .deleteProjectItems:
            true
        default: false
        }
    }

    /// Timeline operations (clipboard, link, nudge, edge trims, markers).
    public static func isTimelineOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .selectClipAtPlayhead, .deselectAll, .nextEditPointAnyTrack, .previousEditPointAnyTrack,
             .copy, .cut, .paste, .pasteInsert, .selectAll, .link, .toggleLinkedSelection, .markSelection,
             .nextMarker, .previousMarker, .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5,
             .trimBackward, .trimForward, .trimBackward5, .trimForward5, .extendEdit, .rollTrimPrevious, .rollTrimNext, .trimPrevious, .trimNext,
             .enableClip, .duplicate, .toggleTrimType, .moveSelectionUp, .moveSelectionDown:
            true
        default:
            false
        }
    }

    /// App-level commands (project handling, windows).
    public static func isShellCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .newProject, .openProject, .saveAs, .revert, .sequenceSettings, .setToFrameSize, .keyboardShortcuts, .preferences,
             .maximizeActivePanel, .resetLayout: true
        default: false
        }
    }

    /// Clip look commands (fades, frame holds, paste attributes).
    public static func isEffectsLookOp(_ c: EditorCommand) -> Bool {
        switch c {
        case .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .pasteAttributes: true
        default: false
        }
    }

    public static func isSupported(_ c: EditorCommand) -> Bool {
        isCore(c) || isShellCommand(c) || isTimelineOp(c) || isEffectsLookOp(c)
    }
}
