import Foundation

/// DaVinci Resolve keyboard command id (the left side of a line in its exported layout) -> our command.
/// Only ids seen in one real exported layout are known (UNVERIFIED beyond that, docs/KEYMAP.md); only commands we really
/// have are mapped. Judgment calls:
/// - `editDelete` (Shift+Del by default) is Resolve's ripple delete, `editBackspace` the plain delete that leaves a gap.
/// - `editBladeRazor` (Ctrl+B) cuts at the playhead: our Add Edit. `editBlade` is the Blade edit mode: our Razor tool.
/// - `editTrim` (Trim edit mode) is our Ripple tool. Ripple Start / End to Playhead are our Ripple Trim Previous / Next.
/// - Large step and multi-frame trim sizes are user settings in Resolve: left unmapped instead of guessing five or ten.
public enum ResolveCommandTable {
    public static let rows: [String: ForeignKeymap.Target] = {
        var t: [String: ForeignKeymap.Target] = [:]
        func c(_ name: String, _ id: String) { t[name] = .command(id) }

        // Transport
        c("controlPlayToggle", "playPause"); c("controlStop", "shuttleStop")
        c("controlPlayReverse", "shuttleReverse"); c("controlPlayForward", "shuttleForward")
        c("controlPlaySlow", "shuttleSlowForward")
        c("controlStepReverse", "stepBackward"); c("controlStepForward", "stepForward")
        c("controlTimelineStart", "goToStart"); c("controlTimelineEnd", "goToEnd")
        c("controlFirstFrame", "goToSelectedClipStart"); c("controlLastFrame", "goToSelectedClipEnd")
        c("controlClipPrev", "previousEditPoint"); c("controlClipNext", "nextEditPoint")
        c("controlGotoIn", "goToIn"); c("controlGotoOut", "goToOut")
        c("controlLoop", "toggleLoop")
        c("controlPlayAroundToPlayInToOut", "playInToOut"); c("controlPlayAroundToPlayToOut", "playToOut")
        c("controlPlayAroundToPlayAroundCurrentFrame", "playAround")
        c("controlKeyframeNext", "nextKeyframe"); c("controlKeyframePrev", "previousKeyframe")
        // Range and markers
        c("markIn", "markIn"); c("markOut", "markOut"); c("markClip", "markClip"); c("markSelected", "markSelection")
        c("markResetIn", "clearIn"); c("markResetOut", "clearOut"); c("markResetInOut", "clearInOut")
        c("markMarkerAdd", "addMarker"); c("markMarkerModify", "editMarker"); c("markMarkerClear", "clearMarker")
        // Editing
        c("editBladeRazor", "addEdit"); c("editBlade", "tool.razor"); c("editPointer", "tool.selection"); c("editTrim", "tool.ripple")
        c("editInsertOverwriteActionInsert", "insert"); c("editInsertOverwriteActionOverwrite", "overwrite")
        c("editDelete", "rippleDelete"); c("editBackspace", "delete")
        c("editNudgeTrimStepNudgeReverse", "nudgeLeft"); c("editNudgeTrimStepNudgeForward", "nudgeRight")
        c("editNudgeTrimStepTrimStart", "trimPrevious"); c("editNudgeTrimStepTrimEnd", "trimNext")
        c("trimRippleStartToPlayhead", "rippleTrimPrevious"); c("trimRippleEndToPlayhead", "rippleTrimNext")
        c("editNudgeTrimStepExtendEdit", "extendEdit")
        c("editSelectItemAtPlayhead", "selectClipAtPlayhead")
        c("editMoveClipsUp", "moveSelectionUp"); c("editMoveClipsDown", "moveSelectionDown")
        c("editClipEnabled", "enableClip"); c("editSnapping", "toggleSnapping"); c("editDuplicateSelection", "duplicate")
        c("editLink", "link"); c("editLinkedSelection", "toggleLinkedSelection"); c("editMatchFrame", "matchFrame")
        c("editM2JoinClip", "joinCuts")
        c("editAddTransition", "applyDefaultTransitions")
        c("editAddVideoTransition", "applyVideoTransition"); c("editAddAudioTransition", "applyAudioTransition")
        // Clipboard / history / selection
        c("editCut", "cut"); c("editCopy", "copy"); c("editPaste", "paste"); c("EditTimeline.editPasteInsert", "pasteInsert")
        c("editPasteAttributes", "pasteAttributes")
        c("editUndo", "undo"); c("editRedo", "redo"); c("editSelectAll", "selectAll"); c("editDeselectAll", "deselectAll")
        // Retiming, audio
        c("clipRetimeControls", "toggleTimeRemapping"); c("clipResetRetime", "removeTimeRemapping")
        c("clipAudioIncreaseAudioLevel1dB", "audioGainUp"); c("clipAudioDecreaseAudioLevel1dB", "audioGainDown")
        // View
        c("viewZoomSubZoomIn", "zoomIn"); c("viewZoomSubZoomOut", "zoomOut"); c("viewZoomSubZoomToFit", "zoomFit")
        c("viewSafeAreaToggle", "toggleSafeAreas")
        // Media pool, file, app
        c("MediaPool.Context_setPosterFrame", "setPosterFrame"); c("MediaPool.Context_clearPosterFrame", "clearPosterFrame")
        c("fileNewTimeline", "newSequence"); c("fileNewProject", "newProject"); c("fileNewFolder", "newBin")
        c("fileSaveProject", "save"); c("fileSaveProjectAs", "saveAs")
        c("resolvePreferences", "preferences")
        // macOS owns these.
        t["resolveQuit"] = .system
        return t
    }()
}
