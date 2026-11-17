// Swift: FCPCommandTable.swift
//! Final Cut Pro command identifier -> our command (`EditorCommand.id`, the stable names `sq.keymap` stores), and Final
//! Cut's own default key set. Only commands we really have are mapped (our own vocabulary on our side). Everything else
//! is reported by the importer.
//!
//! Where Final Cut's meaning differs a little from ours the row says so; those are judgment calls, kept honest here:
//! - Delete closes the gap on a magnetic timeline, so it maps to Ripple Delete; Replace with Gap leaves a gap (our Delete).
//! - Trim Start / Trim End (to playhead) are our Ripple Trim Previous / Next Edit to Playhead.
//! - The Trim tool is our Ripple tool (Final Cut's Trim tool ripples, rolls, slips and slides by where you grab).
//! - Blade at Playhead is Add Edit; Blade All is Add Edit to All Tracks.
//! - Select Clip (X) marks the clip's range, which is what X does in Final Cut.
//! - "Project" in Final Cut is our sequence, "Library" our project: New Project -> New Sequence, Open Library -> Open Project.
//!
//! `planned` rows are the Fast Cut (magnetic timeline) commands another agent is building. Their ids are reserved here
//! (`appendToMainTrack`, `insertSpacer`, `liftOffMainTrack`, `putOnMainTrack`): once an `EditorCommand` with that id
//! exists, imports and the Final Cut preset bind it with no change to this file.

use std::collections::BTreeMap;

use crate::foreign_keymap::{ForeignChord, ForeignCommand, Target};

/// The Final Cut command table.
pub struct FCPCommandTable;

