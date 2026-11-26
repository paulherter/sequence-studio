//! Port of `SQUIKit/Sources/SQUIKit/EditorCommand.swift`.

use crate::localization::SQL10n;
use crate::panel_id::PanelID;
use sq_core_edit::timeline_replace_modes::ReplaceMode;
use sq_core_effects::speed_ramp_preset::SpeedRampPreset;
use sq_core_graphics::split_layout::SplitLayoutPreset;
use sq_core_model::TrackKind;
use sq_core_time::ease_names::ease_name;

/// The timeline thumbnail modes as a command parameter. Same raw values as `SQTimelineUI.ThumbnailMode` (a test keeps them equal).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ThumbnailModeChoice {
    Head,
    HeadAndTail,
    Continuous,
}

impl ThumbnailModeChoice {
    pub const ALL: [ThumbnailModeChoice; 3] = [Self::Head, Self::HeadAndTail, Self::Continuous];

    /// The Swift raw value (`head`, `headAndTail`, `continuous`).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Head => "head",
            Self::HeadAndTail => "headAndTail",
            Self::Continuous => "continuous",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Head => "Head",
            Self::HeadAndTail => "Head and Tail",
            Self::Continuous => "Continuous",
        }
    }
}

/// The monitor view gamma as a command parameter. Same raw values as `SQRender.ViewGamma` (a test in SQMonitorUI keeps them equal).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ViewGammaChoice {
    Mac,
    Web,
    Broadcast,
}

impl ViewGammaChoice {
    pub const ALL: [ViewGammaChoice; 3] = [Self::Mac, Self::Web, Self::Broadcast];

    /// The Swift raw value (`mac`, `web`, `broadcast`).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Mac => "mac",
            Self::Web => "web",
            Self::Broadcast => "broadcast",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Mac => "Mac 1.96",
            Self::Web => "Web 2.2",
            Self::Broadcast => "Broadcast 2.4",
        }
    }
}

/// Which display the monitors preview for, as a command parameter. Same raw values and titles as `SQRender.DisplayView`
/// (`DisplayView.swift`); `sq_render::effects::display_view::DisplayView` is the engine side.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DisplayViewChoice {
    Sdr,
    DisplayP3,
    Hdr1000,
    UnToneMapped,
}

impl DisplayViewChoice {
    pub const ALL: [DisplayViewChoice; 4] = [Self::Sdr, Self::DisplayP3, Self::Hdr1000, Self::UnToneMapped];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Sdr => "sdr",
            Self::DisplayP3 => "displayP3",
            Self::Hdr1000 => "hdr1000",
            Self::UnToneMapped => "unToneMapped",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Sdr => "SDR 100 nit Rec.709",
            Self::DisplayP3 => "Display P3",
            Self::Hdr1000 => "HDR 1000 nit",
            Self::UnToneMapped => "Not Tone-Mapped",
        }
    }
}

/// The timeline and monitor tools.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorTool {
    Selection,
    TrackForward,
    TrackBackward,
    Ripple,
    Rolling,
    Slip,
    Slide,
    Razor,
    Hand,
    Zoom,
    Type,
    RateStretch,
    Mask,
    /// Position (Shift+V, Fast Cut): a dragged clip overwrites where it lands and leaves a hole.
    Position,
    /// Create tool modes next to `type` (Text): each selects the Create slot in that mode.
    Rectangle,
    Ellipse,
    Line,
    Draw,
}

impl EditorTool {
    pub const ALL: [EditorTool; 18] = [
        Self::Selection,
        Self::TrackForward,
        Self::TrackBackward,
        Self::Ripple,
        Self::Rolling,
        Self::Slip,
        Self::Slide,
        Self::Razor,
        Self::Hand,
        Self::Zoom,
        Self::Type,
        Self::RateStretch,
        Self::Mask,
        Self::Position,
        Self::Rectangle,
        Self::Ellipse,
        Self::Line,
        Self::Draw,
    ];

    /// The Swift raw value (the lower camel case name).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Selection => "selection",
            Self::TrackForward => "trackForward",
            Self::TrackBackward => "trackBackward",
            Self::Ripple => "ripple",
            Self::Rolling => "rolling",
            Self::Slip => "slip",
            Self::Slide => "slide",
            Self::Razor => "razor",
            Self::Hand => "hand",
            Self::Zoom => "zoom",
            Self::Type => "type",
            Self::RateStretch => "rateStretch",
            Self::Mask => "mask",
            Self::Position => "position",
            Self::Rectangle => "rectangle",
            Self::Ellipse => "ellipse",
            Self::Line => "line",
            Self::Draw => "draw",
        }
    }
}

