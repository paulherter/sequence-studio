import Foundation

/// Final Cut Pro command identifier -> our command (`EditorCommand.id`, the stable names `sq.keymap` stores).
/// Only commands we really have are mapped (our own vocabulary on our side). Everything else is reported by the importer.
///
/// Where Final Cut's meaning differs a little from ours the row says so; those are judgment calls, kept honest here:
/// - Delete closes the gap on a magnetic timeline, so it maps to Ripple Delete; Replace with Gap leaves a gap (our Delete).
/// - Trim Start / Trim End (to playhead) are our Ripple Trim Previous / Next Edit to Playhead.
/// - The Trim tool is our Ripple tool (Final Cut's Trim tool ripples, rolls, slips and slides by where you grab).
/// - Blade at Playhead is Add Edit; Blade All is Add Edit to All Tracks.
/// - Select Clip (X) marks the clip's range, which is what X does in Final Cut.
/// - "Project" in Final Cut is our sequence, "Library" our project: New Project -> New Sequence, Open Library -> Open Project.
///
/// `planned` rows are the Fast Cut (magnetic timeline) commands another agent is building. Their ids are reserved here
/// (`appendToMainTrack`, `insertSpacer`, `liftOffMainTrack`, `putOnMainTrack`): once an `EditorCommand` with that id exists, imports and the Final Cut preset bind it with no change
/// to this file. Until then the importer lists them as "not available yet". Rename the id here if the real command differs.
public enum FCPCommandTable {
    public static let rows: [String: ForeignKeymap.Target] = {
        var t: [String: ForeignKeymap.Target] = [:]
        func c(_ fcp: String, _ id: String) { t[fcp] = .command(id) }
        func planned(_ fcp: String, _ id: String) { t[fcp] = .planned(id) }

        // Transport
        c("PlayPause", "playPause"); c("Stop", "shuttleStop"); c("JogBackward", "shuttleReverse"); c("JogForward", "shuttleForward")
        c("PlayReverse", "shuttleReverse")
        c("JumpToPreviousFrame", "stepBackward"); c("JumpToNextFrame", "stepForward")
        c("JumpToStart", "goToStart"); c("JumpToEnd", "goToEnd")
        c("JumpBackward10Frames", "stepBackward10"); c("JumpForward10Frames", "stepForward10"); c("PlayToOut", "playToOut")
        c("NextKeyframe", "nextKeyframe"); c("PreviousKeyframe", "previousKeyframe")
        c("Solo", "solo"); c("DetachAudio", "unlink"); c("TrimSelection", "trimToRange")
        c("PreviousEdit", "previousEditPoint"); c("NextEdit", "nextEditPoint")
        c("Up", "previousEditPoint"); c("Down", "nextEditPoint")
        c("LoopPlayback", "toggleLoop"); c("ToggleAudioScrubbing", "toggleAudioScrubbing")
        // Range (In / Out)
        c("SetSelectionStart", "markIn"); c("SetSelectionEnd", "markOut")
        c("GotoIn", "goToIn"); c("GotoOut", "goToOut")
        c("ClearSelection", "clearInOut"); c("ClearSelectionStart", "clearIn"); c("ClearSelectionEnd", "clearOut")
        c("SelectClip", "markClip")
        // Markers
        c("AddMarker", "addMarker"); c("AddAndEditMarker", "addAndEditMarker"); c("ModifyMarker", "editMarker")
        c("DeleteMarker", "clearMarker"); c("DeleteMarkersInSelection", "clearAllMarkers")
        c("NextMarker", "nextMarker"); c("PreviousMarker", "previousMarker")
        // Tools
        c("SelectToolArrowOrRangeSelection", "tool.selection"); c("SelectToolTrim", "tool.ripple")
        c("SelectToolBlade", "tool.razor"); c("SelectToolHand", "tool.hand"); c("SelectToolZoom", "tool.zoom")
        // Editing
        c("BladeAtPlayhead", "addEdit"); c("BladeAll", "addEditAllTracks")
        c("InsertMedia", "insert"); c("OverwriteWithSelectedMedia", "overwrite")
        c("Delete", "rippleDelete"); c("ReplaceWithGap", "delete")
        c("ExtendEdit", "extendEdit"); c("TrimStart", "rippleTrimPrevious"); c("TrimEnd", "rippleTrimNext")
        c("SelectClipAtPlayhead", "selectClipAtPlayhead")
        c("SelectNextItem", "selectNextClip"); c("SelectPreviousItem", "selectPreviousClip")
        c("NudgeLeft", "nudgeLeft"); c("NudgeRight", "nudgeRight"); c("NudgeLeftMany", "nudgeLeft10"); c("NudgeRightMany", "nudgeRight10")
        c("EnableOrDisableEdit", "enableClip"); c("ToggleSnapping", "toggleSnapping")
        c("Duplicate", "duplicate")
        // Clipboard / history / selection
        c("Cut", "cut"); c("Copy", "copy"); c("Paste", "paste"); c("PasteAllAttributes", "pasteAttributes")
        c("UndoChanges", "undo"); c("RedoChanges", "redo"); c("SelectAll", "selectAll"); c("DeselectAll", "deselectAll")
        // Retiming, effects, titles
        c("AddTransition", "applyDefaultTransitions"); c("AddBasicTitle", "addTitle")
        c("FreezeFrame", "addFrameHold"); c("ShowRetimeEditor", "toggleTimeRemapping"); c("RetimeReset", "removeTimeRemapping")
        c("RetimeCustomSpeed", "speedDuration")
        c("VolumeUp", "audioGainUp"); c("VolumeDown", "audioGainDown")
        // View
        c("ZoomIn", "zoomIn"); c("ZoomOut", "zoomOut"); c("ZoomToFit", "zoomFit")
        c("GoToTimeline", "focusPanel.timeline"); c("GoToViewer", "focusPanel.programMonitor")
        c("GoToInspector", "focusPanel.effectControls"); c("ToggleInspector", "focusPanel.effectControls")
        c("ToggleMediaEffectsBrowser", "focusPanel.effects")
        // File / app
        c("Import", "importMedia"); c("NewProject", "newSequence"); c("NewFolder", "newBin"); c("OpenLibrary", "openProject")
        c("ShareDefaultDestination", "export"); c("ShowPreferences", "preferences"); c("KeyboardCustomization", "keyboardShortcuts")
        c("Find", "find"); c("MoveToTrash", "deleteProjectItems")

        // Added after the real-file audit (docs/KEYMAP.md "Final Cut import"): equivalents that had no row.
        c("JoinSelection", "joinCuts")
        c("SelectNextTimelineItem", "selectNextClip"); c("SelectPreviousTimelineItem", "selectPreviousClip")
        c("NudgeUp", "moveSelectionUp"); c("NudgeDown", "moveSelectionDown")           // lane move, not a vertical nudge
        c("CreateCompoundClip", "group"); c("BreakApartClipItems", "ungroup")           // compound clip = our layer Group
        c("PasteAsConnected", "pasteAttached")
        c("RetimeHold", "insertFrameHold")
        c("ToggleSkimming", "toggleHoverScrub")
        c("ProjectInfo", "sequenceSettings")
        c("DefaultLayout", "resetLayout")
        for n in 1...9 {
            let two = String(format: "%02d", n)
            c("SwitchAngle\(two)", "switchAngle.\(n)"); c("CutSwitchAngle\(two)", "switchAngle.\(n)")
        }
        c("GoToEventViewer", "focusPanel.sourceMonitor"); c("ToggleEventViewer", "focusPanel.sourceMonitor")
        c("ToggleEventLibraryBrowser", "focusPanel.library"); c("GoToColorBoard", "focusPanel.colorInspector")
        c("ToggleVideoScopes", "focusPanel.scopes"); c("ToggleHistogram", "focusPanel.scopes")
        c("ToggleWaveform", "focusPanel.scopes"); c("ToggleVectorscope", "focusPanel.scopes")
        c("ToggleAudioMeter", "focusPanel.audioMeter"); c("ToggleMediaTransitionsBrowser", "focusPanel.effects")
        c("ToggleTimeline", "focusPanel.timeline")
        // Connect = Place on Top (Fast Cut "attach"), backtimed has its own command.
        c("AnchorWithSelectedMedia", "placeOnTop"); c("AnchorWithSelectedMediaBacktimed", "attachBacktimed")

        // Fast Cut (magnetic timeline) commands, being built: bind automatically once they exist (TODO rows).
        planned("AppendWithSelectedMedia", "appendToMainTrack")
        planned("InsertGap", "insertSpacer")
        planned("LiftFromSpine", "liftOffMainTrack")
        planned("CollapseToSpine", "putOnMainTrack")

        // macOS owns these.
        for id in ["Quit", "HideApplication", "HideOtherApplications", "Minimize", "CloseWindow"] { t[id] = .system }
        return t
    }()
}