/// (Final Cut id, our id, planned) in the order of the Swift table; a later row replaces an earlier one with the same id.
const ROWS: &[(&str, &str, bool)] = &[
    ("PlayPause", "playPause", false),
    ("Stop", "shuttleStop", false),
    ("JogBackward", "shuttleReverse", false),
    ("JogForward", "shuttleForward", false),
    ("PlayReverse", "shuttleReverse", false),
    ("JumpToPreviousFrame", "stepBackward", false),
    ("JumpToNextFrame", "stepForward", false),
    ("JumpToStart", "goToStart", false),
    ("JumpToEnd", "goToEnd", false),
    ("JumpBackward10Frames", "stepBackward10", false),
    ("JumpForward10Frames", "stepForward10", false),
    ("PlayToOut", "playToOut", false),
    ("NextKeyframe", "nextKeyframe", false),
    ("PreviousKeyframe", "previousKeyframe", false),
    ("Solo", "solo", false),
    ("DetachAudio", "unlink", false),
    ("TrimSelection", "trimToRange", false),
    ("PreviousEdit", "previousEditPoint", false),
    ("NextEdit", "nextEditPoint", false),
    ("Up", "previousEditPoint", false),
    ("Down", "nextEditPoint", false),
    ("LoopPlayback", "toggleLoop", false),
    ("ToggleAudioScrubbing", "toggleAudioScrubbing", false),
    ("SetSelectionStart", "markIn", false),
    ("SetSelectionEnd", "markOut", false),
    ("GotoIn", "goToIn", false),
    ("GotoOut", "goToOut", false),
    ("ClearSelection", "clearInOut", false),
    ("ClearSelectionStart", "clearIn", false),
    ("ClearSelectionEnd", "clearOut", false),
    ("SelectClip", "markClip", false),
    ("AddMarker", "addMarker", false),
    ("AddAndEditMarker", "addAndEditMarker", false),
    ("ModifyMarker", "editMarker", false),
    ("DeleteMarker", "clearMarker", false),
    ("DeleteMarkersInSelection", "clearAllMarkers", false),
    ("NextMarker", "nextMarker", false),
    ("PreviousMarker", "previousMarker", false),
    ("SelectToolArrowOrRangeSelection", "tool.selection", false),
    ("SelectToolTrim", "tool.ripple", false),
    ("SelectToolBlade", "tool.razor", false),
    ("SelectToolHand", "tool.hand", false),
    ("SelectToolZoom", "tool.zoom", false),
    ("BladeAtPlayhead", "addEdit", false),
    ("BladeAll", "addEditAllTracks", false),
    ("InsertMedia", "insert", false),
    ("OverwriteWithSelectedMedia", "overwrite", false),
    ("Delete", "rippleDelete", false),
    ("ReplaceWithGap", "delete", false),
    ("ExtendEdit", "extendEdit", false),
    ("TrimStart", "rippleTrimPrevious", false),
    ("TrimEnd", "rippleTrimNext", false),
    ("SelectClipAtPlayhead", "selectClipAtPlayhead", false),
    ("SelectNextItem", "selectNextClip", false),
    ("SelectPreviousItem", "selectPreviousClip", false),
    ("NudgeLeft", "nudgeLeft", false),
    ("NudgeRight", "nudgeRight", false),
    ("NudgeLeftMany", "nudgeLeft10", false),
    ("NudgeRightMany", "nudgeRight10", false),
    ("EnableOrDisableEdit", "enableClip", false),
    ("ToggleSnapping", "toggleSnapping", false),
    ("Duplicate", "duplicate", false),
    ("Cut", "cut", false),
    ("Copy", "copy", false),
    ("Paste", "paste", false),
    ("PasteAllAttributes", "pasteAttributes", false),
    ("UndoChanges", "undo", false),
    ("RedoChanges", "redo", false),
    ("SelectAll", "selectAll", false),
    ("DeselectAll", "deselectAll", false),
    ("AddTransition", "applyDefaultTransitions", false),
    ("AddBasicTitle", "addTitle", false),
    ("FreezeFrame", "addFrameHold", false),
    ("ShowRetimeEditor", "toggleTimeRemapping", false),
    ("RetimeReset", "removeTimeRemapping", false),
    ("RetimeCustomSpeed", "speedDuration", false),
    ("VolumeUp", "audioGainUp", false),
    ("VolumeDown", "audioGainDown", false),
    ("ZoomIn", "zoomIn", false),
    ("ZoomOut", "zoomOut", false),
    ("ZoomToFit", "zoomFit", false),
    ("GoToTimeline", "focusPanel.timeline", false),
    ("GoToViewer", "focusPanel.programMonitor", false),
    ("GoToInspector", "focusPanel.effectControls", false),
    ("ToggleInspector", "focusPanel.effectControls", false),
    ("ToggleMediaEffectsBrowser", "focusPanel.effects", false),
    ("Import", "importMedia", false),
    ("NewProject", "newSequence", false),
    ("NewFolder", "newBin", false),
    ("OpenLibrary", "openProject", false),
    ("ShareDefaultDestination", "export", false),
    ("ShowPreferences", "preferences", false),
    ("KeyboardCustomization", "keyboardShortcuts", false),
    ("Find", "find", false),
    ("MoveToTrash", "deleteProjectItems", false),
    ("JoinSelection", "joinCuts", false),
    ("SelectNextTimelineItem", "selectNextClip", false),
    ("SelectPreviousTimelineItem", "selectPreviousClip", false),
    ("NudgeUp", "moveSelectionUp", false),
    ("NudgeDown", "moveSelectionDown", false),
    ("CreateCompoundClip", "group", false),
    ("BreakApartClipItems", "ungroup", false),
    ("PasteAsConnected", "pasteAttached", false),
    ("RetimeHold", "insertFrameHold", false),
    ("ToggleSkimming", "toggleHoverScrub", false),
    ("ProjectInfo", "sequenceSettings", false),
    ("DefaultLayout", "resetLayout", false),
    ("GoToEventViewer", "focusPanel.sourceMonitor", false),
    ("ToggleEventViewer", "focusPanel.sourceMonitor", false),
    ("ToggleEventLibraryBrowser", "focusPanel.library", false),
    ("GoToColorBoard", "focusPanel.colorInspector", false),
    ("ToggleVideoScopes", "focusPanel.scopes", false),
    ("ToggleHistogram", "focusPanel.scopes", false),
    ("ToggleWaveform", "focusPanel.scopes", false),
    ("ToggleVectorscope", "focusPanel.scopes", false),
    ("ToggleAudioMeter", "focusPanel.audioMeter", false),
    ("ToggleMediaTransitionsBrowser", "focusPanel.effects", false),
    ("ToggleTimeline", "focusPanel.timeline", false),
    ("AnchorWithSelectedMedia", "placeOnTop", false),
    ("AnchorWithSelectedMediaBacktimed", "attachBacktimed", false),
    ("AppendWithSelectedMedia", "appendToMainTrack", true),
    ("InsertGap", "insertSpacer", true),
    ("LiftFromSpine", "liftOffMainTrack", true),
    ("CollapseToSpine", "putOnMainTrack", true),
];

