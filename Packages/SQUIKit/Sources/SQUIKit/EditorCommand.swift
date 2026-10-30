import Foundation
import SQCore

/// The timeline thumbnail modes as a command parameter. Same raw values as `SQTimelineUI.ThumbnailMode` (a test keeps them equal).
public enum ThumbnailModeChoice: String, Sendable, Hashable, CaseIterable {
    case head, headAndTail, continuous

    public var title: String {
        switch self {
        case .head: "Head"
        case .headAndTail: "Head and Tail"
        case .continuous: "Continuous"
        }
    }
}

/// The monitor view gamma as a command parameter. Same raw values as `SQRender.ViewGamma` (a test in SQMonitorUI keeps them equal).
public enum ViewGammaChoice: String, Sendable, Hashable, CaseIterable {
    case mac, web, broadcast

    public var title: String {
        switch self {
        case .mac: "Mac 1.96"
        case .web: "Web 2.2"
        case .broadcast: "Broadcast 2.4"
        }
    }
}

public enum EditorTool: String, Sendable, Hashable, CaseIterable {
    case selection, trackForward, trackBackward, ripple, rolling, slip, slide, razor, hand, zoom, type, rateStretch, mask
    /// Position (Shift+V, Fast Cut): a dragged clip overwrites where it lands and leaves a hole.
    case position
    /// Create tool modes next to `type` (Text): each selects the Create slot in that mode.
    case rectangle, ellipse, line, draw
}

