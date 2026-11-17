// Swift: TimelineInteraction.swift
//! Pure gesture reducer for the timeline (no AppKit). The view forwards mouse events in view coordinates plus the
//! modifier state; the reducer owns selection, a live `preview` timeline and, on `mouse_up`, hands back ONE
//! `TimelineCommit` (edit list + resulting timeline + undo name) per gesture.
//!
//! Flow: `mouse_down` picks the gesture from tool + hit test, `mouse_dragged` recomputes `preview` from the ORIGINAL
//! `timeline` (never incrementally), `mouse_up` commits (or returns `None` when nothing changed / the edit was refused).
//! `cancel()` (Escape) drops the gesture. `timeline` only changes on commit, so the caller can snapshot for undo.

use crate::caption_word_layout::{CaptionWordLayout, CaptionWordRef};
use crate::rect_math::intersects;
use crate::slip_two_up::SlipTwoUp;
use crate::split_roll::{SplitRoll, SplitRollGhost};
use crate::timeline_autoscroll::{AxisLock, LockAxis};
use crate::timeline_geometry::{ClipZone, TimelineGeometry, TimelineHit, TrackRow};
use sq_core_audio::caption_handover::TimelineCaptionsExt;
use sq_core_edit::snapping::{SnapPoint, SnappingTimelineExt, snap, snap_move};
use sq_core_edit::timeline_bundle::TimelineBundleExt;
use sq_core_edit::timeline_clip_index::TimelineClipIndex;
use sq_core_edit::timeline_clipboard::TimelineClipboardExt;
use sq_core_edit::timeline_edits::{CopySpec, SlipKeyframes};
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt};
use sq_core_model::{CaptionItem, Clip, ClipEdge, EditError, Project, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_editor_session::{
    EdgeEdits, EdgeRef, EdgeSelection, EditorSession, GapSelection, GestureModifiers, TimelineCommit, TimelineEdit,
    TimelineTool,
};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

/// Foundation's `CharacterSet.whitespacesAndNewlines` (Zs, Zl, Zp, U+0009-U+000D, U+0085, U+200B).
// shortcut: private copy of the predicate in sq-prproj-reader; move it to sq_core_time::text when that crate may be edited.
pub(crate) fn is_ws(c: char) -> bool {
    matches!(c as u32,
        0x09..=0x0D | 0x20 | 0x85 | 0xA0 | 0x1680 | 0x2000..=0x200B | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000)
}

/// Fast Cut live reorder preview: while a main-track clip is dragged along V1, where the pointer holds it (the clip
/// floats there; `preview` already shows the neighbors opened up and the slot the drop lands in).
#[derive(Clone, Debug, PartialEq)]
pub struct ReorderGhost {
    /// The main track.
    pub track: Id,
    /// Where the clip floats.
    pub range: TimeRange,
    /// The clip's name.
    pub name: String,
}

/// Result of `nest`: the edited project, the commit for the outer timeline and the new sequence.
#[derive(Clone, Debug, PartialEq)]
pub struct NestResult {
    /// The edited project.
    pub project: Project,
    /// The commit for the outer timeline.
    pub commit: TimelineCommit,
    /// The new sequence.
    pub sequence: Id,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GestureKind {
    Click,
    Marquee,
    Move,
    CaptionMove,
    CaptionTrim,
    WordRetime,
    Trim,
    RippleTrim,
    RateStretch,
    Roll,
    SplitRoll,
    Slip,
    Slide,
    Razor,
    Hand,
}

#[derive(Clone, Debug)]
struct BeforePress {
    clips: BTreeSet<Id>,
    captions: BTreeSet<Id>,
    gap: Option<GapSelection>,
    edges: Option<EdgeSelection>,
}

#[derive(Clone, Debug)]
struct Gesture {
    kind: GestureKind,
    down_point: Point,
    down_time: Time,
    clip: Option<Id>,
    caption: Option<Id>,
    /// `WordRetime`: the word whose edge is dragged.
    word: usize,
    edge: ClipEdge,
    /// `SplitRoll`: the cut whose audio edit is dragged.
    cut: Time,
    active: bool,
    new_track: Option<Track>,
    new_tracks: HashMap<TrackKind, Vec<Track>>,
    sticky_row: Option<usize>,
    base_selection: BTreeSet<Id>,
    /// Captions selected before a marquee started (a Shift marquee keeps them).
    base_captions: BTreeSet<Id>,
    /// Everything selected before the press (clips, captions, gap, edges): Esc on a marquee puts it back.
    before_press: Option<BeforePress>,
    reduce_to: Option<BTreeSet<Id>>,
    scroll_origin: Point,
    /// Option-drag: identities of the copies, stable for the whole gesture.
    copy_ids: std::collections::BTreeMap<Id, Id>,
    copy_links: std::collections::BTreeMap<Id, Id>,
    /// Shift while moving: the axis the pointer moved along first.
    axis_lock: AxisLock,
    /// Option went down before Command: a later Command makes it an insert copy, not a rearrange.
    copy_latched: bool,
    /// Clips the gesture edits; linked partners outside it stay put (Option-click / Linked Selection off).
    /// `None`: linked partners follow as usual.
    scope: Option<BTreeSet<Id>>,
}

impl Gesture {
    fn new(kind: GestureKind, down_point: Point, down_time: Time) -> Gesture {
        Gesture {
            kind,
            down_point,
            down_time,
            clip: None,
            caption: None,
            word: 0,
            edge: ClipEdge::Tail,
            cut: Time::ZERO,
            active: false,
            new_track: None,
            new_tracks: HashMap::new(),
            sticky_row: None,
            base_selection: BTreeSet::new(),
            base_captions: BTreeSet::new(),
            before_press: None,
            reduce_to: None,
            scroll_origin: Point::ZERO,
            copy_ids: Default::default(),
            copy_links: Default::default(),
            axis_lock: AxisLock::new(),
            copy_latched: false,
            scope: None,
        }
    }
}

/// Snap points of the committed `timeline` for one exclusion set, playhead and markers. The first event of a gesture
/// computes them; later events reuse them while the key is the same (on 2000 clips recomputing was ~60 % of a drag
/// event). Gestures snap against `timeline`, never `preview`, so ripple/Fast Cut shifts and the moving selection (the
/// `excluding` key) need nothing extra; `timeline` changing (commit, reset) drops the cache.
#[derive(Clone, Debug)]
struct SnapCache {
    excluding: BTreeSet<Id>,
    playhead: Option<Time>,
    markers: Vec<Time>,
    points: Arc<Vec<SnapPoint>>,
}

/// Makes the identities of the tracks and copies a gesture creates: `seed`, `seed + 1`, ... The caller picks a seed that
/// cannot meet the ids of the project (a random one); the reducer stays cloneable and needs no random source of its own.
#[derive(Clone, Debug)]
struct IdMint(u128);

impl IdSource for IdMint {
    fn next_id(&mut self) -> Id {
        self.0 = self.0.wrapping_add(1);
        Id::from_u128(self.0)
    }
}

/// The gesture reducer.
#[derive(Clone)]
pub struct TimelineInteraction {
    /// Committed timeline (what undo snapshots).
    timeline: Timeline,
    /// Clip ID -> track/position of `timeline` (rebuilt whenever `timeline` changes: init, reset, commit). Drag events
    /// look clips up many times per event; a scan over all tracks was about a third of the drag cost.
    index: TimelineClipIndex,
    /// View geometry.
    pub geometry: TimelineGeometry,
    /// Tool column state.
    pub tool_state: sq_editor_session::ToolState,
    /// Playhead time (a snap target).
    pub playhead: Option<Time>,
    /// Marker times (snap targets).
    pub markers: Vec<Time>,
    selection: BTreeSet<Id>,
    caption_selection: BTreeSet<Id>,
    edge_selection: Option<EdgeSelection>,
    gap_selection: Option<GapSelection>,
    preview: Timeline,
    pending_edits: Vec<TimelineEdit>,
    pending_undo_name: Option<String>,
    snap_time: Option<Time>,
    split_roll_ghost: Option<SplitRollGhost>,
    marquee: Option<Rect>,
    is_rejected: bool,
    rejection_message: Option<String>,
    released_rejection: Option<String>,
    /// Copies the in-flight Option-drag creates (they become the selection on commit).
    pending_copies: BTreeSet<Id>,
    gesture: Option<Gesture>,
    snap_cache: Option<SnapCache>,
    /// Tests: false recomputes on every call (the reference the cache is checked against).
    pub(crate) snap_cache_enabled: bool,
    word_selection: Option<CaptionWordRef>,
    move_hint: Option<String>,
    reorder_ghost: Option<ReorderGhost>,
    /// Hold-S: snapping flipped for the gesture in flight (Premiere's momentary snap toggle). Reset by every mouse down.
    pub snap_inverted: bool,
    ids: IdMint,
}

impl TimelineInteraction {
    /// Pixels the pointer must travel before a press becomes a drag.
    pub const DRAG_THRESHOLD: f64 = 3.0;
    /// Cursor hint while the Blade is dragged: the cut was made at the click, the drag does nothing.
    pub const RAZOR_DRAG_HINT: &'static str = "Cut made at the click";
    /// Extra points the pointer may leave the previous target row before the target changes (no flicker at row edges).
    pub const ROW_HYSTERESIS: f64 = 6.0;

    /// A reducer over `timeline`. Tracks and copies a gesture creates get the ids `id_seed + 1`, `id_seed + 2`, ...
    pub fn new(timeline: Timeline, geometry: TimelineGeometry, id_seed: u128) -> TimelineInteraction {
        TimelineInteraction {
            index: TimelineClipIndex::of(&timeline),
            preview: timeline.clone(),
            timeline,
            geometry,
            tool_state: sq_editor_session::ToolState::default(),
            playhead: None,
            markers: Vec::new(),
            selection: BTreeSet::new(),
            caption_selection: BTreeSet::new(),
            edge_selection: None,
            gap_selection: None,
            pending_edits: Vec::new(),
            pending_undo_name: None,
            snap_time: None,
            split_roll_ghost: None,
            marquee: None,
            is_rejected: false,
            rejection_message: None,
            released_rejection: None,
            pending_copies: BTreeSet::new(),
            gesture: None,
            snap_cache: None,
            snap_cache_enabled: true,
            word_selection: None,
            move_hint: None,
            reorder_ghost: None,
            snap_inverted: false,
            ids: IdMint(id_seed),
        }
    }

    // MARK: Read access

    /// Committed timeline (what undo snapshots).
    pub fn timeline(&self) -> &Timeline {
        &self.timeline
    }

    /// Assigns a new committed timeline (rebuilds the clip index, drops the snap cache).
    fn set_timeline(&mut self, t: Timeline) {
        self.index = TimelineClipIndex::of(&t);
        self.snap_cache = None;
        self.timeline = t;
    }

    /// Selected clips.
    pub fn selection(&self) -> &BTreeSet<Id> {
        &self.selection
    }

    /// Selected caption items (separate from clips; a click on one kind clears the other).
    pub fn caption_selection(&self) -> &BTreeSet<Id> {
        &self.caption_selection
    }

    /// Selected clip edges (click on a head or tail); a click elsewhere clears them.
    pub fn edge_selection(&self) -> Option<&EdgeSelection> {
        self.edge_selection.as_ref()
    }

    /// Selected gap between two clips (Delete closes it).
    pub fn gap_selection(&self) -> Option<&GapSelection> {
        self.gap_selection.as_ref()
    }

    /// What the view should draw: `timeline` with the in-flight gesture applied.
    pub fn preview(&self) -> &Timeline {
        &self.preview
    }

    /// Edits of the in-flight gesture.
    pub fn pending_edits(&self) -> &[TimelineEdit] {
        &self.pending_edits
    }

    /// Undo name of the in-flight gesture.
    pub fn pending_undo_name(&self) -> Option<&str> {
        self.pending_undo_name.as_deref()
    }

    /// Time the dragged edge/clip is snapped to (snap line in the view), `None` when nothing is snapped.
    pub fn snap_time(&self) -> Option<Time> {
        self.snap_time
    }

    /// Option-drag on a cut (audio-only roll): the cut and the applied audio offset (negative = audio leads, J cut). The
    /// view draws the ghost edge at the cut and the label; `None` outside that gesture.
    pub fn split_roll_ghost(&self) -> Option<SplitRollGhost> {
        self.split_roll_ghost
    }

    /// Marquee rectangle in view coordinates while one is being dragged.
    pub fn marquee(&self) -> Option<Rect> {
        self.marquee
    }

    /// The last drag position was refused by the model (locked track, collision...). Nothing will be committed.
    pub fn is_rejected(&self) -> bool {
        self.is_rejected
    }

    /// Why the last command (nest, ...) was refused; `None` otherwise. Cleared by the next mouse down / cancel.
    pub fn rejection_message(&self) -> Option<&str> {
        self.rejection_message.as_deref()
    }

    /// Why the gesture that just ended with `mouse_up` was refused (`None`: it was not). The host shows it in the status bar.
    pub fn released_rejection(&self) -> Option<&str> {
        self.released_rejection.as_deref()
    }

    /// No gesture in flight (the view may start a track resize).
    pub fn is_idle(&self) -> bool {
        self.gesture.is_none()
    }

    /// What the move gesture in flight does ("Insert", "Rearrange", "Copy", "Insert copy"); the view shows it as a hint.
    pub fn move_hint(&self) -> Option<&str> {
        self.move_hint.as_deref()
    }

    /// Fast Cut live reorder preview, `None` otherwise.
    pub fn reorder_ghost(&self) -> Option<&ReorderGhost> {
        self.reorder_ghost.as_ref()
    }

    /// The selected word of a caption (caption track at word level). Its caption is selected with it; any other press
    /// clears it. Delete removes the word, a double-click types into it.
    pub fn word_selection(&self) -> Option<CaptionWordRef> {
        self.word_selection
    }

    // MARK: Reset and programmatic selection

    /// Replaces the committed timeline (undo/redo, external edits). Drops any gesture and prunes the selection.
    pub fn reset(&mut self, timeline: Timeline) {
        self.set_timeline(timeline);
        self.cancel();
        let alive: BTreeSet<Id> = self.timeline.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
        self.selection.retain(|i| alive.contains(i));
        let alive_captions: BTreeSet<Id> =
            self.timeline.caption_tracks.iter().flat_map(|t| t.items().iter().map(|i| i.id)).collect();
        self.caption_selection.retain(|i| alive_captions.contains(i));
        self.set_word_selection(self.word_selection);
        self.edge_selection = self.edge_selection.as_ref().and_then(|e| EdgeEdits::pruned(e, &self.timeline));
        if let Some(g) = self.gap_selection
            && self.timeline.gap(g.track, g.range.start) != Some(g.range)
        {
            self.gap_selection = None;
        }
    }

    /// Selects a word (`None`: none). A word that does not exist is dropped.
    pub fn set_word_selection(&mut self, r: Option<CaptionWordRef>) {
        let Some(r) = r else {
            self.word_selection = None;
            return;
        };
        let ok = self.caption_item(r.caption).is_some_and(|item| r.index < item.tokens().len());
        self.word_selection = if ok { Some(r) } else { None };
    }

    /// A word edit made outside a gesture (typed, inserted, deleted, split, joined, replaced): the result becomes the
    /// committed timeline. One commit, so one undo step.
    pub fn commit_caption_edit(
        &mut self,
        out: Timeline,
        undo_name: &str,
        captions: &BTreeSet<Id>,
        word: Option<CaptionWordRef>,
    ) -> TimelineCommit {
        self.cancel();
        self.set_timeline(out.clone());
        self.preview = out.clone();
        self.selection = BTreeSet::new();
        let alive: BTreeSet<Id> = out.caption_tracks.iter().flat_map(|t| t.items().iter().map(|i| i.id)).collect();
        self.caption_selection = captions.intersection(&alive).copied().collect();
        self.set_word_selection(word);
        TimelineCommit::new(out, Vec::new(), undo_name, BTreeSet::new(), self.caption_selection.clone())
    }

    /// Clears edge and gap selection (they are exclusive with clip selection).
    fn clear_edge_and_gap(&mut self) {
        self.edge_selection = None;
        self.gap_selection = None;
    }

    /// Escape with nothing in flight: only the selection goes (gap, edges). The timeline is not touched.
    pub fn clear_gap_and_edge_selection(&mut self) -> bool {
        if !(self.is_idle() && (self.gap_selection.is_some() || self.edge_selection.is_some())) {
            return false;
        }
        self.clear_edge_and_gap();
        true
    }

    /// Selects clip edges (`None` clears).
    pub fn set_edge_selection(&mut self, e: Option<EdgeSelection>) {
        let some = e.is_some();
        self.edge_selection = e;
        if some {
            self.gap_selection = None;
        }
    }

    /// Programmatic selection (Cmd+A, paste, undo...). A non-empty selection replaces any edge or gap selection;
    /// an empty echo after an edge click leaves it alone.
    pub fn set_selection(&mut self, ids: BTreeSet<Id>) {
        let non_empty = !ids.is_empty();
        self.selection = ids;
        if non_empty {
            self.clear_edge_and_gap();
        }
    }

    /// Selects caption items.
    pub fn set_caption_selection(&mut self, ids: BTreeSet<Id>) {
        self.caption_selection = ids;
    }

    /// Caption item under a view point (for double-click to edit text), `None` elsewhere.
    pub fn caption_item_at(&self, p: Point) -> Option<Id> {
        if let TimelineHit::Caption(id, _) = self.geometry.hit_test(p, &self.timeline) {
            return Some(id);
        }
        None
    }

    fn caption_item(&self, id: Id) -> Option<&CaptionItem> {
        self.timeline.caption_tracks.iter().find_map(|t| t.items().iter().find(|i| i.id == id))
    }

    /// Drops the gesture in flight.
    pub fn cancel(&mut self) {
        // Esc during a marquee: the selection from before the press comes back (the press itself cleared it).
        if let Some(g) = &self.gesture
            && g.kind == GestureKind::Marquee
            && let Some(b) = g.before_press.clone()
        {
            self.selection = b.clips;
            self.caption_selection = b.captions;
            self.gap_selection = b.gap;
            self.edge_selection = b.edges;
        }
        self.snap_inverted = false;
        self.move_hint = None;
        self.reorder_ghost = None;
        self.gesture = None;
        self.preview = self.timeline.clone();
        self.pending_edits = Vec::new();
        self.pending_undo_name = None;
        self.snap_time = None;
        self.marquee = None;
        self.is_rejected = false;
        self.rejection_message = None;
        self.pending_copies = BTreeSet::new();
    }

    // MARK: Lookup helpers

    fn clip(&self, id: Id) -> Option<&Clip> {
        self.index.clip(id, &self.timeline)
    }

    fn track_id_of(&self, id: Id) -> Option<Id> {
        self.index.track_id(id)
    }

    /// The clip plus its linked partners when `linked`.
    fn group(&self, id: Id, linked: bool) -> BTreeSet<Id> {
        let Some(c) = self.clip(id) else { return BTreeSet::new() };
        let Some(l) = c.link.filter(|_| linked) else { return BTreeSet::from([id]) };
        self.index.clips_linked_by(l).iter().copied().collect()
    }

    fn groups(&self, ids: &BTreeSet<Id>, linked: bool) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        for i in ids {
            out.extend(self.group(*i, linked));
        }
        out
    }

    /// What a click selects: the clip's link group, plus its bundle (v57) and the bundle members' partners when `linked`
    /// (Option-click picks the one clip, like Premiere's groups).
    fn selection_group(&self, id: Id, linked: bool) -> BTreeSet<Id> {
        let Some(b) = self.clip(id).and_then(|c| c.bundle).filter(|_| linked) else {
            return self.group(id, linked);
        };
        let mut members: BTreeSet<Id> = self.index.clips_bundled_by(b).iter().copied().collect();
        members.insert(id);
        self.groups(&members, true)
    }

    fn selection_groups(&self, ids: &BTreeSet<Id>, linked: bool) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        for i in ids {
            out.extend(self.selection_group(*i, linked));
        }
        out
    }

    fn linked(&self, m: GestureModifiers) -> bool {
        self.tool_state.linked_selection != m.contains(GestureModifiers::OPTION)
    }

    /// Scope of a tool gesture on `id` (B, N, Y, U): the selection when it holds the clip (a partner left out of it
    /// stays put), else the clip's group as Linked Selection / Option pick it.
    fn tool_scope(&self, id: Id, m: GestureModifiers) -> BTreeSet<Id> {
        if self.selection.contains(&id) { self.selection.clone() } else { self.group(id, self.linked(m)) }
    }

    /// The clip plus the linked partners inside `scope` (all partners without a scope).
    fn group_within(&self, id: Id, scope: &Option<BTreeSet<Id>>) -> BTreeSet<Id> {
        let g = self.group(id, true);
        match scope {
            Some(s) => {
                let mut out: BTreeSet<Id> = g.intersection(s).copied().collect();
                out.insert(id);
                out
            }
            None => g,
        }
    }

    fn clip_x(&self, c: &Clip) -> (f64, f64) {
        (self.geometry.x(c.timeline().start), self.geometry.x(c.timeline().end()))
    }

    fn cached_snap_points(&self, excluding: &BTreeSet<Id>) -> Option<Arc<Vec<SnapPoint>>> {
        let c = self.snap_cache.as_ref()?;
        if self.snap_cache_enabled
            && c.playhead == self.playhead
            && c.markers == self.markers
            && c.excluding == *excluding
        {
            return Some(Arc::clone(&c.points));
        }
        None
    }

    fn snap_points(&mut self, excluding: &BTreeSet<Id>) -> Arc<Vec<SnapPoint>> {
        if let Some(pts) = self.cached_snap_points(excluding) {
            return pts;
        }
        let pts = Arc::new(self.timeline.snap_points(excluding, self.playhead, &self.markers, true));
        if self.snap_cache_enabled {
            self.snap_cache = Some(SnapCache {
                excluding: excluding.clone(),
                playhead: self.playhead,
                markers: self.markers.clone(),
                points: Arc::clone(&pts),
            });
        }
        pts
    }

    /// While a Slip drag runs: first and last frame of the slipped clip for the two-up viewer; `None` otherwise.
    /// Seek `preview` to `head_time` and `tail_time`.
    pub fn slip_two_up(&self) -> Option<SlipTwoUp> {
        let g = self.gesture.as_ref()?;
        if !(g.kind == GestureKind::Slip && g.active) {
            return None;
        }
        let id = g.clip?;
        let now = self.preview.tracks.iter().find_map(|t| t.clips().iter().find(|c| c.id == id))?;
        let start = self.clip(id)?;
        Some(SlipTwoUp::new(now, self.timeline.frame_duration(), start.source.start))
    }

    fn snapping_on(&self) -> bool {
        self.tool_state.snapping != self.snap_inverted
    }

    // MARK: Mouse

    /// A press at `p`.
    pub fn mouse_down(&mut self, p: Point, m: GestureModifiers) {
        self.cancel();
        self.snap_inverted = false;
        let hit = self.geometry.hit_test(p, &self.timeline);
        let down_time = self.geometry.time(p.x);
        let mut g = Gesture::new(GestureKind::Click, p, down_time);
        g.before_press = Some(BeforePress {
            clips: self.selection.clone(),
            captions: self.caption_selection.clone(),
            gap: self.gap_selection,
            edges: self.edge_selection.clone(),
        });
        // Position (Fast Cut): selects and drags like Selection; `publish` turns the drag into a position move.
        let tool = if self.tool_state.timeline_tool() == TimelineTool::Position {
            TimelineTool::Selection
        } else {
            self.tool_state.timeline_tool()
        };
        let had_edges = self.edge_selection.clone();
        self.clear_edge_and_gap();
        self.word_selection = None;
        let shift = m.contains(GestureModifiers::SHIFT);
        let command = m.contains(GestureModifiers::COMMAND);
        let option = m.contains(GestureModifiers::OPTION);

        if tool == TimelineTool::Hand {
            g.kind = GestureKind::Hand;
            g.scroll_origin = Point::new(self.geometry.scroll_x, self.geometry.scroll_y);
            self.gesture = Some(g);
            return;
        }

        match (tool, hit) {
            (TimelineTool::Selection, TimelineHit::Caption(id, zone)) => {
                g.caption = Some(id);
                g.kind = if zone == ClipZone::Body { GestureKind::CaptionMove } else { GestureKind::CaptionTrim };
                g.edge = if zone == ClipZone::Head { ClipEdge::Head } else { ClipEdge::Tail };
                // Two depths: a press selects the caption; a press on a word of the caption that already was the selection
                // selects that word. So Delete after one click removes the caption, never a word by accident.
                let was_the_selection = self.caption_selection == BTreeSet::from([id]) && self.selection.is_empty();
                self.selection = BTreeSet::new();
                if shift && zone == ClipZone::Body {
                    if !self.caption_selection.remove(&id) {
                        self.caption_selection.insert(id);
                    }
                } else if !self.caption_selection.contains(&id) {
                    self.caption_selection = BTreeSet::from([id]);
                }
                // Word level: one of a word's inner edges retimes it (at either depth). The caption's own edges keep
                // trimming the caption, and a Shift-click only changes which captions are selected.
                if zone == ClipZone::Body
                    && !shift
                    && let Some(w) = CaptionWordLayout::hit(p, id, &self.timeline, &self.geometry)
                {
                    if was_the_selection {
                        self.word_selection = Some(w.word);
                    }
                    if w.zone != ClipZone::Body {
                        g.kind = GestureKind::WordRetime;
                        g.word = w.word.index;
                        g.edge = if w.zone == ClipZone::Head { ClipEdge::Head } else { ClipEdge::Tail };
                    }
                }
            }
            (TimelineTool::Selection, TimelineHit::CaptionGap(..) | TimelineHit::CaptionHeader(_)) => {
                if !shift {
                    self.selection = BTreeSet::new();
                    self.caption_selection = BTreeSet::new();
                }
                g.kind = GestureKind::Marquee;
                g.base_selection = self.selection.clone();
                g.base_captions = self.caption_selection.clone();
            }
            (TimelineTool::Selection, TimelineHit::Clip(id, zone)) => {
                g.clip = Some(id);
                if !shift {
                    self.caption_selection = BTreeSet::new();
                }
                let linked = self.linked(m);
                let grp = self.selection_group(id, linked);
                if zone != ClipZone::Body {
                    // Premiere: a click on an edge selects the edge (not the clip). Cmd = ripple trim; Shift adds the edge
                    // (both sides of an edit = rolling edit).
                    g.edge = if zone == ClipZone::Head { ClipEdge::Head } else { ClipEdge::Tail };
                    let edge = g.edge;
                    let r = EdgeRef::new(id, edge);
                    let mut sel = EdgeSelection::new(vec![r], command, linked);
                    // Bundle (v57): a plain trim also takes the same edge of every member sharing its time (the bundle's outer edge).
                    if !sel.ripple && sel.linked {
                        sel.edges.extend(
                            self.timeline.bundle_edge_peers(id, edge).into_iter().map(|c| EdgeRef::new(c, edge)),
                        );
                    }
                    if shift && had_edges.as_ref().is_some_and(|h| h.ripple == sel.ripple) {
                        if let Some(had) = &had_edges {
                            sel.edges = if had.edges.contains(&r) {
                                had.edges.iter().copied().filter(|e| *e != r).collect()
                            } else {
                                let mut v = had.edges.clone();
                                v.push(r);
                                v
                            };
                        }
                    } else if let Some(had) = had_edges.as_ref().filter(|h| h.edges.contains(&r) && !command) {
                        sel = had.clone(); // dragging an already selected edge keeps the selection
                    }
                    self.selection = BTreeSet::new();
                    self.edge_selection = if sel.edges.is_empty() { None } else { Some(sel) };
                    if let Some(e) = &self.edge_selection {
                        g.kind = if EdgeEdits::is_roll(e, &self.timeline) {
                            GestureKind::Roll
                        } else if e.ripple {
                            GestureKind::RippleTrim
                        } else {
                            GestureKind::Trim
                        };
                        g.scope = e.scope();
                    }
                    // Option on a cut of linked A/V: the drag moves only the audio edit (J / L cut in one gesture).
                    if option
                        && !shift
                        && !command
                        && let Some(cut) = SplitRoll::cut(&r, &self.timeline)
                    {
                        g.kind = GestureKind::SplitRoll;
                        g.cut = cut;
                    }
                } else if shift {
                    if self.selection.contains(&id) {
                        for i in &grp {
                            self.selection.remove(i);
                        }
                    } else {
                        self.selection.extend(grp);
                    }
                } else {
                    g.kind = GestureKind::Move;
                    if self.selection.contains(&id) {
                        g.reduce_to = Some(grp);
                    } else {
                        self.selection = grp;
                    }
                    g.scope = Some(self.selection.clone());
                }
            }
            (TimelineTool::Selection, TimelineHit::Gap(track, t)) => {
                if !shift {
                    self.selection = BTreeSet::new();
                    self.caption_selection = BTreeSet::new();
                }
                if let Some(r) = self.timeline.gap(track, t) {
                    self.gap_selection = Some(GapSelection::new(track, r));
                    self.selection = BTreeSet::new();
                }
                g.kind = GestureKind::Marquee;
                g.base_selection = self.selection.clone();
                g.base_captions = self.caption_selection.clone();
            }
            (TimelineTool::Selection, TimelineHit::None) => {
                if !shift {
                    self.selection = BTreeSet::new();
                    self.caption_selection = BTreeSet::new();
                }
                g.kind = GestureKind::Marquee;
                g.base_selection = self.selection.clone();
                g.base_captions = self.caption_selection.clone();
            }
            (TimelineTool::TrackSelectForward, TimelineHit::Clip(id, _)) => {
                let track = self.timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == id)).map(|t| t.id);
                let pivot = if self.tool_state.select_backward {
                    self.clip(id).map(|c| c.timeline().end())
                } else {
                    self.clip(id).map(|c| c.start)
                }
                .unwrap_or(Time::ZERO);
                let linked = self.linked(m);
                self.select_forward(track, pivot, !shift, linked);
            }
            (TimelineTool::TrackSelectForward, TimelineHit::Gap(track, t)) => {
                let linked = self.linked(m);
                self.select_forward(Some(track), t, !shift, linked);
            }
            (TimelineTool::RippleEdit | TimelineTool::RollEdit, TimelineHit::Clip(id, zone)) => {
                g.clip = Some(id);
                g.kind = if tool == TimelineTool::RippleEdit { GestureKind::RippleTrim } else { GestureKind::Roll };
                g.edge = self.nearest_edge(id, zone, p.x);
                g.scope = Some(self.tool_scope(id, m));
            }
            (TimelineTool::RateStretch, TimelineHit::Clip(id, zone)) => {
                g.clip = Some(id);
                g.kind = GestureKind::RateStretch;
                g.edge = self.nearest_edge(id, zone, p.x);
                if !self.selection.contains(&id) {
                    let linked = self.linked(m);
                    self.selection = self.selection_group(id, linked);
                }
                g.scope = Some(self.selection.clone());
            }
            (TimelineTool::Slip, TimelineHit::Clip(id, _)) => {
                g.kind = GestureKind::Slip;
                g.clip = Some(id);
                g.scope = Some(self.tool_scope(id, m));
            }
            (TimelineTool::Slide, TimelineHit::Clip(id, _)) => {
                g.kind = GestureKind::Slide;
                g.clip = Some(id);
                g.scope = Some(self.tool_scope(id, m));
            }
            (TimelineTool::Razor, TimelineHit::Clip(id, _)) => {
                g.kind = GestureKind::Razor;
                g.clip = Some(id);
                g.active = true;
                self.gesture = Some(g);
                self.razor_preview(p, Some(id), m);
                return;
            }
            (TimelineTool::Razor, TimelineHit::Gap(..)) if shift => {
                // Shift+click cuts all tracks at that time, also when the pointer is over an empty spot of one track.
                g.kind = GestureKind::Razor;
                g.active = true;
                self.gesture = Some(g);
                self.razor_preview(p, None, m);
                return;
            }
            _ => return,
        }
        self.gesture = Some(g);
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: Point, m: GestureModifiers) {
        let Some(mut g) = self.gesture.clone() else { return };
        if !g.active {
            if (p.x - g.down_point.x).hypot(p.y - g.down_point.y) < Self::DRAG_THRESHOLD {
                return;
            }
            g.active = true;
        }
        self.gesture = Some(g.clone());
        match g.kind {
            GestureKind::Click => {}
            GestureKind::Razor => {
                // The Blade cut at the click already; dragging moves nothing. Say so at the cursor.
                self.move_hint = Some(Self::RAZOR_DRAG_HINT.to_string());
            }
            GestureKind::Hand => {
                self.geometry.scroll_x = (g.scroll_origin.x - (p.x - g.down_point.x)).max(0.0);
                self.geometry.scroll_y = (g.scroll_origin.y - (p.y - g.down_point.y)).max(0.0);
            }
            GestureKind::Marquee => self.update_marquee(p, m),
            GestureKind::Move => self.update_move(p, m),
            GestureKind::CaptionMove => self.update_caption_move(p),
            GestureKind::CaptionTrim => self.update_caption_trim(p),
            GestureKind::WordRetime => self.update_word_retime(p, m.contains(GestureModifiers::OPTION)),
            GestureKind::Trim | GestureKind::RippleTrim => self.update_trim(p),
            GestureKind::RateStretch => self.update_rate_stretch(p),
            GestureKind::Roll => self.update_roll(p),
            GestureKind::SplitRoll => self.update_split_roll(p),
            GestureKind::Slip => self.update_slip(p),
            GestureKind::Slide => self.update_slide(p),
        }
    }

    /// Finishes the gesture. Returns the commit when the gesture changed the timeline.
    pub fn mouse_up(&mut self, p: Point, m: GestureModifiers) -> Option<TimelineCommit> {
        self.released_rejection = None;
        let g = self.gesture.clone()?;
        if g.active && g.kind != GestureKind::Razor {
            self.mouse_dragged(p, m);
        }
        self.released_rejection = if self.is_rejected { self.rejection_message.clone() } else { None };
        let commit = self.finish(&g);
        // What Swift's `defer` does after the body.
        self.snap_inverted = false;
        self.move_hint = None;
        self.reorder_ghost = None;
        self.gesture = None;
        self.marquee = None;
        self.snap_time = None;
        self.split_roll_ghost = None;
        self.pending_edits = Vec::new();
        self.pending_undo_name = None;
        self.is_rejected = false;
        self.preview = self.timeline.clone();
        self.pending_copies = BTreeSet::new();
        commit
    }

    fn finish(&mut self, g: &Gesture) -> Option<TimelineCommit> {
        if !g.active
            && let Some(r) = &g.reduce_to
        {
            self.selection = r.clone();
        }
        let name = self.pending_undo_name.clone();
        if !(g.active
            && !self.is_rejected
            && !self.pending_edits.is_empty()
            && name.is_some()
            && self.preview != self.timeline)
        {
            return None;
        }
        let name = name?;
        if !self.pending_copies.is_empty() {
            let alive: BTreeSet<Id> = self.preview.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
            self.selection = self.pending_copies.intersection(&alive).copied().collect();
        }
        let commit = TimelineCommit::new(
            self.preview.clone(),
            self.pending_edits.clone(),
            &name,
            self.selection.clone(),
            self.caption_selection.clone(),
        );
        self.set_timeline(self.preview.clone());
        let alive: BTreeSet<Id> = self.timeline.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect();
        self.selection.retain(|i| alive.contains(i));
        let alive_captions: BTreeSet<Id> =
            self.timeline.caption_tracks.iter().flat_map(|t| t.items().iter().map(|i| i.id)).collect();
        self.caption_selection.retain(|i| alive_captions.contains(i));
        Some(commit)
    }

    // MARK: Delete

    /// Delete (lift, leaves a gap) or Shift+Delete (ripple). One commit; selection is cleared.
    pub fn delete_selection(&mut self, ripple: bool) -> Option<TimelineCommit> {
        if !(self.gesture.is_none() && (!self.selection.is_empty() || !self.caption_selection.is_empty())) {
            return None;
        }
        let mut edits: Vec<TimelineEdit> = Vec::new();
        if !self.selection.is_empty() {
            let ids: Vec<Id> = self.selection.iter().copied().collect();
            let base = if ripple { TimelineEdit::RippleDelete(ids) } else { TimelineEdit::Lift(ids) };
            edits = TimelineEdit::scoped(vec![base], Some(&self.selection), &self.timeline);
            if self.timeline.is_fast_cut() {
                edits = TimelineEdit::fast_cut(&edits, &self.timeline, self.tool_state.keep_attached, false);
            }
        }
        // `BTreeSet<Id>` iterates in uuidString order, the order Swift sorts by.
        edits.extend(self.caption_selection.iter().map(|c| TimelineEdit::DeleteCaption(*c)));
        let out = TimelineEdit::apply_all(&edits, &self.timeline, &mut self.ids).ok()?;
        let name = if ripple && !self.selection.is_empty() { "Ripple Delete" } else { "Delete" };
        let commit = TimelineCommit::new(out.clone(), edits, name, BTreeSet::new(), BTreeSet::new());
        self.set_timeline(out.clone());
        self.preview = out;
        self.selection = BTreeSet::new();
        self.caption_selection = BTreeSet::new();
        Some(commit)
    }

    // MARK: Context menu

    /// Right-click: a clip or caption under the pointer that is not selected becomes the selection (its linked
    /// group for clips); a click on a selected item keeps the selection; empty space keeps everything.
    pub fn context_select(&mut self, p: Point, m: GestureModifiers) {
        if self.gesture.is_some() {
            return;
        }
        match self.geometry.hit_test(p, &self.timeline) {
            TimelineHit::Clip(id, _) => {
                self.caption_selection = BTreeSet::new();
                self.clear_edge_and_gap();
                if !self.selection.contains(&id) {
                    let linked = self.linked(m);
                    self.selection = self.selection_group(id, linked);
                }
            }
            TimelineHit::Gap(track, t) => {
                if let Some(r) = self.timeline.gap(track, t) {
                    self.selection = BTreeSet::new();
                    self.caption_selection = BTreeSet::new();
                    self.edge_selection = None;
                    self.gap_selection = Some(GapSelection::new(track, r));
                }
            }
            TimelineHit::Caption(id, _) => {
                self.selection = BTreeSet::new();
                if !self.caption_selection.contains(&id) {
                    self.caption_selection = BTreeSet::from([id]);
                }
            }
            _ => {}
        }
    }

    // MARK: Nest

    /// Premiere "Nest": replaces the selected clips with one nested clip (`Project::nest`). Needs the whole project
    /// because a new sequence is added. An empty or blank name uses "Combined NN". Nothing selected, or a
    /// model error (locked track, collision...), returns `None` and sets `is_rejected` + `rejection_message`.
    /// The commit's `edits` are empty: a nest is not replayable as a timeline edit, undo with `project` snapshots.
    pub fn nest(&mut self, name: &str, project: &Project) -> Option<NestResult> {
        if self.gesture.is_some() {
            return None;
        }
        self.rejection_message = None;
        self.is_rejected = false;
        if self.selection.is_empty() {
            return self.reject("Select clips to combine.");
        }
        let trimmed = name.trim_matches(is_ws);
        let mut p = project.clone();
        let clips: Vec<Id> = self.selection.iter().copied().collect();
        let seq = match p.nest(
            &clips,
            self.timeline.id,
            if trimmed.is_empty() { None } else { Some(trimmed) },
            &mut self.ids,
        ) {
            Ok(s) => s,
            Err(e) => return self.reject(&Self::message_for(&e)),
        };
        let Some(out) = p.timeline(self.timeline.id).cloned() else { return self.reject("Sequence not found.") };
        let new_clips: BTreeSet<Id> = out
            .tracks
            .iter()
            .flat_map(|t| t.clips().iter())
            .filter(|c| c.sequence == Some(seq))
            .map(|c| c.id)
            .collect();
        let commit = TimelineCommit::new(out.clone(), Vec::new(), "Combine", new_clips.clone(), BTreeSet::new());
        self.set_timeline(out.clone());
        self.preview = out;
        self.selection = new_clips;
        self.caption_selection = BTreeSet::new();
        Some(NestResult { project: p, commit, sequence: seq })
    }

    fn reject(&mut self, message: &str) -> Option<NestResult> {
        self.is_rejected = true;
        self.rejection_message = Some(message.to_string());
        None
    }

    pub(crate) fn message_for(error: &EditError) -> String {
        match error {
            EditError::TrackLocked => "A selected clip is on a locked track.",
            EditError::Collision => "Another clip is in the way on the target track.",
            EditError::NestingCycle => EditorSession::NESTING_CYCLE_MESSAGE,
            EditError::ClipNotFound | EditError::TimelineNotFound => "The selected clips no longer exist.",
            EditError::EmptyClip => "Nothing to combine.",
            EditError::WrongTrackKind => "Clips do not fit that track.",
            EditError::InvalidFormat => "That sequence format is not valid.",
            EditError::SpeedUnsupported => "Speed cannot be changed on that clip.",
            EditError::NotACut | EditError::InsufficientMedia => "That transition cannot be applied here.",
            EditError::NotAGroup
            | EditError::NotNested
            | EditError::UngroupLosesLook
            | EditError::NotConvertible
            | EditError::NoTrackToDelete => "Combine failed.",
        }
        .to_string()
    }

    // MARK: Selection tools

    fn select_forward(&mut self, track: Option<Id>, pivot: Time, all_tracks: bool, linked: bool) {
        let mut ids = BTreeSet::new();
        let backward = self.tool_state.select_backward;
        for t in self.timeline.tracks.iter() {
            if !(all_tracks || Some(t.id) == track) {
                continue;
            }
            for c in t.clips() {
                if if backward { c.start < pivot } else { c.timeline().end() > pivot } {
                    ids.insert(c.id);
                }
            }
        }
        self.selection = if linked { self.groups(&ids, true) } else { ids };
    }

    fn update_marquee(&mut self, p: Point, m: GestureModifiers) {
        let Some(g) = self.gesture.clone() else { return };
        let rect = Rect::new(
            g.down_point.x.min(p.x),
            g.down_point.y.min(p.y),
            (p.x - g.down_point.x).abs(),
            (p.y - g.down_point.y).abs(),
        );
        self.marquee = Some(rect);
        self.gap_selection = None;
        let mut hits = BTreeSet::new();
        for row in self.geometry.rows(&self.timeline) {
            let Some(t) = self.timeline.track(row.track).filter(|t| !t.is_locked) else { continue }; // locked clips are not swept up
            for c in t.clips() {
                let (x0, x1) = self.clip_x(c);
                if intersects(&rect, &Rect::new(x0, row.y, (x1 - x0).max(0.001), row.height)) {
                    hits.insert(c.id);
                }
            }
        }
        let swept = if self.linked(m) { self.selection_groups(&hits, true) } else { hits };
        self.selection = g.base_selection.union(&swept).copied().collect();
        // Captions inside the rectangle are picked up too (hidden caption tracks are not drawn, so not swept up).
        let mut caption_hits = BTreeSet::new();
        for row in self.geometry.caption_rows(&self.timeline) {
            let Some(t) = self.timeline.caption_track(row.track).filter(|t| t.is_visible) else { continue };
            for item in t.items() {
                let x0 = self.geometry.x(item.range.start);
                let x1 = self.geometry.x(item.range.end());
                if intersects(&rect, &Rect::new(x0, row.y, (x1 - x0).max(0.001), row.height)) {
                    caption_hits.insert(item.id);
                }
            }
        }
        self.caption_selection = g.base_captions.union(&caption_hits).copied().collect();
    }

    // MARK: Edge helpers

    fn nearest_edge(&self, id: Id, zone: ClipZone, x: f64) -> ClipEdge {
        match zone {
            ClipZone::Head => ClipEdge::Head,
            ClipZone::Tail => ClipEdge::Tail,
            ClipZone::Body => {
                let Some(c) = self.clip(id) else { return ClipEdge::Tail };
                let (x0, x1) = self.clip_x(c);
                if x < (x0 + x1) / 2.0 { ClipEdge::Head } else { ClipEdge::Tail }
            }
        }
    }

    fn publish(&mut self, edits: Vec<TimelineEdit>, name: &str) {
        let (scope, kind) = match &self.gesture {
            Some(g) => (g.scope.clone(), Some(g.kind)),
            None => (None, None),
        };
        let mut edits = TimelineEdit::scoped(edits, scope.as_ref(), &self.timeline);
        // Fast Cut: the gesture runs the Fast Cut verbs, so the preview (and drop ghost) shows where things really land.
        if self.timeline.is_fast_cut() {
            edits = TimelineEdit::fast_cut(
                &edits,
                &self.timeline,
                self.tool_state.keep_attached,
                self.tool_state.timeline_tool() == TimelineTool::Position && kind == Some(GestureKind::Move),
            );
        }
        self.pending_edits = edits.clone();
        self.pending_undo_name = Some(name.to_string());
        self.is_rejected = false;
        self.rejection_message = None;
        if edits.is_empty() {
            self.preview = self.timeline.clone();
            return;
        }
        match TimelineEdit::apply_all(&edits, &self.timeline, &mut self.ids) {
            Ok(t) => self.preview = t,
            Err(e) => {
                self.preview = self.timeline.clone();
                self.pending_edits = Vec::new();
                self.is_rejected = true;
                self.rejection_message = Some(Self::message_for(&e));
            }
        }
    }

    /// Frame-snapped pointer travel since mouse down.
    fn travel(&self, p: Point, g: &Gesture) -> Time {
        self.geometry.time(p.x) - g.down_time
    }

    // MARK: Move

    /// Row the pointer drags `kind` onto, (index, is_new). Above the first row adds a video track, below the last an audio
    /// track. `sticky` (the row chosen last) is kept while the pointer stays within `ROW_HYSTERESIS` of it.
    /// `on_video_ghost`: the pointer is on the "V+" ghost strip under the last track; a video clip dropped there gets a new top track.
    fn drop_row(
        kind: TrackKind,
        y: f64,
        rows: &[TrackRow],
        sticky: Option<usize>,
        on_video_ghost: bool,
    ) -> (i64, bool) {
        if kind == TrackKind::Video && on_video_ghost {
            return (-1, true);
        }
        if let Some(s) = sticky
            && let Some(r) = rows.get(s)
            && r.kind == kind
            && y >= r.y - Self::ROW_HYSTERESIS
            && y < r.max_y() + Self::ROW_HYSTERESIS
        {
            return (s as i64, false);
        }
        if kind == TrackKind::Video
            && let Some(first) = rows.first()
            && y < first.y
        {
            return (-1, true);
        }
        if kind == TrackKind::Audio
            && let Some(last) = rows.last()
            && y >= last.max_y()
        {
            return (rows.len() as i64, true);
        }
        let candidates: Vec<usize> = (0..rows.len()).filter(|&i| rows[i].kind == kind).collect();
        if let Some(hit) = candidates.iter().copied().find(|&i| y >= rows[i].y && y < rows[i].max_y()) {
            return (hit as i64, false);
        }
        let dist = |i: usize| if y < rows[i].y { rows[i].y - y } else { y - rows[i].max_y() };
        // `min(by:)` keeps the first of equal elements.
        let mut near: Option<usize> = None;
        for &i in &candidates {
            if near.is_none_or(|n| dist(i) < dist(n)) {
                near = Some(i);
            }
        }
        if let Some(n) = near {
            return (n as i64, false);
        }
        (if kind == TrackKind::Video { -1 } else { rows.len() as i64 }, true)
    }

    fn update_move(&mut self, p: Point, m: GestureModifiers) {
        let Some(mut g) = self.gesture.clone() else { return };
        let Some(anchor_id) = g.clip else { return };
        let Some(anchor) = self.clip(anchor_id).cloned() else { return };
        // Adobe: Cmd-drag = insert (the old place stays a gap), Cmd+Opt-drag = rearrange (the old place closes), Option-drag
        // = copy; Option first and then Cmd = insert the copy.
        let command = m.contains(GestureModifiers::COMMAND);
        let option = m.contains(GestureModifiers::OPTION);
        if option && !command {
            g.copy_latched = true;
        }
        self.gesture = Some(g.clone());
        let insert = command;
        let copying = option && !insert;
        let insert_copying = option && insert && g.copy_latched;
        let rearranging = option && insert && !g.copy_latched;
        self.move_hint = if insert_copying {
            Some("Insert copy")
        } else if rearranging {
            Some("Rearrange")
        } else if insert {
            Some("Insert")
        } else if copying {
            Some("Copy")
        } else {
            None
        }
        .map(str::to_string);
        self.reorder_ghost = None;
        let movers: Vec<Id> = if !insert && self.selection.contains(&anchor_id) {
            self.selection.iter().copied().collect()
        } else {
            vec![anchor_id]
        };
        let scope = g.scope.clone();
        let mut everything = BTreeSet::new();
        for mv in &movers {
            everything.extend(self.group_within(*mv, &scope));
        }
        let min_start = everything.iter().filter_map(|i| self.clip(*i).map(|c| c.start)).min().unwrap_or(anchor.start);

        // Shift locks the move to the axis the pointer left along first: time or track.
        if m.contains(GestureModifiers::SHIFT) {
            g.axis_lock.update(p.x - g.down_point.x, p.y - g.down_point.y);
        } else {
            g.axis_lock.reset();
        }
        let lock = g.axis_lock.axis();
        let mut d = if lock == Some(LockAxis::Vertical) { Time::ZERO } else { self.travel(p, &g) };
        self.snap_time = None;
        if self.snapping_on() && lock != Some(LockAxis::Vertical) {
            let pts = self.snap_points(&everything);
            let r = snap_move(
                anchor.start + d,
                anchor.timeline().duration,
                &pts,
                self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
                Some(self.geometry.frame_duration),
            );
            d += r.0;
            self.snap_time = r.1.map(|h| h.time);
        }
        d = d.max(Time::ZERO - min_start);

        let rows = self.geometry.rows(&self.timeline);
        let anchor_row = rows.iter().position(|r| Some(r.track) == self.track_id_of(anchor_id)).unwrap_or(0);
        if g.sticky_row.is_none() {
            g.sticky_row = Some(anchor_row);
        }
        let drop_y = if lock == Some(LockAxis::Horizontal) && anchor_row < rows.len() {
            rows[anchor_row].y + rows[anchor_row].height / 2.0
        } else {
            p.y
        };
        let on_video_ghost =
            lock != Some(LockAxis::Horizontal) && self.geometry.ghost_kind(p, &self.timeline) == Some(TrackKind::Video);
        let drop = Self::drop_row(anchor.kind, drop_y, &rows, g.sticky_row, on_video_ghost);
        if !drop.1 {
            g.sticky_row = Some(drop.0 as usize);
        }
        self.gesture = Some(g.clone());
        if self.timeline.is_fast_cut() && !copying && !insert_copying {
            // Fast Cut cursor hint: what the drop will do (TimelineEdit.fastCut).
            let drop_track = if !drop.1 && drop.0 >= 0 { rows.get(drop.0 as usize).map(|r| r.track) } else { None };
            let main = self.timeline.main_track_id();
            let on_main = drop_track.is_some() && drop_track == main;
            let keep = if self.tool_state.keep_attached { " (attached stay)" } else { "" };
            if self.timeline.main_clip_of(anchor_id).is_some() {
                let base = if on_main || anchor.kind == TrackKind::Audio { "Rearrange" } else { "Lift off main track" };
                self.move_hint = Some(format!("{base}{keep}"));
                if on_main
                    && !insert
                    && d != Time::ZERO
                    && let Some(main) = main
                {
                    self.reorder_ghost = Some(ReorderGhost {
                        track: main,
                        range: TimeRange::new(anchor.start + d, anchor.timeline().duration),
                        name: anchor.name.clone(),
                    });
                }
            } else {
                self.move_hint = if on_main { Some("Insert on main track".to_string()) } else { None };
            }
            if self.tool_state.timeline_tool() == TimelineTool::Position && !insert {
                // Position tool: overwrites and leaves a hole
                self.move_hint = Some("Position".to_string());
                self.reorder_ghost = None;
            }
        }

        if insert {
            let mut edits: Vec<TimelineEdit> = Vec::new();
            let mut anchor_track: Option<Id> = None;
            if drop.1 {
                let t = match g.new_track.clone() {
                    Some(t) => t,
                    None => Track::new(self.ids.next_id(), anchor.kind),
                };
                g.new_track = Some(t.clone());
                self.gesture = Some(g.clone());
                anchor_track = Some(t.id);
                edits.push(TimelineEdit::AddTrack(t));
            } else if drop.0 != anchor_row as i64 {
                anchor_track = Some(rows[drop.0 as usize].track);
            }
            if insert_copying {
                // Cmd+Option: insert a copy at the drop point, the original stays.
                let grp = self.group_within(anchor_id, &scope);
                for member in &grp {
                    if !g.copy_ids.contains_key(member) {
                        let id = self.ids.next_id();
                        g.copy_ids.insert(*member, id);
                    }
                }
                let mut link = self.ids.next_id();
                if let Some(l) = anchor.link {
                    link = g.copy_links.get(&l).copied().unwrap_or(link);
                    g.copy_links.insert(l, link);
                }
                let copies: std::collections::BTreeMap<Id, Id> =
                    g.copy_ids.iter().filter(|(k, _)| grp.contains(k)).map(|(k, v)| (*k, *v)).collect();
                self.pending_copies = copies.values().copied().collect();
                let spec = CopySpec { ids: copies, link };
                self.gesture = Some(g);
                edits.push(TimelineEdit::InsertCopy {
                    clip: anchor_id,
                    to: anchor.start + d,
                    track: anchor_track,
                    spec,
                });
                self.publish(edits, "Insert Copy");
                return;
            }
            self.pending_copies = BTreeSet::new();
            if d != Time::ZERO || anchor_track.is_some() {
                edits.push(if rearranging {
                    TimelineEdit::MoveInsert { clip: anchor_id, to: anchor.start + d, track: anchor_track }
                } else {
                    TimelineEdit::InsertMove { clip: anchor_id, to: anchor.start + d, track: anchor_track }
                });
            } else {
                edits = Vec::new();
            }
            self.publish(edits, if rearranging { "Rearrange" } else { "Insert Move" });
            return;
        }

        // Track lanes per kind, bottom-up (index 0 = V1 / A1). A track change of k lanes applies to every moved clip of
        // either kind: video up k = audio down k, because both indices grow away from the center (Premiere mirrors).
        let mut lists: HashMap<TrackKind, Vec<Id>> =
            HashMap::from([(TrackKind::Video, vec![]), (TrackKind::Audio, vec![])]);
        for t in self.timeline.tracks.iter() {
            lists.entry(t.kind).or_default().push(t.id);
        }
        let lane_of = |id: Id| -> Option<(TrackKind, usize)> {
            let tid = self.index.track_id(id)?;
            let t = self.timeline.track(tid)?;
            let i = lists.get(&t.kind)?.iter().position(|x| *x == tid)?;
            Some((t.kind, i))
        };
        let Some(anchor_lane) = lane_of(anchor_id) else { return };
        let target_lane = if drop.1 {
            lists.get(&anchor.kind).map_or(0, |l| l.len())
        } else {
            let want = rows[drop.0 as usize].track;
            lists.get(&anchor.kind).and_then(|l| l.iter().position(|x| *x == want)).unwrap_or(anchor_lane.1)
        };
        let k = target_lane as i64 - anchor_lane.1 as i64;

        let mut used_new: HashMap<TrackKind, usize> = HashMap::new();
        let mut new_tracks = std::mem::take(&mut g.new_tracks);
        let mut dest_track = |kind: TrackKind, index: usize, ids: &mut dyn IdSource| -> Id {
            let existing: &[Id] = lists.get(&kind).map_or(&[], |l| l.as_slice());
            if index < existing.len() {
                return existing[index];
            }
            let fresh = new_tracks.entry(kind).or_default();
            while existing.len() + fresh.len() <= index {
                fresh.push(Track::new(ids.next_id(), kind));
            }
            let base = index - existing.len();
            let top = used_new.get(&kind).map_or(base, |c| (*c).max(base));
            used_new.insert(kind, top);
            fresh[base].id
        };
        let dest_of = |id: Id,
                       dest_track: &mut dyn FnMut(TrackKind, usize, &mut dyn IdSource) -> Id,
                       ids: &mut dyn IdSource|
         -> Option<Id> {
            let l = lane_of(id)?;
            let target = if id == anchor_id { target_lane } else { (l.1 as i64 + k).max(0) as usize };
            let t = dest_track(l.0, target, ids);
            if Some(t) == self.index.track_id(id) { None } else { Some(t) }
        };

        let mut ordered: Vec<Clip> = movers.iter().filter_map(|i| self.clip(*i).cloned()).collect();
        ordered.sort_by(|a, b| {
            // Swift's `sorted(by:)` takes a strict "before" predicate; both directions are needed for a total order.
            let before = |a: &Clip, b: &Clip| -> bool {
                let la = lane_of(a.id).map_or(0, |l| l.1);
                let lb = lane_of(b.id).map_or(0, |l| l.1);
                if k != 0 && la != lb {
                    return if k > 0 { la > lb } else { la < lb };
                }
                if d < Time::ZERO { a.start < b.start } else { a.start > b.start }
            };
            if before(a, b) {
                std::cmp::Ordering::Less
            } else if before(b, a) {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        });
        let mut done: BTreeSet<Id> = BTreeSet::new();
        let mut moves: Vec<TimelineEdit> = Vec::new();
        let mut group_count = 0;
        for c in &ordered {
            if done.contains(&c.id) {
                continue;
            }
            let grp = self.group_within(c.id, &scope);
            done.extend(grp.iter().copied());
            group_count += 1;
            let own = dest_of(c.id, &mut dest_track, &mut self.ids);
            let mut partners: std::collections::BTreeMap<Id, Id> = Default::default();
            for other in &grp {
                if *other != c.id
                    && let Some(t) = dest_of(*other, &mut dest_track, &mut self.ids)
                {
                    partners.insert(*other, t);
                }
            }
            if !(d != Time::ZERO || own.is_some() || !partners.is_empty()) {
                continue;
            }
            if copying {
                // Option-drag: originals stay, copies land at the drop position (Premiere).
                for member in &grp {
                    if !g.copy_ids.contains_key(member) {
                        let fresh = self.ids.next_id();
                        g.copy_ids.insert(*member, fresh);
                    }
                }
                let mut link = self.ids.next_id();
                if let Some(l) = c.link {
                    link = g.copy_links.get(&l).copied().unwrap_or(link);
                    g.copy_links.insert(l, link);
                }
                let copies = g.copy_ids.iter().filter(|(k, _)| grp.contains(k)).map(|(k, v)| (*k, *v)).collect();
                moves.push(TimelineEdit::CopyGroup {
                    clip: c.id,
                    to: c.start + d,
                    track: own,
                    partners,
                    spec: CopySpec { ids: copies, link },
                });
                continue;
            }
            moves.push(if partners.is_empty() {
                TimelineEdit::Move { clip: c.id, to: c.start + d, track: own }
            } else {
                TimelineEdit::MoveGroup { clip: c.id, to: c.start + d, track: own, partners }
            });
        }
        g.new_tracks = new_tracks;
        self.gesture = Some(g.clone());
        self.pending_copies =
            if copying && !moves.is_empty() { g.copy_ids.values().copied().collect() } else { BTreeSet::new() };
        let mut edits: Vec<TimelineEdit> = Vec::new();
        for kind in [TrackKind::Video, TrackKind::Audio] {
            if let Some(top) = used_new.get(&kind) {
                edits.extend(
                    g.new_tracks
                        .get(&kind)
                        .map(|v| v.as_slice())
                        .unwrap_or(&[])
                        .iter()
                        .take(top + 1)
                        .cloned()
                        .map(TimelineEdit::AddTrack),
                );
            }
        }
        let name = if copying {
            if group_count > 1 { "Copy Clips" } else { "Copy Clip" }
        } else if group_count > 1 {
            "Move Clips"
        } else {
            "Move Clip"
        };
        if moves.is_empty() {
            self.publish(Vec::new(), name);
        } else {
            edits.extend(moves);
            self.publish(edits, name);
        }
    }

    // MARK: Captions

    fn update_caption_move(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.caption else { return };
        let Some(item) = self.caption_item(id).cloned() else { return };
        let mut d = self.travel(p, &g);
        self.snap_time = None;
        if self.snapping_on() {
            let pts = self.snap_points(&BTreeSet::new());
            let r = snap_move(
                item.range.start + d,
                item.range.duration,
                &pts,
                self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
                Some(self.geometry.frame_duration),
            );
            d += r.0;
            self.snap_time = r.1.map(|h| h.time);
        }
        let edits = if d == Time::ZERO {
            Vec::new()
        } else {
            vec![TimelineEdit::MoveCaption { caption: id, to: (item.range.start + d).max(Time::ZERO) }]
        };
        self.publish(edits, "Move Caption");
    }

    fn update_caption_trim(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.caption else { return };
        let Some(item) = self.caption_item(id).cloned() else { return };
        let edge_time = if g.edge == ClipEdge::Head { item.range.start } else { item.range.end() };
        let d = self.snapped_delta(self.travel(p, &g), edge_time, &BTreeSet::new());
        let edits = if d == Time::ZERO {
            Vec::new()
        } else {
            vec![TimelineEdit::TrimCaption { caption: id, edge: g.edge, to: edge_time + d }]
        };
        self.publish(edits, "Trim Caption");
    }

    /// A word edge follows the pointer, snapping like a clip edge. It stops at the neighboring word and at the caption's
    /// own edges (one frame stays); two words that touch there move their shared edge together unless Option is held.
    fn update_word_retime(&mut self, p: Point, alone: bool) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.caption else { return };
        let Some(item) = self.caption_item(id).cloned() else { return };
        let words = item.effective_words();
        let Some(word) = words.get(g.word) else { return };
        let edge_time = if g.edge == ClipEdge::Head { word.range.start } else { word.range.end() };
        let d = self.snapped_delta(self.travel(p, &g), edge_time, &BTreeSet::new());
        let edits = if d == Time::ZERO {
            Vec::new()
        } else {
            vec![TimelineEdit::RetimeCaptionWord {
                caption: id,
                index: g.word,
                edge: g.edge,
                to: edge_time + d,
                rolling: !alone,
            }]
        };
        self.publish(edits, "Retime Word");
    }

    // MARK: Trim / ripple / roll / slip / slide

    fn update_trim(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.clip else { return };
        let Some(c) = self.clip(id).cloned() else { return };
        let edge_time = if g.edge == ClipEdge::Head { c.start } else { c.timeline().end() };
        let excluding = self.group(id, true);
        let d = self.snapped_delta(self.travel(p, &g), edge_time, &excluding);
        let ripple = g.kind == GestureKind::RippleTrim;
        let edit = if ripple {
            TimelineEdit::RippleTrim { clip: id, edge: g.edge, by: d }
        } else {
            TimelineEdit::Trim { clip: id, edge: g.edge, by: d }
        };
        let name = if ripple { "Ripple Trim" } else { "Trim Clip" };
        // Several selected edges move together, like the keyboard trims.
        if let Some(sel) = self.edge_selection.clone()
            && sel.edges.len() > 1
        {
            let edits = EdgeEdits::trim(&sel, d, &self.timeline);
            self.publish(edits, name);
            return;
        }
        self.publish(if d == Time::ZERO { Vec::new() } else { vec![edit] }, name);
    }

    /// Rate Stretch: the dragged edge snaps like a trim; the clip's speed follows the new length.
    fn update_rate_stretch(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.clip else { return };
        let Some(c) = self.clip(id).cloned() else { return };
        let edge_time = if g.edge == ClipEdge::Head { c.start } else { c.timeline().end() };
        let excluding = self.group(id, true);
        let d = self.snapped_delta(self.travel(p, &g), edge_time, &excluding);
        let edits = if d == Time::ZERO {
            Vec::new()
        } else {
            vec![TimelineEdit::RateStretch { clip: id, edge: g.edge, by: d }]
        };
        self.publish(edits, "Stretch");
    }

    fn update_roll(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.clip else { return };
        let Some(c) = self.clip(id).cloned() else { return };
        let Some(track) = self.track_id_of(id).and_then(|t| self.timeline.track(t)).cloned() else { return };
        let left: Option<Clip> = if g.edge == ClipEdge::Tail {
            Some(c.clone())
        } else {
            track.clips().iter().find(|k| k.timeline().end() == c.start).cloned()
        };
        let Some(left) = left else {
            self.publish(Vec::new(), "Move Edit");
            return;
        };
        // A roll edits both clips of the cut: the other one joins the scope the same way the clicked clip is in it
        // (alone, or with its partners), so an unlinked roll leaves the partner cut where it is.
        if let Some(mut scope) = g.scope.clone() {
            let right = track.clips().iter().find(|k| k.start == left.timeline().end()).map(|k| k.id);
            let with_partners = self.group(id, true).is_subset(&scope);
            for other in [Some(left.id), right].into_iter().flatten() {
                if !scope.contains(&other) {
                    if with_partners {
                        scope.extend(self.group(other, true));
                    } else {
                        scope.insert(other);
                    }
                }
            }
            if let Some(gg) = self.gesture.as_mut() {
                gg.scope = Some(scope);
            }
        }
        let excluding = self.group(left.id, true);
        let d = self.snapped_delta(self.travel(p, &g), left.timeline().end(), &excluding);
        if let Some(sel) = self.edge_selection.clone()
            && sel.edges.len() > 2
        {
            let edits = EdgeEdits::trim(&sel, d, &self.timeline);
            self.publish(edits, "Move Edit");
            return;
        }
        let edits = if d == Time::ZERO { Vec::new() } else { vec![TimelineEdit::Roll { clip: left.id, by: d }] };
        self.publish(edits, "Move Edit");
    }

    /// Opt-drag on a cut: the audio edit follows the pointer (snapped, clamped by handles), the picture stays.
    fn update_split_roll(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let d = self.snapped_delta(self.travel(p, &g), g.cut, &BTreeSet::new());
        if d == Time::ZERO {
            self.split_roll_ghost = Some(SplitRollGhost { cut: g.cut, offset: Time::ZERO });
            self.publish(Vec::new(), "Split Edit Audio");
            return;
        }
        let mut probe = self.timeline.clone();
        let applied = probe.split_edit(g.cut, SplitEditSide::Audio, g.cut + d, None).unwrap_or(Time::ZERO);
        self.split_roll_ghost = Some(SplitRollGhost { cut: g.cut, offset: applied });
        self.publish(vec![TimelineEdit::SplitEditAudio { cut: g.cut, to: g.cut + d }], "Split Edit Audio");
    }

    fn update_slip(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.clip else { return };
        // The media follows the pointer: dragging right shows earlier material.
        let d = Time::ZERO - self.travel(p, &g);
        let stay = self.tool_state.slip_keyframes_stay;
        self.move_hint = if d == Time::ZERO {
            None
        } else {
            Some(format!(
                "Slip {}{}",
                Self::frame_text(d, self.geometry.frame_duration),
                if stay { " (keyframes stay)" } else { "" }
            ))
        };
        let edits = if d == Time::ZERO {
            Vec::new()
        } else {
            vec![TimelineEdit::Slip {
                clip: id,
                by: d,
                keyframes: if stay { SlipKeyframes::Stay } else { SlipKeyframes::FollowContent },
            }]
        };
        self.publish(edits, if stay { "Slip Clip (Keyframes Stay)" } else { "Slip Clip" });
    }

    fn update_slide(&mut self, p: Point) {
        let Some(g) = self.gesture.clone() else { return };
        let Some(id) = g.clip else { return };
        let Some(c) = self.clip(id).cloned() else { return };
        let mut d = self.travel(p, &g);
        self.snap_time = None;
        if self.snapping_on() {
            let excluding = self.group(id, true);
            let pts = self.snap_points(&excluding);
            let r = snap_move(
                c.start + d,
                c.timeline().duration,
                &pts,
                self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
                Some(self.geometry.frame_duration),
            );
            d += r.0;
            self.snap_time = r.1.map(|h| h.time);
        }
        self.move_hint = if d == Time::ZERO {
            None
        } else {
            Some(format!("Slide {}", Self::frame_text(d, self.geometry.frame_duration)))
        };
        let edits = if d == Time::ZERO { Vec::new() } else { vec![TimelineEdit::Slide { clip: id, by: d }] };
        self.publish(edits, "Slide Clip");
    }

    /// Signed whole frames for the drag readout of Slip and Slide: "+12 f", "-3 f".
    pub(crate) fn frame_text(d: Time, frame: Time) -> String {
        let n = (d.value() as f64 * frame.timescale() as f64 / (d.timescale() as f64 * frame.value() as f64)).round()
            as i64;
        format!("{}{n} f", if n > 0 { "+" } else { "" })
    }

    /// `delta` of an edge at `edge_time`, pulled onto a snap point when snapping is on.
    fn snapped_delta(&mut self, delta: Time, edge_time: Time, excluding: &BTreeSet<Id>) -> Time {
        self.snap_time = None;
        if !self.snapping_on() {
            return delta;
        }
        let pts = self.snap_points(excluding);
        let r = snap(
            edge_time + delta,
            &pts,
            self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
            Some(self.geometry.frame_duration),
        );
        self.snap_time = r.1.map(|h| h.time);
        r.0 - edge_time
    }

    // MARK: Razor

    /// Where a razor click at view x would cut (frame-snapped, edge-snapped when snapping is on). The hover guide
    /// draws its line here, so the line is exactly the cut.
    pub fn razor_cut_time(&self, x: f64) -> Time {
        let t = self.geometry.time(x);
        if !self.snapping_on() {
            return t;
        }
        let pts = self.cached_snap_points(&BTreeSet::new()).unwrap_or_else(|| {
            Arc::new(self.timeline.snap_points(&BTreeSet::new(), self.playhead, &self.markers, true))
        });
        snap(
            t,
            &pts,
            self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
            Some(self.geometry.frame_duration),
        )
        .0
    }

    /// Delete / Shift+Delete has something to act on: clips, captions or a selected gap (which it ripple-closes).
    pub fn has_delete_target(&self) -> bool {
        !self.selection.is_empty() || !self.caption_selection.is_empty() || self.gap_selection.is_some()
    }

    /// Tracks a razor click on `id` cuts: its own track first, then its linked partners' tracks.
    fn razor_tracks(&self, id: Id, linked: bool) -> Option<Vec<Id>> {
        let own = self.track_id_of(id)?;
        let mut set: BTreeSet<Id> = self.group(id, linked).iter().filter_map(|c| self.track_id_of(*c)).collect();
        set.insert(own);
        let mut out = vec![own];
        out.extend(self.timeline.tracks.iter().map(|t| t.id).filter(|t| set.contains(t) && *t != own));
        Some(out)
    }

    /// Tracks the razor hover guide spans at view point `p`: with Shift every track, otherwise only the tracks of the
    /// clip under the pointer (and its linked partners). Empty over an empty lane, so no line is drawn there.
    pub fn razor_guide_tracks(&self, p: Point, shift: bool, option: bool) -> Vec<Id> {
        if shift {
            return self.timeline.tracks.iter().map(|t| t.id).collect();
        }
        let TimelineHit::Clip(id, _) = self.geometry.hit_test(p, &self.timeline) else { return Vec::new() };
        self.razor_tracks(id, self.tool_state.linked_selection != option).unwrap_or_default()
    }

    fn razor_preview(&mut self, p: Point, id: Option<Id>, m: GestureModifiers) {
        let mut t = self.geometry.time(p.x);
        self.snap_time = None;
        if self.snapping_on() {
            let pts = self.snap_points(&BTreeSet::new());
            let r = snap(
                t,
                &pts,
                self.geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
                Some(self.geometry.frame_duration),
            );
            t = r.0;
            self.snap_time = r.1.map(|h| h.time);
        }
        let shift = m.contains(GestureModifiers::SHIFT);
        let mut tracks: Option<Vec<Id>> = None;
        if !shift && let Some(id) = id {
            tracks = self.razor_tracks(id, self.linked(m));
        }
        self.publish(vec![TimelineEdit::AddEdit { at: t, tracks }], if shift { "Blade All Tracks" } else { "Blade" });
    }
}

#[cfg(test)]
mod edge_gap_tests;
#[cfg(test)]
mod mirrored_move_tests;
#[cfg(test)]
mod snap_point_cache_tests;
#[cfg(test)]
mod split_roll_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod unlinked_selection_tests;