impl FCPCommandTable {
    /// Final Cut command id -> target.
    pub fn rows() -> BTreeMap<String, Target> {
        let mut t: BTreeMap<String, Target> = BTreeMap::new();
        for (fcp, id, planned) in ROWS {
            let target = if *planned { Target::Planned((*id).to_string()) } else { Target::Command((*id).to_string()) };
            t.insert((*fcp).to_string(), target);
        }
        // Angle switches, added after the real-file audit (docs/KEYMAP.md "Final Cut import").
        for n in 1..=9 {
            let id = format!("switchAngle.{n}");
            t.insert(format!("SwitchAngle{n:02}"), Target::Command(id.clone()));
            t.insert(format!("CutSwitchAngle{n:02}"), Target::Command(id));
        }
        // macOS owns these.
        for id in ["Quit", "HideApplication", "HideOtherApplications", "Minimize", "CloseWindow"] {
            t.insert(id.to_string(), Target::System);
        }
        t
    }
}

/// Final Cut Pro's own default key set (US keyboard), written as Final Cut command ids and chords and imported through the
/// same table as a user's `.commandset`. From Apple's published "Final Cut Pro keyboard shortcuts" list as remembered, NOT
/// compared against a live copy: approximate (docs/KEYMAP.md). Commands we have no equivalent for are simply absent.
pub struct FCPDefaultSet;