/// Every command the keyboard map and the menus can trigger (docs/UX.md section 3).
public enum EditorCommand: Sendable, Hashable {
    // Transport. J/K/L go through `Shuttle` (see KeyRouter), the rest is plain.
    case shuttleReverse, shuttleStop, shuttleForward
    /// Shift+J / Shift+L: fine speed changes.
    case shuttleSlowReverse, shuttleSlowForward
    case playPause
    case stepBackward, stepForward, stepBackward5, stepForward5
    // Shift = 10 frames for every frame step. The "...5" ids (stepBackward5, nudgeLeft5, trimForward5, slideLeft5, slipLeft5 ...)
    // are stored in key sets and the Premiere table, so the names stay; they all mean 10 frames now.
    /// Jump 10 Frames (Final Cut shift+arrows), Play to Out, Next/Previous Keyframe, Solo, Unlink, Trim to In/Out: key-only
    /// commands that the Final Cut import fills; also in the menus, no default key.
    case stepBackward10, stepForward10, playToOut, nextKeyframe, previousKeyframe, solo, unlink, trimToRange
    /// Mute Selected Tracks (toggle, like Solo) and Detach Audio (the selected video clips lose their audio link and the
    /// audio clips become the selection): default keys Ctrl+Shift+M and Ctrl+Shift+D, both in the clip menu.
    case muteTracks, detachAudio
    case previousEditPoint, nextEditPoint
    case goToStart, goToEnd
    // Marking
    case markIn, markOut, goToIn, goToOut, clearInOut, markClip, clearIn, clearOut
    case playInToOut, toggleLoop, exportFrame, newBin
    case lift, extract, insert, overwrite, addMarker
    case bleep, newTone, toneSettings
    // Tools
    case tool(EditorTool)
    /// Slip tool, variant where the clip's keyframes stay on the timeline (Tools menu; the slot long-press has the same).
    case slipKeyframesStayTool
    // Editing
    case addEdit, addEditAllTracks, rippleTrimPrevious, rippleTrimNext, extendEdit
    /// Q/W variants: Shift = rolling (the cut moves), Option = plain trim (the gap stays).
    case rollTrimPrevious, rollTrimNext, trimPrevious, trimNext
    /// Clip > Enable (Shift+Cmd+E), Edit > Duplicate (Shift+Cmd+/), Ctrl+T trim type, Opt+Up/Down lane move.
    case enableClip, duplicate, toggleTrimType, toggleTrimMode, moveSelectionUp, moveSelectionDown
    /// Clip > Group (Cmd+G) / Ungroup (Shift+Cmd+G), W7.6.
    case group, ungroup
    /// Clip > Bundle (Opt+Cmd+G) / Unbundle (Opt+Shift+Cmd+G), v57: Premiere's selection groups under our own name (Cmd+G is
    /// the W7.6 layer Group). Clip > Make Subclip (Cmd+U) and Edit Original (Cmd+E), Premiere's keys.
    case bundle, unbundle, makeSubclip, editOriginal
    /// Sequence > Join Cuts (no key; Premiere calls it Join Through Edits): puts the leftovers of a blade back into one clip.
    case joinCuts
    /// Clip > Extend to Sequence End: toggles the flag on the selected Adjustment Layers.
    case extendToSequenceEnd
    /// Title templates: Save as Template… and the animation zones of the selected clip.
    case saveAsTemplate, toggleAnimationZones
    case delete, rippleDelete, deleteProjectItems
    case toggleSnapping, matchFrame, reverseMatchFrame, link
    /// Clip > Speed/Duration (Cmd+R).
    case speedDuration
    /// Clip > Reverse Clip: toggles the selected clips between playing forwards and backwards.
    case reverseClip
    /// Clip > Show Time Remapping: toggles the speed band on the selected video clips. Remove Time Remapping resets them to 100 %.
    case toggleTimeRemapping, removeTimeRemapping
    /// Clip > Add Speed Point: a no-change speed point at the playhead of the selected video clip (no default key; the user binds one).
    case addSpeedPoint
    // Clipboard / history
    case copy, cut, paste, pasteAttributes, undo, redo
    // Timeline selection, nudge, edit trims (Premiere: Cmd+Left/Right nudge, Opt+Shift+Left/Right trim 10 frames)
    case selectClipAtPlayhead, deselectAll, nextEditPointAnyTrack, previousEditPointAnyTrack
    /// Edit > Paste to Targeted Track: Cmd+V onto the lowest targeted track per kind (Premiere's pre-22.5 paste; unbound).
    case pasteToTargets
    /// Track targeting by key: toggles the target of video / audio track N (1-based, per kind). Ctrl+1...9 and Ctrl+Opt+1...9.
    case toggleTrackTarget(TrackKind, Int)
    /// Locks (or unlocks) every targeted track in one step (Ctrl+Shift+K).
    case toggleLockOfTargets
    /// Opt+] / Opt+[: select the graphic layer above / below the selected one (from the monitor or the list).
    case selectLayerAbove, selectLayerBelow
    case pasteInsert, selectAll, toggleLinkedSelection, toggleMagnetic, markSelection, nextMarker, previousMarker
    /// Playhead to the start of the next weak stretch of a tracked Magic mask (`MagicTrackHealth`, confidence strip).
    case nextWeakTracking
    case nudgeLeft, nudgeRight, nudgeLeft5, nudgeRight5, nudgeLeft10, nudgeRight10, trimBackward, trimForward, trimBackward5, trimForward5
    /// Premiere parity (2026-10): Clear Selected Marker (Opt+M) / Clear All Markers (Opt+Cmd+M), Select Next / Previous Clip on
    /// the track (Cmd+Down / Up), Go to Selected Clip Start / End, Slide Clip Selection (Opt+, / Opt+. with Shift = 10 frames).
    case clearMarker, clearAllMarkers, selectNextClip, selectPreviousClip, goToSelectedClipStart, goToSelectedClipEnd
    case slideLeft, slideRight, slideLeft5, slideRight5
    /// Split edit points: Mark Overhang (In/Out around the lead or trail of linked clips), Go to Next / Previous Split Point.
    case markOverhang, nextSplitPoint, previousSplitPoint
    /// Slip the selected clips' source by 1 / 10 frames (Opt+Cmd+Left/Right only; Opt+Left/Right with no edit selected says so).
    case slipLeft, slipRight, slipLeft5, slipRight5
    /// Project panel: Cmd+PageUp / Cmd+PageDown switch list / icon view, Cmd+[ / Cmd+] change the icon size.
    case projectListView, projectIconView, projectThumbnailSmaller, projectThumbnailLarger
    /// App-wide UI scale (View > Larger / Smaller / Actual Size, Cmd+Opt+= / - / 0): one step of `UIScale.steps`, applies on next launch.
    case uiScaleLarger, uiScaleSmaller, uiScaleReset
    // View / window
    case zoomIn, zoomOut, zoomFit
    // Track heights (Premiere: Cmd+=/- video, Option+=/- audio, Shift+= expand all, Shift+- minimize all)
    case videoTracksTaller, videoTracksShorter, audioTracksTaller, audioTracksShorter
    case minimizeAllTracks, expandAllTracks
    // Vertical zoom: every track taller / shorter (Ctrl+= / Ctrl+-), Fit All Tracks toggle (Ctrl+\)
    case allTracksTaller, allTracksShorter, toggleFitTracks
    case trackHeightSmall, trackHeightMedium, trackHeightLarge, trackHeightAuto
    case focusPanel(PanelID)
    case maximizePanel, maximizeActivePanel, resetLayout
    /// Moves keyboard focus to the next / previous visible panel (Ctrl+Shift+. and Ctrl+Shift+,).
    case selectNextPanel, selectPreviousPanel
    // File
    case importMedia, newSequence, save, export
    /// One-click export of the active sequence with its platform preset, no sheet (`ExportCoordinator.quickExport()`).
    case quickExport
    case newProject, openProject, saveAs, saveCopy, revert, closeProject, projectNotes, sequenceSettings, setToFrameSize, setToFillFrame
    // App
    case keyboardShortcuts, preferences
    /// Option+Space: floating search palette over effects, transitions, presets and commands.
    case quickApply
    // Keyframes: easing of the selected keyframes in Effect Controls (F9 family; Premiere has no default keys for these)
    case easyEase, easeIn, easeOut, toggleHoldInterpolation
    // Audio
    case audioGain, toggleAudioScrubbing
    /// `[` / `]` change the Audio Gain of the selected audio clips by 1 dB, with Shift by 6 dB.
    case audioGainDown, audioGainUp, audioGainDown6, audioGainUp6
    /// Markers on Beat (spectral beat grid of the selected audio or Music clips), and only the bar starts.
    case matchLoudness, autoDuck, addBeatMarkers, addMarkersOnDownbeats, removeSilences, removeFillerWords
    /// Text to speech: opens the voiceover dialog (voice made on this Mac, inserted at the playhead).
    case voiceover
    /// Record Voice-Over: countdown, then the microphone is recorded from the playhead while the sequence plays; the same
    /// command stops and places the take. No default key.
    case recordVoiceOver
    /// N8b: the project's own live ducking setting (on/off, amount; or follow Preferences).
    case projectLiveDucking
    /// Review step of Remove Silences: proposed-cut markers on the timeline.
    case reviewProposedCuts, acceptProposedCuts, rejectProposedCuts, acceptProposedCutAtPlayhead, rejectProposedCutAtPlayhead
    /// Sequence > Check Cuts: jump cuts, gaps, caption safe zones, audio pops as markers, plus edit stats.
    case checkCuts
    /// Sequence > Whoosh at Selected Cuts: the chosen (else first) item of the Library's SFX bin, centered on each selected cut.
    case whooshAtCuts
    /// Clip > Sync Audio to Reference: the earliest selected clip is the reference; the other selected clips are lined up
    /// to it by sound (with drift correction), else by capture date.
    case syncAudioToReference
    /// Sequence > Punch In Cuts…: alternating or cycling zoom levels over consecutive shots (sheet).
    case punchInCuts
    /// Sequence > Fill Reel…: the media items selected in the Project panel pour into the clips (slots) of the active
    /// sequence in order, into a copy or in place (sheet).
    case fillReel
    case tagDialogue, tagMusic, tagSFX
    /// Clip > Audio Options > Voice Chain: Dialogue role on the selected clips' tracks (voiced EQ, compressor, noise reduction).
    case voiceChain
    /// Clip > Audio Options > Disguise Voice: the Disguise Voice effect on the selected range plus captions for that range.
    case disguiseVoice
    // Clip > Video Options (effects-look): fade presets on the picture, frame holds
    case videoFadeIn, videoFadeOut, addFrameHold, insertFrameHold
    /// Clip > Video Options > Auto Reframe: Position keys that keep the subject in the sequence frame (SQAnalysis).
    case autoReframe
    /// Clip > Video Options > Anonymize: covers people with a Mosaic or a blur limited to tracked Magic masks (SQAnalysis).
    case anonymize
    /// Clip > Video Options > Dynamic Zoom In / Out: a start and an end window of the picture, eased (Ken Burns) as a Dynamic Zoom stage.
    case dynamicZoomIn, dynamicZoomOut, editDynamicZoom
    /// Clip > Video Options > Stabilize: Vision measures the camera shake, a Stabilizer stage (W9.7) removes it before Motion.
    case stabilize
    /// Clip > Video Options > Find Scene Changes: shot changes of the selected clips become proposed cuts (accept razors them).
    case findSceneChanges
    /// Clip > Video Options > Match Color to Clip: Exposure and Color Wheels so the clip looks like the clip under the
    /// playhead on another track (else the previous clip on its track); one-shot Color Match.
    case matchColorToClip
    /// W9.8 Clip > Video Options > Add Subject Mask: a mask that follows the person in the picture (Vision matte).
    case addSubjectMask
    /// Clip > Split Screen: lays the selected clips out in the frame (Scale, Position, Crop); `animated` adds slide in/out keys.
    case splitScreen(SplitLayoutPreset, animated: Bool)
    /// Clip > Speed Ramp Presets: one-click ramp; `onBeat` puts its peak on the nearest beat marker.
    case speedRampPreset(SpeedRampPreset, onBeat: Bool)
    /// F7.16 Clip > Angles: several recordings of one event become one Angles clip (dialog: name, sync, sound).
    case createAnglesClip
    /// F7.16: show angle 1...9 on the selected Angles pieces (or the piece under the playhead); while playing, cut at
    /// the playhead and show that angle from there on.
    case switchAngle(Int)
    /// Clip > Beat Edits: cut the selected clips at the beat markers / move their ends onto the beat markers.
    case cutToBeats, snapToBeats
    /// Clip > Fit Music to Length…: cut or loop the selected music clip at bars to the In/Out range or sequence end.
    case fitMusicToLength
    /// Clip > Video Options: explicit blurred-fill look for the selected clips (BlurredFill.swift in SQCore).
    case fitBlurredFill, fitCard, removeBlurredFill
    /// W8.2: Shift+P puts a static scale-up (PunchIn.swift in SQCore) on the selected video clips; again takes it off.
    case togglePunchIn
    /// W8.1: cut at the playhead, the rest goes to the alternate track (V1<->V2, A1<->A2) with an overlap and audio crossfade.
    case jumpCutAlternate
    /// J / L cut: moves only the audio (or only the video) edit of the nearest cut to the playhead (roll, one undo step).
    case splitEditAudio, splitEditVideo
    /// Fast cutting (Q-CUT1/2): one-key Cut Out (mark start, then extract), close the gap at the playhead, plain-key J / L cut.
    case cutOut, closeGapAtPlayhead, jCut, lCut
    /// Resolve F12 style: the Source clip (else the selected Project media) at the playhead on the next free upper video track.
    case placeOnTop
    /// Fast Cut (docs/research/FCP-MAGNETIC-TIMELINE.md): Ctrl+E, Ctrl+W, Opt+Cmd+Up, Opt+Cmd+Down; Set Attach Point has no key yet.
    case appendToMainTrack, insertSpacer, liftOffMainTrack, putOnMainTrack, setAttachPoint
    /// Fast Cut: Opt+V pastes the clipboard as attached clips at the playhead; Ctrl+Shift+. is Place on Top backtimed (the clip ends at the playhead).
    case pasteAttached, attachBacktimed
    /// Fast Cut storylines: Create Storyline (Ctrl+G; Cmd+G is Group) and Ripple Delete in Storyline (Ctrl+Shift+Delete).
    case createStoryline, storylineRippleDelete
    /// Fast Cut: Move Clip Left / Right swaps the selected main-track clip with its neighbor (Ctrl+Cmd+Left/Right, and Opt+Left/Right when no edit is selected); Delete Selection Only (Cmd+Opt+Delete) removes it and keeps its attached clips.
    case moveClipLeft, moveClipRight, deleteSelectionOnly
    // Source and Project flow: Play In to Out with preroll/postroll (Shift+Space), Play Around (Shift+K), poster frame
    // (Cmd+P / Option+P), Hover Scrub (Shift+H), Find (Cmd+F).
    case playInToOutRoll, playAround, setPosterFrame, clearPosterFrame, toggleHoverScrub, find
    // Transitions (Sequence menu): Cmd+D, Shift+Cmd+D, Shift+D
    case applyVideoTransition, applyAudioTransition, applyDefaultTransitions
    // Captions
    case toggleCaptionsInMonitor
    // View
    case toggleSafeAreas
    /// View > Show Overlays: hides or shows safe margins, guides and rulers in the monitor (settings are kept).
    case toggleOverlays
    /// View > View Gamma: how the monitor shows Rec.709 (display only, never the export).
    case viewGamma(ViewGammaChoice)
    /// Sequence menu: the clips under the playhead on the targeted tracks are selected as the playhead moves.
    case toggleSelectionFollowsPlayhead
    /// N5: the transcript word under the playhead becomes a big styled text clip (`EditorSession.addKeywordAtPlayhead`).
    case keywordAtPlayhead
    /// Workflow audit: the maintainer's title (two lines + emoji text clips with In animations) at the playhead (`EditorSession.addTitle`).
    case addTitle
    /// Workflow audit: transcribe the whole sequence (when needed) and create captions with the default caption look.
    case autoCaptions
    /// Shortcut import rest: Add Keyframe (the property last used in Controls, at the playhead), Play from Start, Toggle All
    /// Targets, Select Left / Right Edge (edges of the selected clips for the trim keys), Edit Marker (the marker at the
    /// playhead), Add and Edit Marker (adds one, then opens its dialog). No default key except Add Keyframe and Play from Start.
    case addKeyframe, playFromStart, toggleAllTargets, selectLeftEdge, selectRightEdge, editMarker, addAndEditMarker
    /// Go to Timecode (Ctrl+P, as in Final Cut): focuses the Program monitor's timecode field; type a time or +/- frames.
    /// Toggle Video / Audio Targets: like Toggle All Targets for the video or the audio tracks only (Cmd+9 / Cmd+0).
    case goToTimecode, toggleVideoTargets, toggleAudioTargets
    /// Nudge Audio / Video Edit: one frame (earlier / later) of the audio or the video half of the cut nearest to the playhead
    /// (`EditorSession.nudgeSplitEdit`), so a J / L cut can be tuned by key. Keys Ctrl+Opt+Left/Right and with Shift.
    case nudgeAudioEditLeft, nudgeAudioEditRight, nudgeVideoEditLeft, nudgeVideoEditRight
    /// Fit to Fill (the Source clip retimed into the sequence In..Out) and Replace Clip from Source (the one selected clip
    /// plays the Source clip, frame shown there lined up with the playhead). Menu only: the Source monitor buttons run the same.
    case fitToFill, replaceClipFromSource
    /// Replace With Clip from Project (Clip menu): the one selected clip plays the item selected in the Project panel.
    case replaceClipFromProject
    /// Clip > Replace and Fit > Replace at Playhead / from Start / from End / with Retime (Fast Cut): the selected main-track
    /// clip plays the Source clip (docs/NEXT F2). Menu only, no default key.
    case replaceMode(ReplaceMode)
    /// J / L Cut by Offset (Clip menu, no default key): the audio edit of the nearest cut moves a role offset (0.25 s dialogue,
    /// 0.5 s music) earlier or later (`EditorSession.offsetSplitEdit`); repeat to grow the split.
    case jCutByOffset, lCutByOffset
    /// File > Export Markers as CSV…: the marker list of the active sequence as a spreadsheet file (save panel).
    case exportMarkersCSV
    /// View > Timeline Thumbnails: what the thumbnails of video clips show (Head, Head and Tail, Continuous). A user preference.
    case thumbnailMode(ThumbnailModeChoice)
    /// Sequence > Add Video Track / Add Audio Track: one empty track on top of its kind (A8).
    case addVideoTrack, addAudioTrack
    /// Sequence > Remove Empty Tracks.
    case removeEmptyTracks
    /// Sequence > Delete Track: the targeted tracks with their clips (the lowest track of each kind stays).
    case deleteTrack
    /// View > Graph Editor: the speed-curve graph under the Effect Controls rows (D4).
    case toggleGraphEditor
    /// File: the interchange, Lottie, template and Premiere imports and exports that the app used to insert by hand (D25).
    case importTimeline, exportEDL, exportFCPXML, exportFinalCutXML, exportOpenTimelineIO
    case importLottie, importMotionGraphicsTemplate, importPremiereProject, importPremierePresets, importProject

