import Foundation

public enum EditorTool: String, Sendable, Hashable, CaseIterable {
    case selection, trackForward, trackBackward, ripple, rolling, slip, slide, razor, hand, zoom, type, rateStretch
}

/// Every command the keyboard map and the menus can trigger (docs/UX.md section 3).
public enum EditorCommand: Sendable, Hashable {
    // Transport. J/K/L go through `Shuttle` (see KeyRouter), the rest is plain.
    case shuttleReverse, shuttleStop, shuttleForward
    /// Shift+J / Shift+L: fine speed changes.
    case shuttleSlowReverse, shuttleSlowForward
    case playPause
    case stepBackward, stepForward, stepBackward5, stepForward5
    case previousEditPoint, nextEditPoint
    case goToStart, goToEnd
    // Marking
    case markIn, markOut, goToIn, goToOut, clearInOut, markClip, clearIn, clearOut
    case playInToOut, toggleLoop, exportFrame, newBin
    case lift, extract, insert, overwrite, addMarker
    // Tools
    case tool(EditorTool)
    // Editing
    case addEdit, addEditAllTracks, rippleTrimPrevious, rippleTrimNext, extendEdit
    /// Q/W variants: Shift = rolling (the cut moves), Option = plain trim (the gap stays).
    case rollTrimPrevious, rollTrimNext, trimPrevious, trimNext
    /// Clip > Enable (Shift+Cmd+E), Edit > Duplicate (Shift+Cmd+/), Ctrl+T trim type, Opt+Up/Down lane move.
    case enableClip, duplicate, toggleTrimType, moveSelectionUp, moveSelectionDown
    case delete, rippleDelete, deleteProjectItems
    case toggleSnapping, matchFrame, reverseMatchFrame, link
    /// Clip > Speed/Duration (Cmd+R).
    case speedDuration
    /// Clip > Show Time Remapping: toggles the speed band on the selected video clips. Remove Time Remapping resets them to 100 %.
    case toggleTimeRemapping, removeTimeRemapping
    // Clipboard / history
    case copy, cut, paste, pasteAttributes, undo, redo
    // Timeline selection, nudge, edit trims (Premiere: Cmd+Left/Right nudge, Opt+Shift+Left/Right trim 5 frames)
    case selectClipAtPlayhead, deselectAll, nextEditPointAnyTrack, previousEditPointAnyTrack
    case pasteInsert, selectAll, toggleLinkedSelection, markSelection, nextMarker, previousMarker
    case nudgeLeft, nudgeRight, nudgeLeft5, nudgeRight5, trimBackward, trimForward, trimBackward5, trimForward5
    // View / window
    case zoomIn, zoomOut, zoomFit
    // Track heights (Premiere: Cmd+=/- video, Option+=/- audio, Shift+= expand all, Shift+- minimize all)
    case videoTracksTaller, videoTracksShorter, audioTracksTaller, audioTracksShorter
    case minimizeAllTracks, expandAllTracks
    case focusPanel(PanelID)
    case maximizePanel, maximizeActivePanel, resetLayout
    // File
    case importMedia, newSequence, save, export
    case newProject, openProject, saveAs, revert, sequenceSettings, setToFrameSize
    // App
    case keyboardShortcuts, preferences
    // Keyframes: easing of the selected keyframes in Effect Controls (F9 family; Premiere has no default keys for these)
    case easyEase, easeIn, easeOut, toggleHoldInterpolation
    // Audio
    case audioGain, toggleAudioScrubbing
    /// `[` / `]` change the Audio Gain of the selected audio clips by 1 dB, with Shift by 6 dB.
    case audioGainDown, audioGainUp, audioGainDown6, audioGainUp6
    case matchLoudness, autoDuck, removeSilences
    case tagDialogue, tagMusic, tagSFX
    // Clip > Video Options (effects-look): fade presets on the picture, frame holds
    case videoFadeIn, videoFadeOut, addFrameHold, insertFrameHold
    // Source and Project flow: Play In to Out with preroll/postroll (Shift+Space), Play Around (Shift+K), poster frame
    // (Cmd+P / Option+P), Hover Scrub (Shift+H), Find (Cmd+F).
    case playInToOutRoll, playAround, setPosterFrame, clearPosterFrame, toggleHoverScrub, find
    // Transitions (Sequence menu): Cmd+D, Shift+Cmd+D, Shift+D
    case applyVideoTransition, applyAudioTransition, applyDefaultTransitions
    // Captions
    case toggleCaptionsInMonitor