const DEFAULT_SPEC: &[(&str, &[&str])] = &[
    ("PlayPause", &["space"]),
    ("Stop", &["k"]),
    ("JogBackward", &["j"]),
    ("JogForward", &["l"]),
    ("PlayReverse", &["shift+space"]),
    ("JumpToPreviousFrame", &["left"]),
    ("JumpToNextFrame", &["right"]),
    ("JumpToStart", &["home"]),
    ("JumpToEnd", &["end"]),
    ("PreviousEdit", &["up"]),
    ("NextEdit", &["down"]),
    ("JumpBackward10Frames", &["shift+left"]),
    ("JumpForward10Frames", &["shift+right"]),
    ("Solo", &["option+s"]),
    ("DetachAudio", &["control+shift+s"]),
    ("TrimSelection", &["option+\\"]),
    ("LoopPlayback", &["cmd+l"]),
    ("ToggleAudioScrubbing", &["shift+s"]),
    ("SetSelectionStart", &["i"]),
    ("SetSelectionEnd", &["o"]),
    ("GotoIn", &["shift+i"]),
    ("GotoOut", &["shift+o"]),
    ("ClearSelection", &["option+x"]),
    ("ClearSelectionStart", &["option+i"]),
    ("ClearSelectionEnd", &["option+o"]),
    ("SelectClip", &["x"]),
    ("AddMarker", &["m"]),
    ("AddAndEditMarker", &["option+m"]),
    ("DeleteMarker", &["control+m"]),
    ("DeleteMarkersInSelection", &["control+shift+m"]),
    ("NextMarker", &["control+'"]),
    ("PreviousMarker", &["control+;"]),
    ("SelectToolArrowOrRangeSelection", &["a"]),
    ("SelectToolTrim", &["t"]),
    ("SelectToolBlade", &["b"]),
    ("SelectToolHand", &["h"]),
    ("SelectToolZoom", &["z"]),
    ("BladeAtPlayhead", &["cmd+b"]),
    ("BladeAll", &["cmd+shift+b"]),
    ("AppendWithSelectedMedia", &["e"]),
    ("InsertMedia", &["w"]),
    ("OverwriteWithSelectedMedia", &["d"]),
    ("AnchorWithSelectedMedia", &["q"]),
    ("AnchorWithSelectedMediaBacktimed", &["shift+q"]),
    ("InsertGap", &["option+w"]),
    ("Delete", &["delete"]),
    ("ReplaceWithGap", &["shift+delete"]),
    ("ExtendEdit", &["shift+x"]),
    ("TrimStart", &["option+["]),
    ("TrimEnd", &["option+]"]),
    ("SelectClipAtPlayhead", &["c"]),
    ("NudgeLeft", &[","]),
    ("NudgeRight", &["."]),
    ("NudgeLeftMany", &["shift+,"]),
    ("NudgeRightMany", &["shift+."]),
    ("EnableOrDisableEdit", &["v"]),
    ("ToggleSnapping", &["n"]),
    ("Duplicate", &["cmd+d"]),
    ("Cut", &["cmd+x"]),
    ("Copy", &["cmd+c"]),
    ("Paste", &["cmd+v"]),
    ("PasteAllAttributes", &["cmd+option+v"]),
    ("UndoChanges", &["cmd+z"]),
    ("RedoChanges", &["cmd+shift+z"]),
    ("SelectAll", &["cmd+a"]),
    ("DeselectAll", &["cmd+shift+a"]),
    ("AddTransition", &["cmd+t"]),
    ("AddBasicTitle", &["control+t"]),
    ("FreezeFrame", &["option+f"]),
    ("ShowRetimeEditor", &["cmd+r"]),
    ("RetimeReset", &["cmd+option+r"]),
    ("RetimeCustomSpeed", &["control+option+r"]),
    ("VolumeUp", &["control+="]),
    ("VolumeDown", &["control+-"]),
    ("ZoomIn", &["cmd+="]),
    ("ZoomOut", &["cmd+-"]),
    ("ZoomToFit", &["shift+z"]),
    ("GoToTimeline", &["cmd+2"]),
    ("GoToViewer", &["cmd+3"]),
    ("ToggleInspector", &["cmd+4"]),
    ("ToggleMediaEffectsBrowser", &["cmd+5"]),
    ("Import", &["cmd+i"]),
    ("NewProject", &["cmd+n"]),
    ("NewFolder", &["cmd+shift+n"]),
    ("OpenLibrary", &["cmd+o"]),
    ("ShareDefaultDestination", &["cmd+e"]),
    ("ShowPreferences", &["cmd+,"]),
    ("KeyboardCustomization", &["option+cmd+k"]),
    ("Find", &["cmd+f"]),
    ("MoveToTrash", &["cmd+delete"]),
    ("CreateCompoundClip", &["option+g"]),
    ("BreakApartClipItems", &["cmd+shift+g"]),
    ("PasteAsConnected", &["cmd+shift+v"]),
    ("RetimeHold", &["shift+h"]),
    ("ProjectInfo", &["cmd+j"]),
];

impl FCPDefaultSet {
    /// The default commands with their chords.
    pub fn commands() -> Vec<ForeignCommand> {
        DEFAULT_SPEC
            .iter()
            .map(|(id, specs)| {
                ForeignCommand::new(id, specs.iter().filter_map(|s| ForeignChord::from_spec(s)).collect())
            })
            .collect()
    }
}