    /// Auto-repeat (key held) re-fires these; everything else ignores repeats.
    public var isRepeatable: Bool {
        switch self {
        case .stepBackward, .stepForward, .stepBackward5, .stepForward5, .stepBackward10, .stepForward10, .nextKeyframe, .previousKeyframe,
             .previousEditPoint, .nextEditPoint, .nextEditPointAnyTrack, .previousEditPointAnyTrack, .zoomIn, .zoomOut,
             .nudgeLeft, .nudgeRight, .nudgeLeft5, .nudgeRight5, .nudgeLeft10, .nudgeRight10, .trimBackward, .trimForward, .trimBackward5, .trimForward5,
             .slideLeft, .slideRight, .slideLeft5, .slideRight5, .slipLeft, .slipRight, .slipLeft5, .slipRight5, .nudgeAudioEditLeft, .nudgeAudioEditRight, .nudgeVideoEditLeft, .nudgeVideoEditRight, .selectNextClip, .selectPreviousClip, .projectThumbnailSmaller, .projectThumbnailLarger,
             .videoTracksTaller, .videoTracksShorter, .audioTracksTaller, .audioTracksShorter, .allTracksTaller, .allTracksShorter,
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
        case .stepBackward5: "Step Back 10 Frames"
        case .stepForward5: "Step Forward 10 Frames"
        case .stepBackward10: "Jump Back 10 Frames"
        case .stepForward10: "Jump Forward 10 Frames"
        case .playToOut: "Play to Out"
        case .nextKeyframe: "Go to Next Keyframe"
        case .previousKeyframe: "Go to Previous Keyframe"
        case .solo: "Solo Selected Tracks"
        case .muteTracks: "Mute Selected Tracks"
        case .detachAudio: "Detach Audio"
        case .unlink: "Unlink"
        case .trimToRange: "Trim to In/Out"
        case .previousEditPoint: "Go to Previous Edit"
        case .nextEditPoint: "Go to Next Edit"
        case .goToStart: "Go to Sequence Start"
        case .goToEnd: "Go to Sequence End"
        case .markIn: "Mark In"
        case .markOut: "Mark Out"
        case .goToIn: "Go to In"
        case .goToOut: "Go to Out"
        case .clearInOut: "Remove In and Out"
        case .markClip: "Mark Clip"
        case .clearIn: "Remove In"
        case .clearOut: "Remove Out"
        case .playInToOut: "Play In to Out"
        case .toggleLoop: "Loop Playback"
        case .exportFrame: "Export Frame…"
        case .exportMarkersCSV: "Export Markers as CSV…"
        case .thumbnailMode(let m): m.title
        case .viewGamma(let g): g.title
        case .toggleOverlays: "Show Overlays"
        case .newBin: "New Folder"
        case .lift: "Clear Range"
        case .bleep: "Bleep"
        case .newTone: "New Tone…"
        case .toneSettings: "Tone Settings…"
        case .extract: "Delete Range"
        case .insert: "Insert"
        case .overwrite: "Overwrite"
        case .addMarker: "Add Marker"
        case .tool(let t):
            switch t {
            case .selection: "Select Tool"
            case .trackForward: "Select Forward Tool"
            case .trackBackward: "Select Backward Tool"
            case .ripple: "Ripple Tool"
            case .rolling: "Roll Tool"
            case .slip: "Slip Tool"
            case .slide: "Slide Tool"
            case .razor: "Blade Tool"
            case .hand: "Hand Tool"
            case .zoom: "Zoom Tool"
            case .type: "Text Tool"
            case .rectangle: "Rectangle Tool"
            case .ellipse: "Ellipse Tool"
            case .line: "Line Tool"
            case .draw: "Draw Tool"
            case .rateStretch: "Stretch Tool"
            case .mask: "Mask Tool"
            case .position: "Position Tool"
            }
        case .slipKeyframesStayTool: "Slip Tool (Keyframes Stay)"
        case .addEdit: "Add Edit"
        case .addEditAllTracks: "Add Edit to All Tracks"
        case .rippleTrimPrevious: "Ripple Trim Previous Edit to Playhead"
        case .rippleTrimNext: "Ripple Trim Next Edit to Playhead"
        case .extendEdit: "Extend Selected Edit to Playhead"
        case .rollTrimPrevious: "Roll Previous Edit to Playhead"
        case .rollTrimNext: "Roll Next Edit to Playhead"
        case .trimPrevious: "Trim Previous Edit to Playhead"
        case .trimNext: "Trim Next Edit to Playhead"
        case .group: "Group"
        case .ungroup: "Ungroup"
        case .bundle: "Bundle"
        case .unbundle: "Unbundle"
        case .joinCuts: "Join Cuts"
        case .makeSubclip: "Make Subclip"
        case .editOriginal: "Edit Original"
        case .extendToSequenceEnd: "Extend to Sequence End"
        case .saveAsTemplate: "Save as Template"
        case .toggleAnimationZones: "Keep Intro and Outro When Trimmed"
        case .enableClip: "Enable"
        case .duplicate: "Duplicate"
        case .toggleTrimType: "Toggle Trim Type"
        case .toggleTrimMode: "Trim Mode"
        case .moveSelectionUp: "Move Selection Up"
        case .moveSelectionDown: "Move Selection Down"
        case .delete: "Delete"
        case .rippleDelete: "Ripple Delete"
        case .deleteProjectItems: "Delete Project Items"
        case .toggleSnapping: "Snap"
        case .matchFrame: "Show in Source"
        case .reverseMatchFrame: "Show in Timeline"
        case .link: "Link"
        case .speedDuration: "Speed…"
        case .reverseClip: "Reverse Clip"
        case .toggleTimeRemapping: "Show Speed Ramp"
        case .removeTimeRemapping: "Remove Speed Ramp"
        case .addSpeedPoint: "Add Speed Point"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .pasteAttributes: "Paste Settings"
        case .selectClipAtPlayhead: "Select Clip at Playhead"
        case .deselectAll: "Deselect All"
        case .nextEditPointAnyTrack: "Go to Next Edit on Any Track"
        case .previousEditPointAnyTrack: "Go to Previous Edit on Any Track"
        case .pasteInsert: "Paste Insert"
        case .pasteToTargets: "Paste to Targeted Track"
        case .toggleTrackTarget(let k, let n): "Toggle Target \(k == .video ? "Video" : "Audio") Track \(n)"
        case .toggleLockOfTargets: "Lock or Unlock Targeted Tracks"
        case .selectAll: "Select All"
        case .selectLayerAbove: "Select Layer Above"
        case .selectLayerBelow: "Select Layer Below"
        case .toggleLinkedSelection: "Linked Selection"
        case .toggleMagnetic: "Fast Cut"
        case .appendToMainTrack: "Append to Main Track"
        case .insertSpacer: "Insert Spacer"
        case .liftOffMainTrack: "Lift off Main Track"
        case .putOnMainTrack: "Put on Main Track"
        case .setAttachPoint: "Set Attach Point"
        case .pasteAttached: "Paste Attached"
        case .attachBacktimed: "Attach Backtimed"
        case .createStoryline: "Create Storyline"
        case .storylineRippleDelete: "Ripple Delete in Storyline"
        case .moveClipLeft: "Move Clip Left"
        case .moveClipRight: "Move Clip Right"
        case .deleteSelectionOnly: "Delete Selection Only"
        case .markSelection: "Mark Selection"
        case .nextMarker: "Go to Next Marker"
        case .previousMarker: "Go to Previous Marker"
        case .nextWeakTracking: "Go to Next Weak Tracking"
        case .clearMarker: "Clear Selected Marker"
        case .clearAllMarkers: "Clear All Markers"
        case .selectNextClip: "Select Next Clip"
        case .selectPreviousClip: "Select Previous Clip"
        case .goToSelectedClipStart: "Go to Selected Clip Start"
        case .goToSelectedClipEnd: "Go to Selected Clip End"
        case .markOverhang: "Mark Overhang"
        case .nextSplitPoint: "Go to Next Split Point"
        case .previousSplitPoint: "Go to Previous Split Point"
        case .slideLeft: "Slide Clip Selection Left 1 Frame"
        case .slideRight: "Slide Clip Selection Right 1 Frame"
        case .slideLeft5: "Slide Clip Selection Left 10 Frames"
        case .slideRight5: "Slide Clip Selection Right 10 Frames"
        case .slipLeft: "Slip Clip Selection Left 1 Frame"
        case .slipRight: "Slip Clip Selection Right 1 Frame"
        case .slipLeft5: "Slip Clip Selection Left 10 Frames"
        case .slipRight5: "Slip Clip Selection Right 10 Frames"
        case .projectListView: "List View"
        case .projectIconView: "Icon View"
        case .projectThumbnailSmaller: "Smaller Thumbnails"
        case .projectThumbnailLarger: "Larger Thumbnails"
        case .uiScaleLarger: "Larger"
        case .uiScaleSmaller: "Smaller"
        case .uiScaleReset: "Actual Size"
        case .nudgeLeft: "Nudge Clip Selection Left 1 Frame"
        case .nudgeRight: "Nudge Clip Selection Right 1 Frame"
        case .nudgeLeft5: "Nudge Clip Selection Left by Many"
        case .nudgeRight5: "Nudge Clip Selection Right by Many"
        case .nudgeLeft10: "Nudge Clip Selection Left 10 Frames"
        case .nudgeRight10: "Nudge Clip Selection Right 10 Frames"
        case .trimBackward: "Trim Backward"
        case .trimForward: "Trim Forward"
        case .trimBackward5: "Trim Backward 10 Frames"
        case .trimForward5: "Trim Forward 10 Frames"
        case .undo: "Undo"
        case .redo: "Redo"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomFit: "Zoom to Fit"
        case .videoTracksTaller: "Increase Video Track Height"
        case .videoTracksShorter: "Decrease Video Track Height"
        case .audioTracksTaller: "Increase Audio Track Height"
        case .audioTracksShorter: "Decrease Audio Track Height"
        case .allTracksTaller: "Zoom In Vertically"
        case .allTracksShorter: "Zoom Out Vertically"
        case .toggleFitTracks: "Fit All Tracks to Height"
        case .minimizeAllTracks: "Minimize All Tracks"
        case .expandAllTracks: "Expand All Tracks"
        case .trackHeightSmall: "Small"
        case .trackHeightMedium: "Medium"
        case .trackHeightLarge: "Large"
        case .trackHeightAuto: "Auto"
        case .focusPanel(let p): "Show " + Self.panelTitle(p)
        case .speedRampPreset(let p, let onBeat): onBeat ? p.title + " on Beat" : p.title
        case .createAnglesClip: "Create Angles Clip…"
        case .switchAngle(let n): "Switch to Angle \(n)"
        case .cutToBeats: "Cut to Beats"
        case .snapToBeats: "Snap to Beats"
        case .fitMusicToLength: "Fit Music to Length…"
        case .splitScreen(let preset, let animated): animated ? preset.title + ", Animated" : preset.title
        case .maximizePanel: "Maximize Panel Under Pointer"
        case .maximizeActivePanel: "Maximize Active Panel"
        case .resetLayout: "Reset to Saved Layout"
        case .selectNextPanel: "Select Next Panel"
        case .selectPreviousPanel: "Select Previous Panel"
        case .importMedia: "Import…"
        case .newSequence: "New Sequence…"
        case .save: "Save"
        case .export: "Export…"
        case .quickExport: "Quick Export"
        case .newProject: "New Project"
        case .openProject: "Open Project…"
        case .saveAs: "Save As…"
        case .saveCopy: "Save a Copy…"
        case .revert: "Revert"
        case .closeProject: "Close Project"
        case .projectNotes: "Project Notes…"
        case .sequenceSettings: "Sequence Settings…"
        case .setToFrameSize: "Fit to Frame"
        case .setToFillFrame: "Fill Frame"
        case .keyboardShortcuts: "Keyboard Shortcuts…"
        case .preferences: "Settings…"
        case .quickApply: "Quick Apply…"
        case .easyEase: EaseName.smooth
        case .easeIn: EaseName.smoothIn
        case .easeOut: EaseName.smoothOut
        case .toggleHoldInterpolation: "Toggle Hold"
        case .audioGain: "Audio Gain…"
        case .toggleAudioScrubbing: "Audio Scrubbing"
        case .audioGainDown: "Decrease Audio Gain by 1 dB"
        case .audioGainUp: "Increase Audio Gain by 1 dB"
        case .audioGainDown6: "Decrease Audio Gain by 6 dB"
        case .audioGainUp6: "Increase Audio Gain by 6 dB"
        case .matchLoudness: "Match Loudness"
        case .autoDuck: "Bake Live Duck to Keys"
        case .addBeatMarkers: "Markers on Beat"
        case .addMarkersOnDownbeats: "Markers on Downbeats"
        case .projectLiveDucking: "Live Ducking for This Project…"
        case .removeSilences: "Remove Silences…"
        case .removeFillerWords: "Remove Filler Words"
        case .voiceover: "Voiceover from Text…"
        case .recordVoiceOver: "Record Voice-Over"
        case .acceptProposedCuts: "Accept All Proposed Cuts"
        case .reviewProposedCuts: "Review Proposed Cuts…"
        case .rejectProposedCuts: "Reject All Proposed Cuts"
        case .acceptProposedCutAtPlayhead: "Accept Proposed Cut at Playhead"
        case .rejectProposedCutAtPlayhead: "Reject Proposed Cut at Playhead"
        case .checkCuts: "Check Cuts…"
        case .whooshAtCuts: "Whoosh at Selected Cuts"
        case .syncAudioToReference: "Sync Audio to Reference"
        case .punchInCuts: "Punch In Cuts…"
        case .fillReel: "Fill Reel…"
        case .voiceChain: "Voice Chain"
        case .disguiseVoice: "Disguise Voice"
        case .tagDialogue: "Dialogue"
        case .tagMusic: "Music"
        case .tagSFX: "SFX"
        case .videoFadeIn: "Fade In"
        case .videoFadeOut: "Fade Out"
        case .addFrameHold: "Add Frame Hold"
        case .insertFrameHold: "Insert Frame Hold Segment"
        case .autoReframe: "Auto Reframe"
        case .anonymize: "Anonymize…"
        case .dynamicZoomIn: "Dynamic Zoom In"
        case .dynamicZoomOut: "Dynamic Zoom Out"
        case .editDynamicZoom: "Edit Dynamic Zoom"
        case .stabilize: "Stabilize"
        case .findSceneChanges: "Find Scene Changes"
        case .matchColorToClip: "Match Color to Clip"
        case .addSubjectMask: "Add Subject Mask"
        case .fitBlurredFill: "Fit with Blurred Fill"
        case .fitCard: "Card with Blurred Background"
        case .removeBlurredFill: "Remove Blurred Fill"
        case .togglePunchIn: "Punch In"
        case .jumpCutAlternate: "Jump Cut to Alternate Track"
        case .splitEditAudio: "Move Audio Edit to Playhead"
        case .splitEditVideo: "Move Video Edit to Playhead"
        case .cutOut: "Cut Out (Mark Start, then Delete Range)"
        case .closeGapAtPlayhead: "Close Gap at Playhead"
        case .placeOnTop: "Place on Top"
        case .addVideoTrack: "Add Video Track"
        case .addAudioTrack: "Add Audio Track"
        case .removeEmptyTracks: "Remove Empty Tracks"
        case .deleteTrack: "Delete Track"
        case .toggleGraphEditor: "Graph Editor"
        case .importTimeline: "Import Timeline…"
        case .exportEDL: "Export EDL…"
        case .exportFCPXML: "Export FCPXML…"
        case .exportFinalCutXML: "Export Final Cut Pro XML…"
        case .exportOpenTimelineIO: "Export OpenTimelineIO…"
        case .importLottie: "Import Lottie Animation…"
        case .importMotionGraphicsTemplate: "Import Motion Graphics Template…"
        case .importPremiereProject: "Import Premiere Project…"
        case .importPremierePresets: "Import Premiere Presets…"
        case .importProject: "Import Project…"
        case .jCut: "J Cut (Audio Leads)"
        case .jCutByOffset: "J Cut by Offset"
        case .lCutByOffset: "L Cut by Offset"
        case .nudgeAudioEditLeft: "Nudge Audio Edit Left 1 Frame"
        case .nudgeAudioEditRight: "Nudge Audio Edit Right 1 Frame"
        case .nudgeVideoEditLeft: "Nudge Video Edit Left 1 Frame"
        case .nudgeVideoEditRight: "Nudge Video Edit Right 1 Frame"
        case .fitToFill: "Fit to Fill"
        case .replaceClipFromSource: "Replace Clip from Source"
        case .replaceClipFromProject: "Replace Clip from Project"
        case .replaceMode(let m): m.title
        case .lCut: "L Cut (Audio Trails)"
        case .playInToOutRoll: "Play In to Out with Preroll/Postroll"
        case .playAround: "Play Around"
        case .setPosterFrame: "Set Poster Frame"
        case .clearPosterFrame: "Delete Poster Frame"
        case .toggleHoverScrub: "Hover Scrub"
        case .find: "Find…"
        case .applyVideoTransition: "Apply Video Transition"
        case .applyAudioTransition: "Apply Audio Transition"
        case .applyDefaultTransitions: "Apply Default Transitions to Selection"
        case .toggleCaptionsInMonitor: "Show Captions in Program"
        case .toggleSafeAreas: "Safe Margins"
        case .toggleSelectionFollowsPlayhead: "Selection Follows Playhead"
        case .keywordAtPlayhead: "Keyword at Playhead"
        case .addTitle: "Add Title"
        case .autoCaptions: "Transcribe and Create Captions"
        case .addKeyframe: "Add Keyframe"
        case .playFromStart: "Play from Start"
        case .toggleAllTargets: "Toggle All Targets"
        case .goToTimecode: "Go to Timecode…"
        case .toggleVideoTargets: "Toggle Video Targets"
        case .toggleAudioTargets: "Toggle Audio Targets"
        case .selectLeftEdge: "Select Left Edge"
        case .selectRightEdge: "Select Right Edge"
        case .editMarker: "Edit Marker…"
        case .addAndEditMarker: "Add and Edit Marker…"
        }
    }