    /// Auto-repeat (key held) re-fires these; everything else ignores repeats.
    public var isRepeatable: Bool {
        switch self {
        case .stepBackward, .stepForward, .stepBackward5, .stepForward5,
             .previousEditPoint, .nextEditPoint, .nextEditPointAnyTrack, .previousEditPointAnyTrack, .zoomIn, .zoomOut,
             .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .trimBackward, .trimForward, .trimBackward5, .trimForward5,
             .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter,
             .undo, .redo, .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6: true
        default: false
        }
    }

    /// Menu title (English).
    public var title: String {
        switch self {
        case .shuttleReverse: "Shuttle Reverse"
        case .shuttleStop: "Shuttle Stop"
        case .shuttleSlowReverse: "Shuttle Slow Reverse"
        case .shuttleSlowForward: "Shuttle Slow Forward"
        case .shuttleForward: "Shuttle Forward"
        case .playPause: "Play/Pause"
        case .stepBackward: "Step Back 1 Frame"
        case .stepForward: "Step Forward 1 Frame"
        case .stepBackward5: "Step Back 5 Frames"
        case .stepForward5: "Step Forward 5 Frames"
        case .previousEditPoint: "Go to Previous Edit Point"
        case .nextEditPoint: "Go to Next Edit Point"
        case .goToStart: "Go to Sequence Start"
        case .goToEnd: "Go to Sequence End"
        case .markIn: "Mark In"
        case .markOut: "Mark Out"
        case .goToIn: "Go to In"
        case .goToOut: "Go to Out"
        case .clearInOut: "Clear In and Out"
        case .markClip: "Mark Clip"
        case .clearIn: "Clear In"
        case .clearOut: "Clear Out"
        case .playInToOut: "Play In to Out"
        case .toggleLoop: "Loop Playback"
        case .exportFrame: "Export Frame…"
        case .newBin: "New Bin"
        case .lift: "Lift"
        case .extract: "Extract"
        case .insert: "Insert"
        case .overwrite: "Overwrite"
        case .addMarker: "Add Marker"
        case .tool(let t):
            switch t {
            case .selection: "Selection Tool"
            case .trackForward: "Track Select Forward Tool"
            case .trackBackward: "Track Select Backward Tool"
            case .ripple: "Ripple Edit Tool"
            case .rolling: "Rolling Edit Tool"
            case .slip: "Slip Tool"
            case .slide: "Slide Tool"
            case .razor: "Razor Tool"
            case .hand: "Hand Tool"
            case .zoom: "Zoom Tool"
            case .type: "Type Tool"
            case .rateStretch: "Rate Stretch Tool"
            }
        case .addEdit: "Add Edit"
        case .addEditAllTracks: "Add Edit to All Tracks"
        case .rippleTrimPrevious: "Ripple Trim Previous Edit to Playhead"
        case .rippleTrimNext: "Ripple Trim Next Edit to Playhead"
        case .extendEdit: "Extend Selected Edit to Playhead"
        case .rollTrimPrevious: "Roll Previous Edit to Playhead"
        case .rollTrimNext: "Roll Next Edit to Playhead"
        case .trimPrevious: "Trim Previous Edit to Playhead"
        case .trimNext: "Trim Next Edit to Playhead"
        case .enableClip: "Enable"
        case .duplicate: "Duplicate"
        case .toggleTrimType: "Toggle Trim Type"
        case .moveSelectionUp: "Move Selection Up"
        case .moveSelectionDown: "Move Selection Down"
        case .delete: "Delete"
        case .rippleDelete: "Ripple Delete"
        case .deleteProjectItems: "Delete Project Items"
        case .toggleSnapping: "Snap"
        case .matchFrame: "Match Frame"
        case .reverseMatchFrame: "Reverse Match Frame"
        case .link: "Link"
        case .speedDuration: "Speed/Duration…"
        case .toggleTimeRemapping: "Show Time Remapping"
        case .removeTimeRemapping: "Remove Time Remapping"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .pasteAttributes: "Paste Attributes"
        case .selectClipAtPlayhead: "Select Clip at Playhead"
        case .deselectAll: "Deselect All"
        case .nextEditPointAnyTrack: "Go to Next Edit Point on Any Track"
        case .previousEditPointAnyTrack: "Go to Previous Edit Point on Any Track"
        case .pasteInsert: "Paste Insert"
        case .selectAll: "Select All"
        case .toggleLinkedSelection: "Linked Selection"
        case .markSelection: "Mark Selection"
        case .nextMarker: "Go to Next Marker"
        case .previousMarker: "Go to Previous Marker"
        case .nudgeLeft: "Nudge Clip Selection Left 1 Frame"
        case .nudgeRight: "Nudge Clip Selection Right 1 Frame"
        case .nudgeLeft5: "Nudge Clip Selection Left 5 Frames"
        case .nudgeRight5: "Nudge Clip Selection Right 5 Frames"
        case .trimBackward: "Trim Backward"
        case .trimForward: "Trim Forward"
        case .trimBackward5: "Trim Backward 5 Frames"
        case .trimForward5: "Trim Forward 5 Frames"
        case .undo: "Undo"
        case .redo: "Redo"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomFit: "Zoom to Fit"
        case .videoTracksTaller: "Increase Video Track Height"
        case .videoTracksShorter: "Decrease Video Track Height"
        case .audioTracksTaller: "Increase Audio Track Height"
        case .audioTracksShorter: "Decrease Audio Track Height"
        case .minimizeAllTracks: "Minimize All Tracks"
        case .expandAllTracks: "Expand All Tracks"
        case .focusPanel(let p): "Show " + Self.panelTitle(p)
        case .maximizePanel: "Maximize Panel Under Pointer"
        case .maximizeActivePanel: "Maximize Active Panel"
        case .resetLayout: "Reset to Saved Layout"
        case .importMedia: "Import Media…"
        case .newSequence: "New Sequence…"
        case .save: "Save"
        case .export: "Export…"
        case .newProject: "New Project"
        case .openProject: "Open Project…"
        case .saveAs: "Save As…"
        case .revert: "Revert"
        case .sequenceSettings: "Sequence Settings…"
        case .setToFrameSize: "Set to Frame Size"
        case .keyboardShortcuts: "Keyboard Shortcuts…"
        case .preferences: "Settings…"
        case .easyEase: "Easy Ease"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .toggleHoldInterpolation: "Toggle Hold Interpolation"
        case .audioGain: "Audio Gain…"
        case .toggleAudioScrubbing: "Audio Scrubbing"
        case .audioGainDown: "Decrease Audio Gain by 1 dB"
        case .audioGainUp: "Increase Audio Gain by 1 dB"
        case .audioGainDown6: "Decrease Audio Gain by 6 dB"
        case .audioGainUp6: "Increase Audio Gain by 6 dB"
        case .matchLoudness: "Match Loudness"
        case .autoDuck: "Auto Duck Music"
        case .removeSilences: "Remove Silences…"
        case .tagDialogue: "Dialogue"
        case .tagMusic: "Music"
        case .tagSFX: "SFX"
        case .videoFadeIn: "Fade In"
        case .videoFadeOut: "Fade Out"
        case .addFrameHold: "Add Frame Hold"
        case .insertFrameHold: "Insert Frame Hold Segment"
        case .playInToOutRoll: "Play In to Out with Preroll/Postroll"
        case .playAround: "Play Around"
        case .setPosterFrame: "Set Poster Frame"
        case .clearPosterFrame: "Clear Poster Frame"
        case .toggleHoverScrub: "Hover Scrub"
        case .find: "Find…"
        case .applyVideoTransition: "Apply Video Transition"
        case .applyAudioTransition: "Apply Audio Transition"
        case .applyDefaultTransitions: "Apply Default Transitions to Selection"
        case .toggleCaptionsInMonitor: "Show Captions in Program Monitor"
        }
    }

    public static func panelTitle(_ p: PanelID) -> String {
        switch p {
        case .effectControls: "Effect Controls"
        case .text: "Text"
        case .colorInspector: "Color"
        case .scopes: "Scopes"
        case .programMonitor: "Program"
        case .sourceMonitor: "Source"
        case .library: "Library"
        case .effects: "Effects"
        case .project: "Project"
        case .timeline: "Timeline"
        case .audioMeter: "Audio Meters"
        }
    }
}

/// Where a binding applies. `global` is the fallback behind every focus-specific scope.
public enum CommandScope: Sendable, Hashable, CaseIterable {
    case global, timeline, program, source, project

    /// Scope of a focused panel; panels without own bindings use only `global`.
    public static func scope(for panel: PanelID?) -> CommandScope? {
        switch panel {
        case .timeline: .timeline
        case .programMonitor: .program
        case .sourceMonitor: .source
        case .project, .library: .project
        default: nil
        }
    }
}