/// Every command the keyboard map and the menus can trigger (docs/UX.md section 3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorCommand {
    // Transport. J/K/L go through `Shuttle` (see KeyRouter), the rest is plain.
    ShuttleReverse,
    ShuttleStop,
    ShuttleForward,
    /// Shift+J / Shift+L: fine speed changes.
    ShuttleSlowReverse,
    ShuttleSlowForward,
    PlayPause,
    StepBackward,
    StepForward,
    StepBackward5,
    StepForward5,
    // Shift = 10 frames for every frame step. The "...5" ids (stepBackward5, nudgeLeft5, trimForward5, slideLeft5, slipLeft5 ...)
    // are stored in key sets and the Premiere table, so the names stay; they all mean 10 frames now.
    /// Jump 10 Frames (Final Cut shift+arrows), Play to Out, Next/Previous Keyframe, Solo, Unlink, Trim to In/Out: key-only
    /// commands that the Final Cut import fills; also in the menus, no default key.
    StepBackward10,
    StepForward10,
    PlayToOut,
    NextKeyframe,
    PreviousKeyframe,
    Solo,
    Unlink,
    TrimToRange,
    /// Mute Selected Tracks (toggle, like Solo) and Detach Audio (the selected video clips lose their audio link and the
    /// audio clips become the selection): default keys Ctrl+Shift+M and Ctrl+Shift+D, both in the clip menu.
    MuteTracks,
    DetachAudio,
    PreviousEditPoint,
    NextEditPoint,
    GoToStart,
    GoToEnd,
    // Marking
    MarkIn,
    MarkOut,
    GoToIn,
    GoToOut,
    ClearInOut,
    MarkClip,
    ClearIn,
    ClearOut,
    PlayInToOut,
    ToggleLoop,
    ExportFrame,
    NewBin,
    Lift,
    Extract,
    Insert,
    Overwrite,
    AddMarker,
    Bleep,
    NewTone,
    ToneSettings,
    // Tools
    Tool(EditorTool),
    /// Slip tool, variant where the clip's keyframes stay on the timeline (Tools menu; the slot long-press has the same).
    SlipKeyframesStayTool,
    // Editing
    AddEdit,
    AddEditAllTracks,
    RippleTrimPrevious,
    RippleTrimNext,
    ExtendEdit,
    /// Q/W variants: Shift = rolling (the cut moves), Option = plain trim (the gap stays).
    RollTrimPrevious,
    RollTrimNext,
    TrimPrevious,
    TrimNext,
    /// Clip > Enable (Shift+Cmd+E), Edit > Duplicate (Shift+Cmd+/), Ctrl+T trim type, Opt+Up/Down lane move.
    EnableClip,
    Duplicate,
    ToggleTrimType,
    ToggleTrimMode,
    MoveSelectionUp,
    MoveSelectionDown,
    /// Clip > Group (Cmd+G) / Ungroup (Shift+Cmd+G), W7.6.
    Group,
    Ungroup,
    /// Clip > Bundle (Opt+Cmd+G) / Unbundle (Opt+Shift+Cmd+G), v57: Premiere's selection groups under our own name (Cmd+G is
    /// the W7.6 layer Group). Clip > Make Subclip (Cmd+U) and Edit Original (Cmd+E), Premiere's keys.
    Bundle,
    Unbundle,
    /// Clip > Combine… (Opt+G, Final Cut's compound clip key): names a new sequence and nests the selection in it.
    Combine,
    MakeSubclip,
    EditOriginal,
    /// Sequence > Join Cuts (no key; Premiere calls it Join Through Edits): puts the leftovers of a blade back into one clip.
    JoinCuts,
    /// Clip > Extend to Sequence End: toggles the flag on the selected Adjustment Layers.
    ExtendToSequenceEnd,
    /// Title templates: Save as Template… and the animation zones of the selected clip.
    SaveAsTemplate,
    ToggleAnimationZones,
    Delete,
    RippleDelete,
    DeleteProjectItems,
    ToggleSnapping,
    MatchFrame,
    ReverseMatchFrame,
    Link,
    /// Clip > Speed/Duration (Cmd+R).
    SpeedDuration,
    /// Clip > Reverse Clip: toggles the selected clips between playing forwards and backwards.
    ReverseClip,
    /// Clip > Show Time Remapping: toggles the speed band on the selected video clips. Remove Time Remapping resets them to 100 %.
    ToggleTimeRemapping,
    RemoveTimeRemapping,
    /// Clip > Add Speed Point: a no-change speed point at the playhead of the selected video clip (no default key; the user binds one).
    AddSpeedPoint,
    // Clipboard / history
    Copy,
    Cut,
    Paste,
    PasteAttributes,
    Undo,
    Redo,
    // Timeline selection, nudge, edit trims (Premiere: Cmd+Left/Right nudge, Opt+Shift+Left/Right trim 10 frames)
    SelectClipAtPlayhead,
    DeselectAll,
    NextEditPointAnyTrack,
    PreviousEditPointAnyTrack,
    /// Edit > Paste to Targeted Track: Cmd+V onto the lowest targeted track per kind (Premiere's pre-22.5 paste; unbound).
    PasteToTargets,
    /// Track targeting by key: toggles the target of video / audio track N (1-based, per kind). Ctrl+1...9 and Ctrl+Opt+1...9.
    ToggleTrackTarget(TrackKind, i64),
    /// Locks (or unlocks) every targeted track in one step (Ctrl+Shift+K).
    ToggleLockOfTargets,
    /// Opt+] / Opt+[: select the graphic layer above / below the selected one (from the monitor or the list).
    SelectLayerAbove,
    SelectLayerBelow,
    PasteInsert,
    SelectAll,
    ToggleLinkedSelection,
    ToggleMagnetic,
    MarkSelection,
    NextMarker,
    PreviousMarker,
    /// Playhead to the start of the next weak stretch of a tracked Magic mask (`MagicTrackHealth`, confidence strip).
    NextWeakTracking,
    NudgeLeft,
    NudgeRight,
    NudgeLeft5,
    NudgeRight5,
    NudgeLeft10,
    NudgeRight10,
    TrimBackward,
    TrimForward,
    TrimBackward5,
    TrimForward5,
    /// Premiere parity (2026-10): Clear Selected Marker (Opt+M) / Clear All Markers (Opt+Cmd+M), Select Next / Previous Clip on
    /// the track (Cmd+Down / Up), Go to Selected Clip Start / End, Slide Clip Selection (Opt+, / Opt+. with Shift = 10 frames).
    ClearMarker,
    ClearAllMarkers,
    SelectNextClip,
    SelectPreviousClip,
    GoToSelectedClipStart,
    GoToSelectedClipEnd,
    SlideLeft,
    SlideRight,
    SlideLeft5,
    SlideRight5,
    /// Split edit points: Mark Overhang (In/Out around the lead or trail of linked clips), Go to Next / Previous Split Point.
    MarkOverhang,
    NextSplitPoint,
    PreviousSplitPoint,
    /// Slip the selected clips' source by 1 / 10 frames (Opt+Cmd+Left/Right only; Opt+Left/Right with no edit selected says so).
    SlipLeft,
    SlipRight,
    SlipLeft5,
    SlipRight5,
    /// Project panel: Cmd+PageUp / Cmd+PageDown switch list / icon view, Cmd+[ / Cmd+] change the icon size.
    ProjectListView,
    ProjectIconView,
    ProjectThumbnailSmaller,
    ProjectThumbnailLarger,
    /// App-wide UI scale (View > Larger / Smaller / Actual Size, Cmd+Opt+= / - / 0): one step of `UIScale.steps`, applies on next launch.
    UiScaleLarger,
    UiScaleSmaller,
    UiScaleReset,
    // View / window
    ZoomIn,
    ZoomOut,
    ZoomFit,
    // Track heights (Premiere: Cmd+=/- video, Option+=/- audio, Shift+= expand all, Shift+- minimize all)
    VideoTracksTaller,
    VideoTracksShorter,
    AudioTracksTaller,
    AudioTracksShorter,
    MinimizeAllTracks,
    ExpandAllTracks,
    // Vertical zoom: every track taller / shorter (Ctrl+= / Ctrl+-), Fit All Tracks toggle (Ctrl+\)
    AllTracksTaller,
    AllTracksShorter,
    ToggleFitTracks,
    TrackHeightSmall,
    TrackHeightMedium,
    TrackHeightLarge,
    TrackHeightAuto,
    FocusPanel(PanelID),
    MaximizePanel,
    MaximizeActivePanel,
    ResetLayout,
    /// Moves keyboard focus to the next / previous visible panel (Ctrl+Shift+. and Ctrl+Shift+,).
    SelectNextPanel,
    SelectPreviousPanel,
    // File
    ImportMedia,
    NewSequence,
    Save,
    Export,
    /// One-click export of the active sequence with its platform preset, no sheet (`ExportCoordinator.quickExport()`).
    QuickExport,
    NewProject,
    OpenProject,
    SaveAs,
    SaveCopy,
    Revert,
    CloseProject,
    ProjectNotes,
    SequenceSettings,
    SetToFrameSize,
    SetToFillFrame,
    // App
    KeyboardShortcuts,
    Preferences,
    /// Option+Space: floating search palette over effects, transitions, presets and commands.
    QuickApply,
    // Keyframes: easing of the selected keyframes in Effect Controls (F9 family; Premiere has no default keys for these)
    EaseLinear,
    EasyEase,
    EaseIn,
    EaseOut,
    ToggleHoldInterpolation,
    // Audio
    AudioGain,
    ToggleAudioScrubbing,
    /// `[` / `]` change the Audio Gain of the selected audio clips by 1 dB, with Shift by 6 dB.
    AudioGainDown,
    AudioGainUp,
    AudioGainDown6,
    AudioGainUp6,
    /// Markers on Beat (spectral beat grid of the selected audio or Music clips), and only the bar starts.
    MatchLoudness,
    AutoDuck,
    AddBeatMarkers,
    AddMarkersOnDownbeats,
    RemoveSilences,
    RemoveFillerWords,
    /// Text to speech: opens the voiceover dialog (voice made on this computer, inserted at the playhead).
    Voiceover,
    /// Record Voice-Over: countdown, then the microphone is recorded from the playhead while the sequence plays; the same
    /// command stops and places the take. No default key.
    RecordVoiceOver,
    /// N8b: the project's own live ducking setting (on/off, amount; or follow Preferences).
    ProjectLiveDucking,
    /// Review step of Remove Silences: proposed-cut markers on the timeline.
    ReviewProposedCuts,
    AcceptProposedCuts,
    RejectProposedCuts,
    AcceptProposedCutAtPlayhead,
    RejectProposedCutAtPlayhead,
    /// Sequence > Check Cuts: jump cuts, gaps, caption safe zones, audio pops as markers, plus edit stats.
    CheckCuts,
    /// Sequence > Whoosh at Selected Cuts: the chosen (else first) item of the Library's SFX bin, centered on each selected cut.
    WhooshAtCuts,
    /// Clip > Sync Audio to Reference: the earliest selected clip is the reference; the other selected clips are lined up
    /// to it by sound (with drift correction), else by capture date.
    SyncAudioToReference,
    /// Sequence > Punch In Cuts…: alternating or cycling zoom levels over consecutive shots (sheet).
    PunchInCuts,
    /// Sequence > Fill Reel…: the media items selected in the Project panel pour into the clips (slots) of the active
    /// sequence in order, into a copy or in place (sheet).
    FillReel,
    TagDialogue,
    TagMusic,
    TagSFX,
    /// Clip > Audio Options > Voice Chain: Dialogue role on the selected clips' tracks (voiced EQ, compressor, noise reduction).
    VoiceChain,
    /// Clip > Audio Options > Disguise Voice: the Disguise Voice effect on the selected range plus captions for that range.
    DisguiseVoice,
    // Clip > Video Options (effects-look): fade presets on the picture, frame holds
    VideoFadeIn,
    VideoFadeOut,
    AddFrameHold,
    InsertFrameHold,
    /// Clip > Video Options > Auto Reframe: Position keys that keep the subject in the sequence frame (SQAnalysis).
    AutoReframe,
    /// Clip > Video Options > Anonymize: covers people with a Mosaic or a blur limited to tracked Magic masks (SQAnalysis).
    Anonymize,
    /// Clip > Video Options > Dynamic Zoom In / Out: a start and an end window of the picture, eased (Ken Burns) as a Dynamic Zoom stage.
    DynamicZoomIn,
    DynamicZoomOut,
    EditDynamicZoom,
    /// Clip > Video Options > Stabilize: Vision measures the camera shake, a Stabilizer stage (W9.7) removes it before Motion.
    Stabilize,
    /// Clip > Video Options > Find Scene Changes: shot changes of the selected clips become proposed cuts (accept razors them).
    FindSceneChanges,
    /// Clip > Video Options > Match Color to Clip: Exposure and Color Wheels so the clip looks like the clip under the
    /// playhead on another track (else the previous clip on its track); one-shot Color Match.
    MatchColorToClip,
    /// W9.8 Clip > Video Options > Add Subject Mask: a mask that follows the person in the picture (Vision matte).
    AddSubjectMask,
    /// Clip > Split Screen: lays the selected clips out in the frame (Scale, Position, Crop); `animated` adds slide in/out keys.
    SplitScreen(SplitLayoutPreset, bool),
    /// Clip > Speed Ramp Presets: one-click ramp; `onBeat` puts its peak on the nearest beat marker.
    SpeedRampPreset(SpeedRampPreset, bool),
    /// F7.16 Clip > Angles: several recordings of one event become one Angles clip (dialog: name, sync, sound).
    CreateAnglesClip,
    /// F7.16: show angle 1...9 on the selected Angles pieces (or the piece under the playhead); while playing, cut at
    /// the playhead and show that angle from there on.
    SwitchAngle(i64),
    /// Clip > Beat Edits: cut the selected clips at the beat markers / move their ends onto the beat markers.
    CutToBeats,
    SnapToBeats,
    /// Clip > Fit Music to Length…: cut or loop the selected music clip at bars to the In/Out range or sequence end.
    FitMusicToLength,
    /// Clip > Video Options: explicit blurred-fill look for the selected clips (BlurredFill.swift in SQCore).
    FitBlurredFill,
    FitCard,
    RemoveBlurredFill,
    /// W8.2: Shift+P puts a static scale-up (PunchIn.swift in SQCore) on the selected video clips; again takes it off.
    TogglePunchIn,
    /// W8.1: cut at the playhead, the rest goes to the alternate track (V1<->V2, A1<->A2) with an overlap and audio crossfade.
    JumpCutAlternate,
    /// J / L cut: moves only the audio (or only the video) edit of the nearest cut to the playhead (roll, one undo step).
    SplitEditAudio,
    SplitEditVideo,
    /// Fast cutting (Q-CUT1/2): one-key Cut Out (mark start, then extract), close the gap at the playhead, plain-key J / L cut.
    CutOut,
    CloseGapAtPlayhead,
    JCut,
    LCut,
    /// Resolve F12 style: the Source clip (else the selected Project media) at the playhead on the next free upper video track.
    PlaceOnTop,
    /// Fast Cut (docs/research/FCP-MAGNETIC-TIMELINE.md): Ctrl+E, Ctrl+W, Opt+Cmd+Up, Opt+Cmd+Down; Set Attach Point has no key yet.
    AppendToMainTrack,
    InsertSpacer,
    LiftOffMainTrack,
    PutOnMainTrack,
    SetAttachPoint,
    /// Fast Cut: Opt+V pastes the clipboard as attached clips at the playhead; Ctrl+Shift+. is Place on Top backtimed (the clip ends at the playhead).
    PasteAttached,
    AttachBacktimed,
    /// Fast Cut storylines: Create Storyline (Ctrl+G; Cmd+G is Group) and Ripple Delete in Storyline (Ctrl+Shift+Delete).
    CreateStoryline,
    StorylineRippleDelete,
    /// Fast Cut: Move Clip Left / Right swaps the selected main-track clip with its neighbor (Ctrl+Cmd+Left/Right, and Opt+Left/Right when no edit is selected); Delete Selection Only (Cmd+Opt+Delete) removes it and keeps its attached clips.
    MoveClipLeft,
    MoveClipRight,
    DeleteSelectionOnly,
    // Source and Project flow: Play In to Out with preroll/postroll (Shift+Space), Play Around (Shift+K), poster frame
    // (Cmd+P / Option+P), Hover Scrub (Shift+H), Find (Cmd+F).
    PlayInToOutRoll,
    PlayAround,
    SetPosterFrame,
    ClearPosterFrame,
    ToggleHoverScrub,
    Find,
    // Transitions (Sequence menu): Cmd+D, Shift+Cmd+D, Shift+D
    ApplyVideoTransition,
    ApplyAudioTransition,
    ApplyDefaultTransitions,
    // Captions
    ToggleCaptionsInMonitor,
    // View
    ToggleSafeAreas,
    /// View > Show Overlays: hides or shows safe margins, guides and rulers in the monitor (settings are kept).
    ToggleOverlays,
    /// View > View Gamma: how the monitor shows Rec.709 (display only, never the export).
    ViewGamma(ViewGammaChoice),
    /// View > Display: which display the monitors preview for (session-only, display only, never the export).
    DisplayView(DisplayViewChoice),
    /// Sequence menu: the clips under the playhead on the targeted tracks are selected as the playhead moves.
    ToggleSelectionFollowsPlayhead,
    /// N5: the transcript word under the playhead becomes a big styled text clip (`EditorSession.addKeywordAtPlayhead`).
    KeywordAtPlayhead,
    /// Workflow audit: the maintainer's title (two lines + emoji text clips with In animations) at the playhead (`EditorSession.addTitle`).
    AddTitle,
    /// Workflow audit: transcribe the whole sequence (when needed) and create captions with the default caption look.
    AutoCaptions,
    /// Shortcut import rest: Add Keyframe (the property last used in Controls, at the playhead), Play from Start, Toggle All
    /// Targets, Select Left / Right Edge (edges of the selected clips for the trim keys), Edit Marker (the marker at the
    /// playhead), Add and Edit Marker (adds one, then opens its dialog). No default key except Add Keyframe and Play from Start.
    AddKeyframe,
    PlayFromStart,
    ToggleAllTargets,
    SelectLeftEdge,
    SelectRightEdge,
    EditMarker,
    AddAndEditMarker,
    /// Go to Timecode (Ctrl+P, as in Final Cut): focuses the Program monitor's timecode field; type a time or +/- frames.
    /// Toggle Video / Audio Targets: like Toggle All Targets for the video or the audio tracks only (Cmd+9 / Cmd+0).
    GoToTimecode,
    ToggleVideoTargets,
    ToggleAudioTargets,
    /// Nudge Audio / Video Edit: one frame (earlier / later) of the audio or the video half of the cut nearest to the playhead
    /// (`EditorSession.nudgeSplitEdit`), so a J / L cut can be tuned by key. Keys Ctrl+Opt+Left/Right and with Shift.
    NudgeAudioEditLeft,
    NudgeAudioEditRight,
    NudgeVideoEditLeft,
    NudgeVideoEditRight,
    /// Fit to Fill (the Source clip retimed into the sequence In..Out) and Replace Clip from Source (the one selected clip
    /// plays the Source clip, frame shown there lined up with the playhead). Menu only: the Source monitor buttons run the same.
    FitToFill,
    ReplaceClipFromSource,
    /// Replace With Clip from Project (Clip menu): the one selected clip plays the item selected in the Project panel.
    ReplaceClipFromProject,
    /// Clip > Replace and Fit > Replace at Playhead / from Start / from End / with Retime (Fast Cut): the selected main-track
    /// clip plays the Source clip (docs/NEXT F2). Menu only, no default key.
    ReplaceMode(ReplaceMode),
    /// J / L Cut by Offset (Clip menu, no default key): the audio edit of the nearest cut moves a role offset (0.25 s dialogue,
    /// 0.5 s music) earlier or later (`EditorSession.offsetSplitEdit`); repeat to grow the split.
    JCutByOffset,
    LCutByOffset,
    /// File > Export Markers as CSV…: the marker list of the active sequence as a spreadsheet file (save panel).
    ExportMarkersCSV,
    /// View > Timeline Thumbnails: what the thumbnails of video clips show (Head, Head and Tail, Continuous). A user preference.
    ThumbnailMode(ThumbnailModeChoice),
    /// Sequence > Add Video Track / Add Audio Track: one empty track on top of its kind (A8).
    AddVideoTrack,
    AddAudioTrack,
    /// Sequence > Remove Empty Tracks.
    RemoveEmptyTracks,
    /// Sequence > Delete Track: the targeted tracks with their clips (the lowest track of each kind stays).
    DeleteTrack,
    /// File: the interchange, Lottie, template and Premiere imports and exports that the app used to insert by hand (D25).
    ImportTimeline,
    ExportEDL,
    ExportFCPXML,
    ExportFinalCutXML,
    ExportOpenTimelineIO,
    ImportLottie,
    ImportMotionGraphicsTemplate,
    ImportPremiereProject,
    ImportPremierePresets,
    ImportProject,
}