    /// Panel name in the UI language (`panelTitle` stays English: tests, keys and logs use it).
    public static func localizedPanelTitle(_ p: PanelID) -> String { SQL10n.string(panelTitle(p)) }

    public static func panelTitle(_ p: PanelID) -> String {
        switch p {
        case .effectControls: "Controls"
        case .text: "Captions"
        case .colorInspector: "Color"
        case .colorClips: "Sources"
        case .steps: "Steps"
        case .scopes: "Scopes"
        case .graphics: "Graphics"
        case .programMonitor: "Program"
        case .sourceMonitor: "Source"
        case .library: "Library"
        case .effects: "Effects"
        case .keystones: "Keystones"
        case .markerList: "Marker List"
        case .project: "Project"
        case .timeline: "Timeline"
        case .audioMeter: "Audio Meters"
        }
    }
}

/// Where a binding applies. `global` is the fallback behind every focus-specific scope.
public enum CommandScope: Sendable, Hashable, CaseIterable {
    case global, timeline, program, source, project, effectControls

    /// Scope of a focused panel; panels without own bindings use only `global`.
    public static func scope(for panel: PanelID?) -> CommandScope? {
        switch panel {
        case .timeline: .timeline
        case .programMonitor: .program
        case .sourceMonitor: .source
        case .project, .library: .project
        case .effectControls: .effectControls
        default: nil
        }
    }
}

extension EditorCommand {
    /// Frames the selected keyframes move when Effect Controls has keyboard focus with keys selected (Final Cut:
    /// Comma / Period, Shift = 10). Without that focus the same keys keep their meaning: `,` `.` are Insert / Overwrite,
    /// Shift+, / Shift+. Keystones / Place on Top, the nudge commands move clips. nil = not a nudge key.
    public var keyframeNudgeFrames: Int? {
        switch self {
        case .insert, .nudgeLeft: -1
        case .overwrite, .nudgeRight: 1
        case .focusPanel(.keystones), .nudgeLeft10: -10
        case .nudgeLeft5: -10
        case .placeOnTop, .nudgeRight10: 10
        case .nudgeRight5: 10
        default: nil
        }
    }
}
