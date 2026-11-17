//! Port of `ResolveCommandTable.swift`: DaVinci Resolve keyboard command ids mapped to our commands.

use crate::foreign_keymap::Target;

/// A row of the Resolve table.
#[derive(Clone, Copy)]
enum Row {
    Command(&'static str),
    System,
}

/// DaVinci Resolve keyboard command id (the left side of a line in its exported layout) -> our command.
/// Only ids seen in one real exported layout are known (UNVERIFIED beyond that, docs/KEYMAP.md); only commands we really
/// have are mapped. Judgment calls:
/// - `editDelete` (Shift+Del by default) is Resolve's ripple delete, `editBackspace` the plain delete that leaves a gap.
/// - `editBladeRazor` (Ctrl+B) cuts at the playhead: our Add Edit. `editBlade` is the Blade edit mode: our Razor tool.
/// - `editTrim` (Trim edit mode) is our Ripple tool. Ripple Start / End to Playhead are our Ripple Trim Previous / Next.
/// - Large step and multi-frame trim sizes are user settings in Resolve: left unmapped instead of guessing five or ten.
const RESOLVE_ROWS: [(&str, Row); 85] = [
    // Transport
    ("controlPlayToggle", Row::Command("playPause")),
    ("controlStop", Row::Command("shuttleStop")),
    ("controlPlayReverse", Row::Command("shuttleReverse")),
    ("controlPlayForward", Row::Command("shuttleForward")),
    ("controlPlaySlow", Row::Command("shuttleSlowForward")),
    ("controlStepReverse", Row::Command("stepBackward")),
    ("controlStepForward", Row::Command("stepForward")),
    ("controlTimelineStart", Row::Command("goToStart")),
    ("controlTimelineEnd", Row::Command("goToEnd")),
    ("controlFirstFrame", Row::Command("goToSelectedClipStart")),
    ("controlLastFrame", Row::Command("goToSelectedClipEnd")),
    ("controlClipPrev", Row::Command("previousEditPoint")),
    ("controlClipNext", Row::Command("nextEditPoint")),
    ("controlGotoIn", Row::Command("goToIn")),
    ("controlGotoOut", Row::Command("goToOut")),
    ("controlLoop", Row::Command("toggleLoop")),
    ("controlPlayAroundToPlayInToOut", Row::Command("playInToOut")),
    ("controlPlayAroundToPlayToOut", Row::Command("playToOut")),
    ("controlPlayAroundToPlayAroundCurrentFrame", Row::Command("playAround")),
    ("controlKeyframeNext", Row::Command("nextKeyframe")),
    ("controlKeyframePrev", Row::Command("previousKeyframe")),
    // Range and markers
    ("markIn", Row::Command("markIn")),
    ("markOut", Row::Command("markOut")),
    ("markClip", Row::Command("markClip")),
    ("markSelected", Row::Command("markSelection")),
    ("markResetIn", Row::Command("clearIn")),
    ("markResetOut", Row::Command("clearOut")),
    ("markResetInOut", Row::Command("clearInOut")),
    ("markMarkerAdd", Row::Command("addMarker")),
    ("markMarkerModify", Row::Command("editMarker")),
    ("markMarkerClear", Row::Command("clearMarker")),
    // Editing
    ("editBladeRazor", Row::Command("addEdit")),
    ("editBlade", Row::Command("tool.razor")),
    ("editPointer", Row::Command("tool.selection")),
    ("editTrim", Row::Command("tool.ripple")),
    ("editInsertOverwriteActionInsert", Row::Command("insert")),
    ("editInsertOverwriteActionOverwrite", Row::Command("overwrite")),
    ("editDelete", Row::Command("rippleDelete")),
    ("editBackspace", Row::Command("delete")),
    ("editNudgeTrimStepNudgeReverse", Row::Command("nudgeLeft")),
    ("editNudgeTrimStepNudgeForward", Row::Command("nudgeRight")),
    ("editNudgeTrimStepTrimStart", Row::Command("trimPrevious")),
    ("editNudgeTrimStepTrimEnd", Row::Command("trimNext")),
    ("trimRippleStartToPlayhead", Row::Command("rippleTrimPrevious")),
    ("trimRippleEndToPlayhead", Row::Command("rippleTrimNext")),
    ("editNudgeTrimStepExtendEdit", Row::Command("extendEdit")),
    ("editSelectItemAtPlayhead", Row::Command("selectClipAtPlayhead")),
    ("editMoveClipsUp", Row::Command("moveSelectionUp")),
    ("editMoveClipsDown", Row::Command("moveSelectionDown")),
    ("editClipEnabled", Row::Command("enableClip")),
    ("editSnapping", Row::Command("toggleSnapping")),
    ("editDuplicateSelection", Row::Command("duplicate")),
    ("editLink", Row::Command("link")),
    ("editLinkedSelection", Row::Command("toggleLinkedSelection")),
    ("editMatchFrame", Row::Command("matchFrame")),
    ("editM2JoinClip", Row::Command("joinCuts")),
    ("editAddTransition", Row::Command("applyDefaultTransitions")),
    ("editAddVideoTransition", Row::Command("applyVideoTransition")),
    ("editAddAudioTransition", Row::Command("applyAudioTransition")),
    // Clipboard / history / selection
    ("editCut", Row::Command("cut")),
    ("editCopy", Row::Command("copy")),
    ("editPaste", Row::Command("paste")),
    ("EditTimeline.editPasteInsert", Row::Command("pasteInsert")),
    ("editPasteAttributes", Row::Command("pasteAttributes")),
    ("editUndo", Row::Command("undo")),
    ("editRedo", Row::Command("redo")),
    ("editSelectAll", Row::Command("selectAll")),
    ("editDeselectAll", Row::Command("deselectAll")),
    // Retiming, audio
    ("clipRetimeControls", Row::Command("toggleTimeRemapping")),
    ("clipResetRetime", Row::Command("removeTimeRemapping")),
    ("clipAudioIncreaseAudioLevel1dB", Row::Command("audioGainUp")),
    ("clipAudioDecreaseAudioLevel1dB", Row::Command("audioGainDown")),
    // View
    ("viewZoomSubZoomIn", Row::Command("zoomIn")),
    ("viewZoomSubZoomOut", Row::Command("zoomOut")),
    ("viewZoomSubZoomToFit", Row::Command("zoomFit")),
    ("viewSafeAreaToggle", Row::Command("toggleSafeAreas")),
    // Media pool, file, app
    ("MediaPool.Context_setPosterFrame", Row::Command("setPosterFrame")),
    ("MediaPool.Context_clearPosterFrame", Row::Command("clearPosterFrame")),
    ("fileNewTimeline", Row::Command("newSequence")),
    ("fileNewProject", Row::Command("newProject")),
    ("fileNewFolder", Row::Command("newBin")),
    ("fileSaveProject", Row::Command("save")),
    ("fileSaveProjectAs", Row::Command("saveAs")),
    ("resolvePreferences", Row::Command("preferences")),
    // macOS owns these.
    ("resolveQuit", Row::System),
];

/// Every (command id, target) row of the table.
pub fn rows() -> impl Iterator<Item = (&'static str, Target)> {
    RESOLVE_ROWS.iter().map(|(n, r)| {
        (
            *n,
            match r {
                Row::Command(c) => Target::Command((*c).to_string()),
                Row::System => Target::System,
            },
        )
    })
}

/// The target of a DaVinci Resolve command id (Swift `ResolveCommandTable.rows[name]`); `None` for an unknown id.
pub fn resolve_target(name: &str) -> Option<Target> {
    RESOLVE_ROWS.iter().find(|(n, _)| *n == name).map(|(_, r)| match r {
        Row::Command(c) => Target::Command((*c).to_string()),
        Row::System => Target::System,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn ids_are_unique_and_known_rows_resolve() {
        let names: BTreeSet<&str> = RESOLVE_ROWS.iter().map(|(n, _)| *n).collect();
        assert_eq!(names.len(), RESOLVE_ROWS.len(), "a duplicate Resolve id would shadow the earlier row");
        assert_eq!(resolve_target("editBladeRazor"), Some(Target::Command("addEdit".to_string())));
        assert_eq!(resolve_target("editDelete"), Some(Target::Command("rippleDelete".to_string())));
        assert_eq!(resolve_target("resolveQuit"), Some(Target::System));
        assert_eq!(resolve_target("nope"), None);
    }
}
