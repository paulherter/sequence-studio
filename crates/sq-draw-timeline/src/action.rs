// Swift: TimelineAction.swift
//! What the timeline panel asks of the host: one variant per Mac `TimelineView` callback. [`crate::session_bridge`]
//! applies them through the `EditorSession` API; the panel never edits the model itself.

use sq_core_edit::source_edit_placement::MarkedRangeDragPart;
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_edit::timeline_trim_mode::TrimPoint;
use sq_core_effects::keystone::{Keystone, KeystoneSpan};
use sq_core_graphics::graphics_move_out::GraphicsLayerDestination;
use sq_core_model::{Clip, ClipEdge, SpeedKeys, Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::{GapSelection, LineKeyRef, SpeedEditPhase, TimelineCommit, TrackToggle};
use sq_timeline_ui::{CaptionWordRef, SlipTwoUp, TransitionChange};
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::editor_command::EditorCommand;
use std::collections::BTreeSet;

/// One request of the panel to its host.
#[derive(Clone, Debug, PartialEq)]
pub enum TimelineAction {
    /// A finished gesture (move, trim, ripple, roll, slip, slide, razor, rate stretch, marquee delete...).
    Commit(Box<TimelineCommit>),
    /// Delete on a selected gap: ripple-closes it (Fast Cut: a spacer on the main track).
    CloseGap(GapSelection),
    /// The selection changed.
    Select { clips: BTreeSet<Id>, captions: BTreeSet<Id> },
    /// Move the playhead.
    Seek(Time),
    /// A scrub begins.
    BeginScrub,
    /// The scrub moved.
    Scrub(Time),
    /// The scrub ended.
    EndScrub,
    /// A track header button or target chip; `shift` / `option` as held (Shift = every track of the kind).
    ToggleTrack { track: Id, toggle: TrackToggle, shift: bool, option: bool },
    /// Add a track.
    AddTrack(TrackKind),
    /// A source patch chip clicked (`solo`: Option, this stream only).
    SourcePatchClick { kind: TrackKind, solo: bool },
    /// A source patch chip dragged onto a track (`both`: Shift).
    SourcePatchMove { kind: TrackKind, to: Id, both: bool },
    /// A sequence marker dragged.
    MoveMarker(Id, Time),
    /// A sequence marker's duration changed.
    SetMarkerDuration(Id, Time),
    /// The In/Out range or one of its ends dragged.
    MoveInOut(TimeRange, MarkedRangeDragPart),
    /// A transition selected (or none).
    SelectTransition { id: Option<Id>, keep_clips: bool },
    /// One step of a transition box drag; `continues` coalesces the steps of one drag into one undo step.
    ChangeTransition { id: Id, change: TransitionChange, continues: bool },
    /// Double-click a transition box: the duration dialog.
    EditTransition(Id),
    /// A transition layer's cut marker dragged to `to`.
    TransitionLayerCut { clip: Id, to: Time, continues: bool },
    /// A transition layer's end dragged to `to` (`symmetric`: the other end mirrors it).
    TransitionLayerResize { clip: Id, edge: ClipEdge, to: Time, symmetric: bool, continues: bool },
    /// Open a nested sequence.
    OpenNestedSequence(Id),
    /// Double-click an edit with the Selection tool; `pointer_before` = the outgoing side was clicked.
    OpenTrimMode { point: TrimPoint, pointer_before: bool },
    /// Edit a text clip.
    EditTextClip(Id),
    /// Edit a tone clip.
    EditToneClip(Id),
    /// Open a graphic's layers.
    OpenGraphicLayers(Id),
    /// Open media in the Source monitor.
    OpenInSource(Id),
    /// Edit a marker.
    EditMarker(Id),
    /// Double-click a clip marker flag: the clip marker editor.
    EditClipMarker { clip: Id, marker: Id },
    /// A dragged clip marker flag.
    MoveClipMarker { clip: Id, marker: Id, to: Time },
    /// One step of a volume / opacity band or fade handle drag: the first opens the undo step `undo_name`, later ones
    /// continue it. `base` is the clip the panel believed the session held when it computed `clip` (the step before):
    /// the session applies only what differs, so an edit another panel made since stays.
    ReplaceClip { clip: Box<Clip>, base: Box<Clip>, undo_name: String, continues: bool },
    /// The band drag that sent `ReplaceClip` ended: its undo step closes.
    EndGesture,
    /// A key on a band was clicked (`extend`: Shift toggles it in the picked set); `None` drops the picked keys.
    LineKeyClick { key: Option<LineKeyRef>, extend: bool },
    /// One phase of a speed band drag.
    SpeedEdit { clip: Id, keys: SpeedKeys, phase: SpeedEditPhase, keeping_keys: bool },
    /// Esc during a speed band drag: the sequence goes back to `restoring`.
    CancelSpeedEdit { clip: Id, restoring: Box<Timeline> },
    /// A key glyph on a selected clip's key lane: Effect Controls picks the keys at `time` (`extend`: Shift).
    KeyLaneClick { clip: Id, time: Time, extend: bool },
    /// A right press at a panel point: the host shows the context menu there.
    ContextMenu(CGPoint),
    /// A shell command the panel triggers itself.
    Command(EditorCommand),
    /// The Fast Cut skimmer moved to a frame (`None`: it is hidden).
    Skim(Option<Time>),
    /// Slip drag: the two-up the Program monitor shows (`None` = back to normal), with the preview timeline it reads.
    SlipTwoUp(Option<SlipTwoUp>, Box<Timeline>),
    /// Project-panel media dropped on the panel: on `track` (`None` = the targeted tracks) or on a new track of `new_track`.
    DropMedia {
        ids: Vec<Id>,
        time: Time,
        track: Option<Id>,
        new_track: Option<TrackKind>,
        insert: bool,
        streams: SourceStreams,
    },
    /// A keystone dropped on a clip at `span` (clip-local), one undo step; the bar shows.
    DropKeystone { keystone: Box<Keystone>, clip: Id, span: KeystoneSpan },
    /// The bar of the keystone applied last was stretched, one undo step.
    RestretchKeystone { clip: Id, from: KeystoneSpan, to: KeystoneSpan, name: String },
    /// Items picked in a clip's item lanes: the clip is selected, the host's item selection follows.
    SelectItems { clip: Id, items: BTreeSet<Id> },
    /// The disclosure arrow of a text or shape clip: it becomes a Graphic first.
    MakeGraphic(Id),
    /// A lane name dropped within its Graphic: the items go to `to_index` (bottom first), one undo step.
    ReorderItems { clip: Id, ids: Vec<Id>, to_index: usize },
    /// A lane name dropped on another Graphic or a free video stretch; `copy` keeps the originals.
    MoveItemsOut { clip: Id, ids: Vec<Id>, to: GraphicsLayerDestination, copy: bool },
    /// Fast Cut: the attached clip's attach point moved to `time`, one undo step.
    SetAttachPoint { clip: Id, time: Time },
    /// The eye in a caption track's header.
    ToggleCaptionTrackVisibility(Id),
    /// A caption double-click: the word under the pointer (inline word field) or, without one, the Text panel.
    EditCaption(Id, Option<CaptionWordRef>),
    /// A refused gesture's reason or a hint for the status line.
    Status(String),
}