impl EditorCommand {
    /// Auto-repeat (key held) re-fires these; everything else ignores repeats.
    pub fn is_repeatable(&self) -> bool {
        matches!(
            self,
            Self::StepBackward
                | Self::StepForward
                | Self::StepBackward5
                | Self::StepForward5
                | Self::StepBackward10
                | Self::StepForward10
                | Self::NextKeyframe
                | Self::PreviousKeyframe
                | Self::PreviousEditPoint
                | Self::NextEditPoint
                | Self::NextEditPointAnyTrack
                | Self::PreviousEditPointAnyTrack
                | Self::ZoomIn
                | Self::ZoomOut
                | Self::NudgeLeft
                | Self::NudgeRight
                | Self::NudgeLeft5
                | Self::NudgeRight5
                | Self::NudgeLeft10
                | Self::NudgeRight10
                | Self::TrimBackward
                | Self::TrimForward
                | Self::TrimBackward5
                | Self::TrimForward5
                | Self::SlideLeft
                | Self::SlideRight
                | Self::SlideLeft5
                | Self::SlideRight5
                | Self::SlipLeft
                | Self::SlipRight
                | Self::SlipLeft5
                | Self::SlipRight5
                | Self::NudgeAudioEditLeft
                | Self::NudgeAudioEditRight
                | Self::NudgeVideoEditLeft
                | Self::NudgeVideoEditRight
                | Self::SelectNextClip
                | Self::SelectPreviousClip
                | Self::ProjectThumbnailSmaller
                | Self::ProjectThumbnailLarger
                | Self::VideoTracksTaller
                | Self::VideoTracksShorter
                | Self::AudioTracksTaller
                | Self::AudioTracksShorter
                | Self::AllTracksTaller
                | Self::AllTracksShorter
                | Self::Undo
                | Self::Redo
                | Self::AudioGainDown
                | Self::AudioGainUp
                | Self::AudioGainDown6
                | Self::AudioGainUp6
        )
    }

