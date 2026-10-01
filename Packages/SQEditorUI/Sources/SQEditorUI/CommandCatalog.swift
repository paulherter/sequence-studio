import Foundation

/// Every plain command plus the parametrised ones (tools, panels), for audits and tests. Commands added later that are
/// bound to a key or listed in a menu are picked up by `audited` even before they are added here.
public enum CommandCatalog {
    public static let plain: [EditorCommand] = [
        .shuttleReverse, .shuttleStop, .shuttleForward, .shuttleSlowReverse, .shuttleSlowForward, .playPause, .stepBackward,
        .stepForward, .stepBackward5, .stepForward5, .previousEditPoint, .nextEditPoint, .goToStart, .goToEnd, .markIn,
        .markOut, .goToIn, .goToOut, .clearInOut, .markClip, .clearIn, .clearOut, .playInToOut, .toggleLoop, .exportFrame,
        .newBin, .lift, .extract, .insert, .overwrite, .addMarker, .addEdit, .addEditAllTracks, .rippleTrimPrevious,
        .rippleTrimNext, .extendEdit, .rollTrimPrevious, .rollTrimNext, .trimPrevious, .trimNext, .enableClip, .duplicate,
        .toggleTrimType, .moveSelectionUp, .moveSelectionDown, .delete, .rippleDelete, .deleteProjectItems, .toggleSnapping,
        .matchFrame, .reverseMatchFrame, .link, .speedDuration, .toggleTimeRemapping, .removeTimeRemapping, .copy,
        .cut, .paste, .pasteAttributes, .undo, .redo, .selectClipAtPlayhead, .deselectAll, .nextEditPointAnyTrack,
        .previousEditPointAnyTrack, .pasteInsert, .selectAll, .toggleLinkedSelection, .markSelection, .nextMarker,
        .previousMarker, .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .trimBackward, .trimForward, .trimBackward5, .trimForward5, .zoomIn, .zoomOut,
        .zoomFit, .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter, .minimizeAllTracks,
        .expandAllTracks, .maximizePanel, .maximizeActivePanel, .resetLayout, .importMedia, .newSequence, .save, .export,
        .newProject, .openProject, .saveAs, .revert, .sequenceSettings, .setToFrameSize, .keyboardShortcuts, .preferences,
        .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation,
        .audioGain, .toggleAudioScrubbing, .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6,
        .matchLoudness, .autoDuck, .tagDialogue, .tagMusic, .tagSFX, .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold,
        .playInToOutRoll, .playAround, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub, .find, .applyVideoTransition,
        .applyAudioTransition, .applyDefaultTransitions, .toggleCaptionsInMonitor
    ]

    public static var all: [EditorCommand] {
        plain + EditorTool.allCases.map(EditorCommand.tool) + PanelID.allCases.map(EditorCommand.focusPanel)
    }

    /// The catalog united with everything the map binds and the menus list.
    public static func audited(_ map: CommandMap) -> [EditorCommand] {
        var seen = Set<EditorCommand>()
        var out: [EditorCommand] = []
        for c in all + map.entries.map(\.command) + EditorMenus.all.flatMap(\.commands) where seen.insert(c).inserted { out.append(c) }
        return out
    }
}