/// Final Cut Pro's own default key set (US keyboard), written as Final Cut command ids and chords and imported through the
/// same table as a user's `.commandset`. From Apple's published "Final Cut Pro keyboard shortcuts" list as remembered, NOT
/// compared against a live copy: approximate (docs/KEYMAP.md). Commands we have no equivalent for are simply absent.
public enum FCPDefaultSet {
    public static let commands: [ForeignCommand] = {
        let spec: [(String, [String])] = [
            ("PlayPause", ["space"]), ("Stop", ["k"]), ("JogBackward", ["j"]), ("JogForward", ["l"]), ("PlayReverse", ["shift+space"]),
            ("JumpToPreviousFrame", ["left"]), ("JumpToNextFrame", ["right"]), ("JumpToStart", ["home"]), ("JumpToEnd", ["end"]),
            ("PreviousEdit", ["up"]), ("NextEdit", ["down"]),
            ("JumpBackward10Frames", ["shift+left"]), ("JumpForward10Frames", ["shift+right"]),
            ("Solo", ["option+s"]), ("DetachAudio", ["control+shift+s"]), ("TrimSelection", ["option+\\"]),
            ("LoopPlayback", ["cmd+l"]), ("ToggleAudioScrubbing", ["shift+s"]),
            ("SetSelectionStart", ["i"]), ("SetSelectionEnd", ["o"]), ("GotoIn", ["shift+i"]), ("GotoOut", ["shift+o"]),
            ("ClearSelection", ["option+x"]), ("ClearSelectionStart", ["option+i"]), ("ClearSelectionEnd", ["option+o"]), ("SelectClip", ["x"]),
            ("AddMarker", ["m"]), ("AddAndEditMarker", ["option+m"]), ("DeleteMarker", ["control+m"]), ("DeleteMarkersInSelection", ["control+shift+m"]),
            ("NextMarker", ["control+'"]), ("PreviousMarker", ["control+;"]),
            ("SelectToolArrowOrRangeSelection", ["a"]), ("SelectToolTrim", ["t"]), ("SelectToolBlade", ["b"]),
            ("SelectToolHand", ["h"]), ("SelectToolZoom", ["z"]),
            ("BladeAtPlayhead", ["cmd+b"]), ("BladeAll", ["cmd+shift+b"]),
            ("AppendWithSelectedMedia", ["e"]), ("InsertMedia", ["w"]), ("OverwriteWithSelectedMedia", ["d"]),
            ("AnchorWithSelectedMedia", ["q"]), ("AnchorWithSelectedMediaBacktimed", ["shift+q"]), ("InsertGap", ["option+w"]),
            ("Delete", ["delete"]), ("ReplaceWithGap", ["shift+delete"]),
            ("ExtendEdit", ["shift+x"]), ("TrimStart", ["option+["]), ("TrimEnd", ["option+]"]), ("SelectClipAtPlayhead", ["c"]),
            ("NudgeLeft", [","]), ("NudgeRight", ["."]), ("NudgeLeftMany", ["shift+,"]), ("NudgeRightMany", ["shift+."]),
            ("EnableOrDisableEdit", ["v"]), ("ToggleSnapping", ["n"]), ("Duplicate", ["cmd+d"]),
            ("Cut", ["cmd+x"]), ("Copy", ["cmd+c"]), ("Paste", ["cmd+v"]), ("PasteAllAttributes", ["cmd+option+v"]),
            ("UndoChanges", ["cmd+z"]), ("RedoChanges", ["cmd+shift+z"]), ("SelectAll", ["cmd+a"]), ("DeselectAll", ["cmd+shift+a"]),
            ("AddTransition", ["cmd+t"]), ("AddBasicTitle", ["control+t"]),
            ("FreezeFrame", ["option+f"]), ("ShowRetimeEditor", ["cmd+r"]), ("RetimeReset", ["cmd+option+r"]), ("RetimeCustomSpeed", ["control+option+r"]),
            ("VolumeUp", ["control+="]), ("VolumeDown", ["control+-"]),
            ("ZoomIn", ["cmd+="]), ("ZoomOut", ["cmd+-"]), ("ZoomToFit", ["shift+z"]),
            ("GoToTimeline", ["cmd+2"]), ("GoToViewer", ["cmd+3"]), ("ToggleInspector", ["cmd+4"]), ("ToggleMediaEffectsBrowser", ["cmd+5"]),
            ("Import", ["cmd+i"]), ("NewProject", ["cmd+n"]), ("NewFolder", ["cmd+shift+n"]), ("OpenLibrary", ["cmd+o"]),
            ("ShareDefaultDestination", ["cmd+e"]), ("ShowPreferences", ["cmd+,"]), ("KeyboardCustomization", ["option+cmd+k"]),
            ("Find", ["cmd+f"]), ("MoveToTrash", ["cmd+delete"]),
            ("CreateCompoundClip", ["option+g"]), ("BreakApartClipItems", ["cmd+shift+g"]),
            ("PasteAsConnected", ["cmd+shift+v"]), ("RetimeHold", ["shift+h"]), ("ProjectInfo", ["cmd+j"]),
        ]
        return spec.map { ForeignCommand(sourceID: $0.0, chords: $0.1.compactMap { ForeignChord(spec: $0) }) }
    }()
}