    /// Menu title (English).
    pub fn title(&self) -> String {
        match self {
            Self::ShuttleReverse => "Shuttle Reverse".to_string(),
            Self::ShuttleStop => "Shuttle Stop".to_string(),
            Self::ShuttleSlowReverse => "Shuttle Slow Reverse".to_string(),
            Self::ShuttleSlowForward => "Shuttle Slow Forward".to_string(),
            Self::ShuttleForward => "Shuttle Forward".to_string(),
            Self::PlayPause => "Play/Pause".to_string(),
            Self::StepBackward => "Step Back 1 Frame".to_string(),
            Self::StepForward => "Step Forward 1 Frame".to_string(),
            Self::StepBackward5 => "Step Back 10 Frames".to_string(),
            Self::StepForward5 => "Step Forward 10 Frames".to_string(),
            Self::StepBackward10 => "Jump Back 10 Frames".to_string(),
            Self::StepForward10 => "Jump Forward 10 Frames".to_string(),
            Self::PlayToOut => "Play to Out".to_string(),
            Self::NextKeyframe => "Go to Next Keyframe".to_string(),
            Self::PreviousKeyframe => "Go to Previous Keyframe".to_string(),
            Self::Solo => "Solo Selected Tracks".to_string(),
            Self::MuteTracks => "Mute Selected Tracks".to_string(),
            Self::DetachAudio => "Detach Audio".to_string(),
            Self::Unlink => "Unlink".to_string(),
            Self::TrimToRange => "Trim to In/Out".to_string(),
            Self::PreviousEditPoint => "Go to Previous Edit".to_string(),
            Self::NextEditPoint => "Go to Next Edit".to_string(),
            Self::GoToStart => "Go to Sequence Start".to_string(),
            Self::GoToEnd => "Go to Sequence End".to_string(),
            Self::MarkIn => "Mark In".to_string(),
            Self::MarkOut => "Mark Out".to_string(),
            Self::GoToIn => "Go to In".to_string(),
            Self::GoToOut => "Go to Out".to_string(),
            Self::ClearInOut => "Remove In and Out".to_string(),
            Self::MarkClip => "Mark Clip".to_string(),
            Self::ClearIn => "Remove In".to_string(),
            Self::ClearOut => "Remove Out".to_string(),
            Self::PlayInToOut => "Play In to Out".to_string(),
            Self::ToggleLoop => "Loop Playback".to_string(),
            Self::ExportFrame => "Export Frame…".to_string(),
            Self::ExportMarkersCSV => "Export Markers as CSV…".to_string(),
            Self::ThumbnailMode(m) => m.title().to_string(),
            Self::ViewGamma(g) => g.title().to_string(),
            Self::DisplayView(v) => v.title().to_string(),
            Self::ToggleOverlays => "Show Overlays".to_string(),
            Self::NewBin => "New Folder".to_string(),
            Self::Lift => "Clear Range".to_string(),
            Self::Bleep => "Bleep".to_string(),
            Self::NewTone => "New Tone…".to_string(),
            Self::ToneSettings => "Tone Settings…".to_string(),
            Self::Extract => "Delete Range".to_string(),
            Self::Insert => "Insert".to_string(),
            Self::Overwrite => "Overwrite".to_string(),
            Self::AddMarker => "Add Marker".to_string(),
            Self::Tool(t) => match t {
                EditorTool::Selection => "Select Tool".to_string(),
                EditorTool::TrackForward => "Select Forward Tool".to_string(),
                EditorTool::TrackBackward => "Select Backward Tool".to_string(),
                EditorTool::Ripple => "Ripple Tool".to_string(),
                EditorTool::Rolling => "Roll Tool".to_string(),
                EditorTool::Slip => "Slip Tool".to_string(),
                EditorTool::Slide => "Slide Tool".to_string(),
                EditorTool::Razor => "Blade Tool".to_string(),
                EditorTool::Hand => "Hand Tool".to_string(),
                EditorTool::Zoom => "Zoom Tool".to_string(),
                EditorTool::Type => "Text Tool".to_string(),
                EditorTool::Rectangle => "Rectangle Tool".to_string(),
                EditorTool::Ellipse => "Ellipse Tool".to_string(),
                EditorTool::Line => "Line Tool".to_string(),
                EditorTool::Draw => "Draw Tool".to_string(),
                EditorTool::RateStretch => "Stretch Tool".to_string(),
                EditorTool::Mask => "Mask Tool".to_string(),
                EditorTool::Position => "Position Tool".to_string(),
            },
            Self::SlipKeyframesStayTool => "Slip Tool (Keyframes Stay)".to_string(),
            Self::AddEdit => "Add Edit".to_string(),
            Self::AddEditAllTracks => "Add Edit to All Tracks".to_string(),
            Self::RippleTrimPrevious => "Ripple Trim Previous Edit to Playhead".to_string(),
            Self::RippleTrimNext => "Ripple Trim Next Edit to Playhead".to_string(),
            Self::ExtendEdit => "Extend Selected Edit to Playhead".to_string(),
            Self::RollTrimPrevious => "Roll Previous Edit to Playhead".to_string(),
            Self::RollTrimNext => "Roll Next Edit to Playhead".to_string(),
            Self::TrimPrevious => "Trim Previous Edit to Playhead".to_string(),
            Self::TrimNext => "Trim Next Edit to Playhead".to_string(),
            Self::Group => "Group".to_string(),
            Self::Ungroup => "Ungroup".to_string(),
            Self::Bundle => "Bundle".to_string(),
            Self::Unbundle => "Unbundle".to_string(),
            Self::Combine => "Combine…".to_string(),
            Self::JoinCuts => "Join Cuts".to_string(),
            Self::MakeSubclip => "Make Subclip".to_string(),
            Self::EditOriginal => "Edit Original".to_string(),
            Self::ExtendToSequenceEnd => "Extend to Sequence End".to_string(),
            Self::SaveAsTemplate => "Save as Template".to_string(),
            Self::ToggleAnimationZones => "Keep Intro and Outro When Trimmed".to_string(),
            Self::EnableClip => "Enable".to_string(),
            Self::Duplicate => "Duplicate".to_string(),
            Self::ToggleTrimType => "Toggle Trim Type".to_string(),
            Self::ToggleTrimMode => "Trim Mode".to_string(),
            Self::MoveSelectionUp => "Move Selection Up".to_string(),
            Self::MoveSelectionDown => "Move Selection Down".to_string(),
            Self::Delete => "Delete".to_string(),
            Self::RippleDelete => "Ripple Delete".to_string(),
            Self::DeleteProjectItems => "Delete Project Items".to_string(),
            Self::ToggleSnapping => "Snap".to_string(),
            Self::MatchFrame => "Show in Source".to_string(),
            Self::ReverseMatchFrame => "Show in Timeline".to_string(),
            Self::Link => "Link".to_string(),
            Self::SpeedDuration => "Speed…".to_string(),
            Self::ReverseClip => "Reverse Clip".to_string(),
            Self::ToggleTimeRemapping => "Show Speed Ramp".to_string(),
            Self::RemoveTimeRemapping => "Remove Speed Ramp".to_string(),
            Self::AddSpeedPoint => "Add Speed Point".to_string(),
            Self::Copy => "Copy".to_string(),
            Self::Cut => "Cut".to_string(),
            Self::Paste => "Paste".to_string(),
            Self::PasteAttributes => "Paste Settings".to_string(),
            Self::SelectClipAtPlayhead => "Select Clip at Playhead".to_string(),
            Self::DeselectAll => "Deselect All".to_string(),
            Self::NextEditPointAnyTrack => "Go to Next Edit on Any Track".to_string(),
            Self::PreviousEditPointAnyTrack => "Go to Previous Edit on Any Track".to_string(),
            Self::PasteInsert => "Paste Insert".to_string(),
            Self::PasteToTargets => "Paste to Targeted Track".to_string(),
            Self::ToggleTrackTarget(k, n) => {
                format!("Toggle Target {} Track {n}", if *k == TrackKind::Video { "Video" } else { "Audio" })
            }
            Self::ToggleLockOfTargets => "Lock or Unlock Targeted Tracks".to_string(),
            Self::SelectAll => "Select All".to_string(),
            Self::SelectLayerAbove => "Select Layer Above".to_string(),
            Self::SelectLayerBelow => "Select Layer Below".to_string(),
            Self::ToggleLinkedSelection => "Linked Selection".to_string(),
            Self::ToggleMagnetic => "Fast Cut".to_string(),
            Self::AppendToMainTrack => "Append to Main Track".to_string(),
            Self::InsertSpacer => "Insert Spacer".to_string(),
            Self::LiftOffMainTrack => "Lift off Main Track".to_string(),
            Self::PutOnMainTrack => "Put on Main Track".to_string(),
            Self::SetAttachPoint => "Set Attach Point".to_string(),
            Self::PasteAttached => "Paste Attached".to_string(),
            Self::AttachBacktimed => "Attach Backtimed".to_string(),
            Self::CreateStoryline => "Create Storyline".to_string(),
            Self::StorylineRippleDelete => "Ripple Delete in Storyline".to_string(),
            Self::MoveClipLeft => "Move Clip Left".to_string(),
            Self::MoveClipRight => "Move Clip Right".to_string(),
            Self::DeleteSelectionOnly => "Delete Selection Only".to_string(),
            Self::MarkSelection => "Mark Selection".to_string(),
            Self::NextMarker => "Go to Next Marker".to_string(),
            Self::PreviousMarker => "Go to Previous Marker".to_string(),
            Self::NextWeakTracking => "Go to Next Weak Tracking".to_string(),
            Self::ClearMarker => "Clear Selected Marker".to_string(),
            Self::ClearAllMarkers => "Clear All Markers".to_string(),
            Self::SelectNextClip => "Select Next Clip".to_string(),
            Self::SelectPreviousClip => "Select Previous Clip".to_string(),
            Self::GoToSelectedClipStart => "Go to Selected Clip Start".to_string(),
            Self::GoToSelectedClipEnd => "Go to Selected Clip End".to_string(),
            Self::MarkOverhang => "Mark Overhang".to_string(),
            Self::NextSplitPoint => "Go to Next Split Point".to_string(),
            Self::PreviousSplitPoint => "Go to Previous Split Point".to_string(),
            Self::SlideLeft => "Slide Clip Selection Left 1 Frame".to_string(),
            Self::SlideRight => "Slide Clip Selection Right 1 Frame".to_string(),
            Self::SlideLeft5 => "Slide Clip Selection Left 10 Frames".to_string(),
            Self::SlideRight5 => "Slide Clip Selection Right 10 Frames".to_string(),
            Self::SlipLeft => "Slip Clip Selection Left 1 Frame".to_string(),
            Self::SlipRight => "Slip Clip Selection Right 1 Frame".to_string(),
            Self::SlipLeft5 => "Slip Clip Selection Left 10 Frames".to_string(),
            Self::SlipRight5 => "Slip Clip Selection Right 10 Frames".to_string(),
            Self::ProjectListView => "List View".to_string(),
            Self::ProjectIconView => "Icon View".to_string(),
            Self::ProjectThumbnailSmaller => "Smaller Thumbnails".to_string(),
            Self::ProjectThumbnailLarger => "Larger Thumbnails".to_string(),
            Self::UiScaleLarger => "Larger".to_string(),
            Self::UiScaleSmaller => "Smaller".to_string(),
            Self::UiScaleReset => "Actual Size".to_string(),
            Self::NudgeLeft => "Nudge Clip Selection Left 1 Frame".to_string(),
            Self::NudgeRight => "Nudge Clip Selection Right 1 Frame".to_string(),
            Self::NudgeLeft5 => "Nudge Clip Selection Left by Many".to_string(),
            Self::NudgeRight5 => "Nudge Clip Selection Right by Many".to_string(),
            Self::NudgeLeft10 => "Nudge Clip Selection Left 10 Frames".to_string(),
            Self::NudgeRight10 => "Nudge Clip Selection Right 10 Frames".to_string(),
            Self::TrimBackward => "Trim Backward".to_string(),
            Self::TrimForward => "Trim Forward".to_string(),
            Self::TrimBackward5 => "Trim Backward 10 Frames".to_string(),
            Self::TrimForward5 => "Trim Forward 10 Frames".to_string(),
            Self::Undo => "Undo".to_string(),
            Self::Redo => "Redo".to_string(),
            Self::ZoomIn => "Zoom In".to_string(),
            Self::ZoomOut => "Zoom Out".to_string(),
            Self::ZoomFit => "Zoom to Fit".to_string(),
            Self::VideoTracksTaller => "Increase Video Track Height".to_string(),
            Self::VideoTracksShorter => "Decrease Video Track Height".to_string(),
            Self::AudioTracksTaller => "Increase Audio Track Height".to_string(),
            Self::AudioTracksShorter => "Decrease Audio Track Height".to_string(),
            Self::AllTracksTaller => "Zoom In Vertically".to_string(),
            Self::AllTracksShorter => "Zoom Out Vertically".to_string(),
            Self::ToggleFitTracks => "Fit All Tracks to Height".to_string(),
            Self::MinimizeAllTracks => "Minimize All Tracks".to_string(),
            Self::ExpandAllTracks => "Expand All Tracks".to_string(),
            Self::TrackHeightSmall => "Small".to_string(),
            Self::TrackHeightMedium => "Medium".to_string(),
            Self::TrackHeightLarge => "Large".to_string(),
            Self::TrackHeightAuto => "Auto".to_string(),
            Self::FocusPanel(p) => format!("Show {}", Self::panel_title(*p)),
            Self::SpeedRampPreset(p, on_beat) => {
                if *on_beat {
                    format!("{} on Beat", p.title())
                } else {
                    p.title().to_string()
                }
            }
            Self::CreateAnglesClip => "Create Angles Clip…".to_string(),
            Self::SwitchAngle(n) => format!("Switch to Angle {n}"),
            Self::CutToBeats => "Cut to Beats".to_string(),
            Self::SnapToBeats => "Snap to Beats".to_string(),
            Self::FitMusicToLength => "Fit Music to Length…".to_string(),
            Self::SplitScreen(preset, animated) => {
                if *animated {
                    format!("{}, Animated", preset.title())
                } else {
                    preset.title().to_string()
                }
            }
            Self::MaximizePanel => "Maximize Panel Under Pointer".to_string(),
            Self::MaximizeActivePanel => "Maximize Active Panel".to_string(),
            Self::ResetLayout => "Reset to Saved Layout".to_string(),
            Self::SelectNextPanel => "Select Next Panel".to_string(),
            Self::SelectPreviousPanel => "Select Previous Panel".to_string(),
            Self::ImportMedia => "Import…".to_string(),
            Self::NewSequence => "New Sequence…".to_string(),
            Self::Save => "Save".to_string(),
            Self::Export => "Export…".to_string(),
            Self::QuickExport => "Quick Export".to_string(),
            Self::NewProject => "New Project".to_string(),
            Self::OpenProject => "Open Project…".to_string(),
            Self::SaveAs => "Save As…".to_string(),
            Self::SaveCopy => "Save a Copy…".to_string(),
            Self::Revert => "Revert".to_string(),
            Self::CloseProject => "Close Project".to_string(),
            Self::ProjectNotes => "Project Notes…".to_string(),
            Self::SequenceSettings => "Sequence Settings…".to_string(),
            Self::SetToFrameSize => "Fit to Frame".to_string(),
            Self::SetToFillFrame => "Fill Frame".to_string(),
            Self::KeyboardShortcuts => "Keyboard Shortcuts…".to_string(),
            Self::Preferences => "Settings…".to_string(),
            Self::QuickApply => "Quick Apply…".to_string(),
            Self::EaseLinear => ease_name::STEADY.to_string(),
            Self::EasyEase => ease_name::SMOOTH.to_string(),
            Self::EaseIn => ease_name::SMOOTH_IN.to_string(),
            Self::EaseOut => ease_name::SMOOTH_OUT.to_string(),
            Self::ToggleHoldInterpolation => "Toggle Hold".to_string(),
            Self::AudioGain => "Audio Gain…".to_string(),
            Self::ToggleAudioScrubbing => "Audio Scrubbing".to_string(),
            Self::AudioGainDown => "Decrease Audio Gain by 1 dB".to_string(),
            Self::AudioGainUp => "Increase Audio Gain by 1 dB".to_string(),
            Self::AudioGainDown6 => "Decrease Audio Gain by 6 dB".to_string(),
            Self::AudioGainUp6 => "Increase Audio Gain by 6 dB".to_string(),
            Self::MatchLoudness => "Match Loudness".to_string(),
            Self::AutoDuck => "Bake Live Duck to Keys".to_string(),
            Self::AddBeatMarkers => "Markers on Beat".to_string(),
            Self::AddMarkersOnDownbeats => "Markers on Downbeats".to_string(),
            Self::ProjectLiveDucking => "Live Ducking for This Project…".to_string(),
            Self::RemoveSilences => "Remove Silences…".to_string(),
            Self::RemoveFillerWords => "Remove Filler Words".to_string(),
            Self::Voiceover => "Voiceover from Text…".to_string(),
            Self::RecordVoiceOver => "Record Voice-Over".to_string(),
            Self::AcceptProposedCuts => "Accept All Proposed Cuts".to_string(),
            Self::ReviewProposedCuts => "Review Proposed Cuts…".to_string(),
            Self::RejectProposedCuts => "Reject All Proposed Cuts".to_string(),
            Self::AcceptProposedCutAtPlayhead => "Accept Proposed Cut at Playhead".to_string(),
            Self::RejectProposedCutAtPlayhead => "Reject Proposed Cut at Playhead".to_string(),
            Self::CheckCuts => "Check Cuts…".to_string(),
            Self::WhooshAtCuts => "Whoosh at Selected Cuts".to_string(),
            Self::SyncAudioToReference => "Sync Audio to Reference".to_string(),
            Self::PunchInCuts => "Punch In Cuts…".to_string(),
            Self::FillReel => "Fill Reel…".to_string(),
            Self::VoiceChain => "Voice Chain".to_string(),
            Self::DisguiseVoice => "Disguise Voice".to_string(),
            Self::TagDialogue => "Dialogue".to_string(),
            Self::TagMusic => "Music".to_string(),
            Self::TagSFX => "SFX".to_string(),
            Self::VideoFadeIn => "Fade In".to_string(),
            Self::VideoFadeOut => "Fade Out".to_string(),
            Self::AddFrameHold => "Add Frame Hold".to_string(),
            Self::InsertFrameHold => "Insert Frame Hold Segment".to_string(),
            Self::AutoReframe => "Auto Reframe".to_string(),
            Self::Anonymize => "Anonymize…".to_string(),
            Self::DynamicZoomIn => "Dynamic Zoom In".to_string(),
            Self::DynamicZoomOut => "Dynamic Zoom Out".to_string(),
            Self::EditDynamicZoom => "Edit Dynamic Zoom".to_string(),
            Self::Stabilize => "Stabilize".to_string(),
            Self::FindSceneChanges => "Find Scene Changes".to_string(),
            Self::MatchColorToClip => "Match Color to Clip".to_string(),
            Self::AddSubjectMask => "Add Subject Mask".to_string(),
            Self::FitBlurredFill => "Fit with Blurred Fill".to_string(),
            Self::FitCard => "Card with Blurred Background".to_string(),
            Self::RemoveBlurredFill => "Remove Blurred Fill".to_string(),
            Self::TogglePunchIn => "Punch In".to_string(),
            Self::JumpCutAlternate => "Jump Cut to Alternate Track".to_string(),
            Self::SplitEditAudio => "Move Audio Edit to Playhead".to_string(),
            Self::SplitEditVideo => "Move Video Edit to Playhead".to_string(),
            Self::CutOut => "Cut Out (Mark Start, then Delete Range)".to_string(),
            Self::CloseGapAtPlayhead => "Close Gap at Playhead".to_string(),
            Self::PlaceOnTop => "Place on Top".to_string(),
            Self::AddVideoTrack => "Add Video Track".to_string(),
            Self::AddAudioTrack => "Add Audio Track".to_string(),
            Self::RemoveEmptyTracks => "Remove Empty Tracks".to_string(),
            Self::DeleteTrack => "Delete Track".to_string(),
            Self::ImportTimeline => "Import Timeline…".to_string(),
            Self::ExportEDL => "Export EDL…".to_string(),
            Self::ExportFCPXML => "Export FCPXML…".to_string(),
            Self::ExportFinalCutXML => "Export Final Cut Pro XML…".to_string(),
            Self::ExportOpenTimelineIO => "Export OpenTimelineIO…".to_string(),
            Self::ImportLottie => "Import Lottie Animation…".to_string(),
            Self::ImportMotionGraphicsTemplate => "Import Motion Graphics Template…".to_string(),
            Self::ImportPremiereProject => "Import Premiere Project…".to_string(),
            Self::ImportPremierePresets => "Import Premiere Presets…".to_string(),
            Self::ImportProject => "Import Project…".to_string(),
            Self::JCut => "J Cut (Audio Leads)".to_string(),
            Self::JCutByOffset => "J Cut by Offset".to_string(),
            Self::LCutByOffset => "L Cut by Offset".to_string(),
            Self::NudgeAudioEditLeft => "Nudge Audio Edit Left 1 Frame".to_string(),
            Self::NudgeAudioEditRight => "Nudge Audio Edit Right 1 Frame".to_string(),
            Self::NudgeVideoEditLeft => "Nudge Video Edit Left 1 Frame".to_string(),
            Self::NudgeVideoEditRight => "Nudge Video Edit Right 1 Frame".to_string(),
            Self::FitToFill => "Fit to Fill".to_string(),
            Self::ReplaceClipFromSource => "Replace Clip from Source".to_string(),
            Self::ReplaceClipFromProject => "Replace Clip from Project".to_string(),
            Self::ReplaceMode(m) => m.title().to_string(),
            Self::LCut => "L Cut (Audio Trails)".to_string(),
            Self::PlayInToOutRoll => "Play In to Out with Preroll/Postroll".to_string(),
            Self::PlayAround => "Play Around".to_string(),
            Self::SetPosterFrame => "Set Poster Frame".to_string(),
            Self::ClearPosterFrame => "Delete Poster Frame".to_string(),
            Self::ToggleHoverScrub => "Hover Scrub".to_string(),
            Self::Find => "Find…".to_string(),
            Self::ApplyVideoTransition => "Apply Video Transition".to_string(),
            Self::ApplyAudioTransition => "Apply Audio Transition".to_string(),
            Self::ApplyDefaultTransitions => "Apply Default Transitions to Selection".to_string(),
            Self::ToggleCaptionsInMonitor => "Show Captions in Program".to_string(),
            Self::ToggleSafeAreas => "Safe Margins".to_string(),
            Self::ToggleSelectionFollowsPlayhead => "Selection Follows Playhead".to_string(),
            Self::KeywordAtPlayhead => "Keyword at Playhead".to_string(),
            Self::AddTitle => "Add Title".to_string(),
            Self::AutoCaptions => "Transcribe and Create Captions".to_string(),
            Self::AddKeyframe => "Add Keyframe".to_string(),
            Self::PlayFromStart => "Play from Start".to_string(),
            Self::ToggleAllTargets => "Toggle All Targets".to_string(),
            Self::GoToTimecode => "Go to Timecode…".to_string(),
            Self::ToggleVideoTargets => "Toggle Video Targets".to_string(),
            Self::ToggleAudioTargets => "Toggle Audio Targets".to_string(),
            Self::SelectLeftEdge => "Select Left Edge".to_string(),
            Self::SelectRightEdge => "Select Right Edge".to_string(),
            Self::EditMarker => "Edit Marker…".to_string(),
            Self::AddAndEditMarker => "Add and Edit Marker…".to_string(),
        }
    }

    /// Panel name in the UI language (`panel_title` stays English: tests, keys and logs use it).
    pub fn localized_panel_title(p: PanelID) -> String {
        SQL10n::string(Self::panel_title(p))
    }

    pub fn panel_title(p: PanelID) -> &'static str {
        match p {
            PanelID::EffectControls => "Controls",
            PanelID::Text => "Captions",
            PanelID::ColorInspector => "Color",
            PanelID::ColorClips => "Sources",
            PanelID::Steps => "Steps",
            PanelID::Scopes => "Scopes",
            PanelID::Graphics => "Text & Graphics",
            PanelID::ProgramMonitor => "Program",
            PanelID::SourceMonitor => "Source",
            PanelID::Library => "Library",
            PanelID::Effects => "Effects",
            PanelID::MarkerList => "Markers",
            PanelID::Project => "Project",
            PanelID::Timeline => "Timeline",
            PanelID::AudioMeter => "Audio Meters",
            PanelID::Tools => "Tools",
        }
    }

    /// Frames the selected keyframes move when Effect Controls has keyboard focus with keys selected (Final Cut:
    /// Comma / Period, Shift = 10). Without that focus the same keys keep their meaning: `,` `.` are Insert / Overwrite,
    /// Shift+. Place on Top, the nudge commands move clips. nil = not a nudge key.
    pub fn keyframe_nudge_frames(&self) -> Option<i64> {
        match self {
            Self::Insert | Self::NudgeLeft => Some(-1),
            Self::Overwrite | Self::NudgeRight => Some(1),
            Self::NudgeLeft10 => Some(-10),
            Self::NudgeLeft5 => Some(-10),
            Self::PlaceOnTop | Self::NudgeRight10 => Some(10),
            Self::NudgeRight5 => Some(10),
            _ => None,
        }
    }
}

/// Where a binding applies. `global` is the fallback behind every focus-specific scope.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CommandScope {
    Global,
    Timeline,
    Program,
    Source,
    Project,
    EffectControls,
}

impl CommandScope {
    pub const ALL: [CommandScope; 6] =
        [Self::Global, Self::Timeline, Self::Program, Self::Source, Self::Project, Self::EffectControls];

    /// The panels that hold the keyboard while a binding of this scope is in play (`None`: no panel has it). A global
    /// binding applies in every one of them.
    pub fn foci(self) -> Vec<Option<PanelID>> {
        let panels = |scope: CommandScope| -> Vec<Option<PanelID>> {
            match scope {
                Self::Global => Vec::new(),
                Self::Timeline => vec![Some(PanelID::Timeline)],
                Self::Program => vec![Some(PanelID::ProgramMonitor)],
                Self::Source => vec![Some(PanelID::SourceMonitor)],
                Self::Project => vec![Some(PanelID::Project), Some(PanelID::Library)],
                Self::EffectControls => vec![Some(PanelID::EffectControls)],
            }
        };
        match self {
            Self::Global => std::iter::once(None).chain(Self::ALL.into_iter().flat_map(panels)).collect(),
            scoped => panels(scoped),
        }
    }

    /// Scope of a focused panel; panels without own bindings use only `global`.
    pub fn scope_for(panel: Option<PanelID>) -> Option<CommandScope> {
        match panel {
            Some(PanelID::Timeline) => Some(Self::Timeline),
            Some(PanelID::ProgramMonitor) => Some(Self::Program),
            Some(PanelID::SourceMonitor) => Some(Self::Source),
            Some(PanelID::Project) | Some(PanelID::Library) => Some(Self::Project),
            Some(PanelID::EffectControls) => Some(Self::EffectControls),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nudge_keys_map_to_frame_counts() {
        assert_eq!(EditorCommand::Insert.keyframe_nudge_frames(), Some(-1));
        assert_eq!(EditorCommand::Overwrite.keyframe_nudge_frames(), Some(1));
        assert_eq!(EditorCommand::PlaceOnTop.keyframe_nudge_frames(), Some(10));
        assert_eq!(EditorCommand::NudgeLeft.keyframe_nudge_frames(), Some(-1));
        assert_eq!(EditorCommand::NudgeRight10.keyframe_nudge_frames(), Some(10));
        assert_eq!(EditorCommand::NudgeLeft10.keyframe_nudge_frames(), Some(-10));
        assert_eq!(EditorCommand::NudgeLeft5.keyframe_nudge_frames(), Some(-10));
        assert_eq!(EditorCommand::PlayPause.keyframe_nudge_frames(), None);
    }

    #[test]
    fn replace_mode_commands_carry_the_mode_title() {
        for m in ReplaceMode::ALL {
            assert_eq!(EditorCommand::ReplaceMode(m).title(), m.title());
        }
    }

    #[test]
    fn titles_of_parametrised_commands() {
        assert_eq!(EditorCommand::Tool(EditorTool::Razor).title(), "Blade Tool");
        assert_eq!(EditorCommand::ToggleTrackTarget(TrackKind::Audio, 3).title(), "Toggle Target Audio Track 3");
        assert_eq!(EditorCommand::FocusPanel(PanelID::EffectControls).title(), "Show Controls");
        assert_eq!(EditorCommand::SwitchAngle(2).title(), "Switch to Angle 2");
        assert_eq!(EditorCommand::ViewGamma(ViewGammaChoice::Web).title(), "Web 2.2");
        assert_eq!(EditorCommand::DisplayView(DisplayViewChoice::UnToneMapped).title(), "Not Tone-Mapped");
        assert_eq!(
            DisplayViewChoice::ALL.map(DisplayViewChoice::raw_value),
            ["sdr", "displayP3", "hdr1000", "unToneMapped"]
        );
        assert_eq!(EditorCommand::ThumbnailMode(ThumbnailModeChoice::HeadAndTail).title(), "Head and Tail");
        assert_eq!(EditorCommand::EaseLinear.title(), "Linear");
        assert_eq!(EditorCommand::EasyEase.title(), "Ease In & Out");
        assert_eq!(EditorCommand::ShuttleSlowReverse.title(), "Shuttle Slow Reverse");
        assert_eq!(EditorCommand::FitMusicToLength.title(), "Fit Music to Length\u{2026}");
    }

    #[test]
    fn view_choices_keep_their_raw_values() {
        assert_eq!(ViewGammaChoice::ALL.map(ViewGammaChoice::raw_value), ["mac", "web", "broadcast"]);
        assert_eq!(ThumbnailModeChoice::ALL.map(ThumbnailModeChoice::raw_value), ["head", "headAndTail", "continuous"]);
    }

    #[test]
    fn repeat_and_scope() {
        assert!(EditorCommand::StepForward.is_repeatable() && EditorCommand::Undo.is_repeatable());
        assert!(!EditorCommand::PlayPause.is_repeatable());
        assert_eq!(CommandScope::scope_for(Some(PanelID::Library)), Some(CommandScope::Project));
        assert_eq!(CommandScope::scope_for(Some(PanelID::Scopes)), None);
        assert_eq!(CommandScope::scope_for(None), None);
    }
}
