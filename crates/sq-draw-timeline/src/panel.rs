// Swift: TimelinePanel.swift
//! The Timeline panel on the shared draw-list toolkit: the Mac `TimelineView` translated, not rebuilt. Models, layout
//! math, hit-testing and every tool gesture are `sq-timeline-ui`'s own; only the AppKit glue changes: drawing goes
//! through `Canvas`, events read `InputEvent`, callbacks become [`TimelineAction`]s.
//!
//! Coordinates: points inside the panel, origin top-left, y down; the ruler is the top row and the track header column
//! the left 156 pt, exactly like the Mac view's bounds, so every `sq-timeline-ui` formula applies unchanged.

use crate::band_gestures::BandDrag;
use crate::bands::LayerDrag;
use crate::caption_words::CaptionWordField;
use crate::captions::CaptionSearchControl;
use crate::item_lanes::ItemLaneState;
use crate::lane_cache::LaneCache;
use crate::lanes::TimelineKeyLaneSource;
use crate::media::TimelineMediaSource;
use crate::speed_band::SpeedBandDrag;
use crate::wheel::TimelineWheelState;
use sq_core_edit::timeline_beat_snap::BeatSnapLevel;
use sq_core_effects::transition::ResolvedTransition;
use sq_core_model::{Clip, LabelResolver, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{DrawTheme, InputModifiers, Rect, ZoomScrollBarControl};
use sq_editor_session::{ToolHold, ToolState};
use sq_library::library_folder_store::SettingsStore;
use sq_timeline_ui::{
    ClipMarkerHit, DropPreview, DuckCurveSource, InOutPart, KeystoneBar, KeystoneEdgeDrag, ThumbnailMode,
    TimelineFollow, TimelineGeometry, TimelineInteraction, TimelineZoom, TrackHeightStore, TrackRow,
    TransitionDropTarget, TransitionHit, TransitionLayerDropTarget, ZoomAnimation, ZoomFitToggle,
    ZoomMode as ZoomAnimationMode,
};
use sq_uikit::controls_grid::{CGPoint, CGSize};
use sq_uikit::design_tokens::sq_tokens::spacing;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

/// One gesture in flight; the Mac view keeps one optional per kind, only ever one of them set.
#[derive(Clone)]
pub(crate) enum Gesture {
    Resize {
        zone: sq_timeline_ui::TrackSizingZone,
        start_y: f64,
        rows: Vec<TrackRow>,
        start_fraction: f64,
    },
    Zoom {
        start: CGPoint,
        current: CGPoint,
        zoom_out: bool,
    },
    InOut {
        part: InOutPart,
        down_x: f64,
        down_time: Time,
        moved: bool,
        original: TimeRange,
    },
    MarkerDuration {
        id: Id,
        start: Time,
        original: Time,
        moved: bool,
    },
    Marker {
        id: Id,
        down_x: f64,
        moved: bool,
        original: Time,
    },
    Scrub,
    Transition {
        hit: TransitionHit,
        original: Box<ResolvedTransition>,
        start_x: f64,
        began: bool,
        last_frames: i64,
    },
    /// A press on a header button (the Swift `.header(id, toggle)` payload is never read).
    Header,
    Clips,
    ZoomBar(ZoomBarSnapshot),
    ClipMarker {
        hit: ClipMarkerHit,
        down_x: f64,
        moved: bool,
    },
    /// A volume or opacity rubber band, or a fade handle.
    Band(Box<BandDrag>),
    /// The Time Remapping speed band.
    Speed(Box<SpeedBandDrag>),
    /// Fast Cut: the attach thread of `clip`; `original` is the sequence at the press, `time` the attach point now.
    Attach {
        clip: Id,
        original: Box<Timeline>,
        time: Time,
    },
    /// The edge of the keystone bar.
    Keystone(Box<KeystoneEdgeDrag>),
    /// A transition layer's cut marker or end.
    TransitionLayer(LayerDrag),
    /// A press on a source patch chip; `dragging` once it moved 3 pt.
    Patch {
        kind: TrackKind,
        down: CGPoint,
        dragging: bool,
    },
    /// A press in the item lanes (bar move or trim, lane name drag; the details are in `item_lanes`).
    ItemLane,
}

/// Ids for what the panel's own edits create (copied layers, new keys, split captions): `seed + 1`, `seed + 2`, ... The
/// seed holds the panel's random salt, so ids never repeat across sessions or panel instances (a reopened project
/// already holds the ids of the last session).
pub(crate) struct PanelIds(u128);

impl IdSource for PanelIds {
    fn next_id(&mut self) -> Id {
        self.0 = self.0.wrapping_add(1);
        Id::from_u128(self.0)
    }
}

/// A random 128-bit salt for one panel instance.
fn random_salt() -> u128 {
    sq_core_time::RandomIds.next_id().as_u128()
}

/// The view state at a zoom bar press (`zoomBarDrag`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct ZoomBarSnapshot {
    pub scroll_x: f64,
    pub viewport: f64,
    pub scale: f64,
    pub extent: f64,
}

/// The running ease of a key, zoom-tool click or backslash zoom (start = panel clock).
pub(crate) struct RunningZoom {
    pub anim: ZoomAnimation,
    pub start: f64,
}

/// What the panel takes from the session each frame.
pub struct SessionView<'a> {
    /// The active sequence.
    pub timeline: &'a Timeline,
    /// Selected clips.
    pub selection: &'a BTreeSet<Id>,
    /// Selected caption items.
    pub captions: &'a BTreeSet<Id>,
    /// The playhead.
    pub playhead: Time,
    /// The selected transition.
    pub selected_transition: Option<Id>,
    /// Label colors of clips.
    pub labels: LabelResolver,
    /// Volume / opacity keys picked on the clip bands.
    pub line_keys: BTreeSet<Id>,
}

/// Weak tracking stretches of a clip's Magic mask (`None` = the clip has no track).
pub type WeakSpansOf = Box<dyn Fn(&Clip) -> Option<Vec<sq_core_masks::HealthSpan>>>;

/// The Timeline panel.
pub struct TimelinePanel {
    /// Design tokens.
    pub theme: DrawTheme,
    /// What is drawn: the committed timeline, or the gesture's preview while a drag runs.
    pub(crate) timeline: Timeline,
    /// Per-clip sync badges and per-track prefix-max clip ends, rebuilt when `timeline` changes.
    pub(crate) sync_badges: BTreeMap<Id, i64>,
    pub(crate) prefix_ends: BTreeMap<Id, Vec<Time>>,
    /// Bumped with every `timeline` change: the layer cache's stamp for the model.
    pub(crate) content_revision: u64,
    /// Tracks that hold a transition layer clip.
    pub(crate) transition_layer_tracks: BTreeSet<Id>,
    /// The cached clip layer.
    pub(crate) lane_cache: LaneCache,
    /// The session's timeline as last synced.
    pub(crate) committed: Timeline,
    /// Zoom, scroll and row heights.
    pub geometry: TimelineGeometry,
    pub(crate) interaction: TimelineInteraction,
    pub(crate) selection: BTreeSet<Id>,
    pub(crate) caption_selection: BTreeSet<Id>,
    pub(crate) playhead: Time,
    pub(crate) selected_transition: Option<Id>,
    /// Clip and marker label colors.
    pub labels: LabelResolver,
    /// Cached-render spans for the ruler's cache strip (the host fills it when it has a render cache).
    pub cached_ranges: Vec<TimeRange>,
    /// Beat grid level the snaps use.
    pub beat_level: BeatSnapLevel,
    /// Device-pixel frame in the window.
    pub(crate) frame: Rect,
    /// Device pixels per point.
    pub(crate) scale: f32,
    /// Panel size in points.
    pub(crate) size: CGSize,
    /// Seconds clock for double-click detection and autoscroll (injectable for tests).
    pub clock: Box<dyn Fn() -> f64>,
    /// Hold-to-temp tool: a tool key held past the threshold returns to the tool from before when it comes up.
    pub(crate) tool_hold: ToolHold,
    pub(crate) fitted: bool,
    /// Whether the tracks were scrolled to the video/audio boundary once for the shown timeline.
    pub(crate) scrolled_to_base: bool,
    pub(crate) zoom_animation: Option<RunningZoom>,
    pub(crate) fit_toggle: ZoomFitToggle,
    /// Whether the last key press was the panel's own (it may still have produced no action, like a zoom key).
    pub(crate) key_handled: bool,
    pub(crate) gesture: Option<Gesture>,
    /// Modifiers held at mouse down (the host reports none on drag / up events).
    pub(crate) down_modifiers: InputModifiers,
    /// The pointer shape at the press: a gesture keeps it until the release.
    pub(crate) press_cursor: Option<DrawCursor>,
    /// The ` hold (keep attached) took part in an edit: its release does not maximize the panel.
    pub(crate) keep_attached_used: bool,
    /// The keys held right now (the host's live key state); `None` = the keys held at the press.
    pub live_modifiers: Option<Box<dyn Fn() -> InputModifiers>>,
    pub(crate) last_drag: Option<CGPoint>,
    pub(crate) last_autoscroll: Option<f64>,
    pub(crate) last_click: Option<(f64, CGPoint, i64)>,
    pub(crate) scrub_snap_time: Option<Time>,
    /// Track row under the pointer (reveals Lock and Sync Lock like the Mac header's hover).
    pub(crate) hover_track: Option<Id>,
    pub(crate) hover_point: Option<CGPoint>,
    /// A Slip drag's two-up is showing in the Program monitor.
    pub(crate) slip_two_up_shown: bool,
    /// The running media drag over the panel (host driven).
    pub(crate) drop_preview: DropPreview,
    /// What an effect, preset or transition drag from the Effects panel would land on.
    pub(crate) effect_drop_target: Option<Id>,
    pub(crate) transition_drop_target: Option<TransitionDropTarget>,
    pub(crate) transition_layer_drop_target: Option<TransitionLayerDropTarget>,
    /// The gesture hint last reported, so a hint goes to the status line once.
    pub(crate) last_hint: Option<String>,
    /// The zoom scroll bar under the tracks.
    pub(crate) zoom_bar: ZoomScrollBarControl,
    /// Waveforms, thumbnails and the offline state of the media behind the clips.
    pub media: Option<std::rc::Rc<dyn TimelineMediaSource>>,
    /// What video clip thumbnails show.
    pub thumbnail_mode: ThumbnailMode,
    /// Remove Silences preview: the ranges the open dialog would cut, shaded red.
    pub silence_preview: Vec<TimeRange>,
    /// Volume / opacity keys selected on the clip bands.
    pub(crate) selected_line_keys: BTreeSet<Id>,
    /// Clips that show the speed band instead of the opacity line.
    pub speed_band_clips: BTreeSet<Id>,
    /// The transport runs: the skimmer hides. The host keeps it current.
    pub is_playing: bool,
    /// Weak tracking stretches of a clip's Magic mask; `None` = none.
    pub track_weak_spans: Option<WeakSpansOf>,
    /// Playback follow: whether the user's scroll beats the follow.
    pub(crate) follow: TimelineFollow,
    /// Trackpad and wheel state.
    pub(crate) wheel: TimelineWheelState,
    pub(crate) follow_was_playing: bool,
    /// Color page: the clips the Color panel grades get a yellow outline.
    pub grade_outline: BTreeSet<Id>,
    /// Background analysis share done per clip (Stabilizer), drawn as a strip along the clip's bottom.
    pub analysis_progress: BTreeMap<Id, f64>,
    /// Where the user's track heights and split are kept per sequence (`None` = not kept, e.g. in tests).
    pub height_store: Option<Rc<RefCell<dyn SettingsStore>>>,
    /// The Fast Cut skimmer's frame (`None`: hidden).
    pub(crate) skimmer_time: Option<Time>,
    /// A band drag sent a change whose undo step is still open (the Mac host's `TimelineLineGesture.emitted`).
    pub(crate) line_step_open: bool,
    /// The key lanes of Effect Controls' selected section (`None` = no lane).
    pub key_lanes: Option<Rc<dyn TimelineKeyLaneSource>>,
    /// The live duck curve on Music tracks (N8b); `None` = not drawn.
    pub duck_curve: Option<DuckCurveSource>,
    /// Source patching: the streams of the clip in the Source view (`None`: none loaded, no patch column), set by the host.
    pub source_patch_streams: Option<Vec<TrackKind>>,
    /// The header row a dragged patch chip is over.
    pub(crate) patch_drop_track: Option<Id>,
    /// The bar of the keystone applied last, and its clip as the bar left it: any other change to that clip hides the bar.
    pub keystone_bar: Option<KeystoneBar>,
    pub(crate) keystone_bar_clip: Option<Clip>,
    /// Where a dragged keystone would land (`keystoneHover`).
    pub keystone_ghost: Option<KeystoneBar>,
    /// Open item lanes, their selection and drags.
    pub(crate) item_lanes: ItemLaneState,
    /// The inline word field on the caption track.
    pub(crate) word_field: Option<CaptionWordField>,
    /// A press inside the open word field (x in panel points, click count), turned into a caret once a frame can measure
    /// the text.
    pub(crate) word_field_press_at: Option<(f64, i64)>,
    /// The button is down inside the open word field: (press x, pointer x, moved since the last frame). The next frame
    /// turns it into a selection from the press to the pointer (`draw_word_field`).
    pub(crate) word_field_drag: Option<(f64, f64, bool)>,
    /// Steady-clock seconds of the last event or frame (the host sets it): the open field's caret blinks with it.
    pub ui_now: f64,
    /// The caption find and replace card (`None` = closed).
    pub caption_search: Option<CaptionSearchControl>,
    /// Counts the id sources handed out by `fresh_ids`.
    pub(crate) id_serial: u128,
    /// Random per panel instance: mixed into every id seed so a reopened project (revision and serial back at 0) never
    /// mints the ids an earlier session saved. Tests set a fixed one with `with_id_salt`.
    pub(crate) id_salt: u128,
}

/// Seconds since the first call (the Swift default clock is `systemUptime`).
fn uptime() -> f64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

impl TimelinePanel {
    /// The selected edges with their ripple and link flags (`interaction.edgeSelection`).
    pub fn edge_selection(&self) -> Option<sq_editor_session::EdgeSelection> {
        self.interaction.edge_selection().cloned()
    }

    /// Selects edit points (a click on a clip head or tail, or the selection tests of the app).
    pub fn set_edge_selection(&mut self, e: Option<sq_editor_session::EdgeSelection>) {
        self.interaction.set_edge_selection(e);
    }

    /// Delete has something to act on: clips, captions or a selected gap (`interaction.hasDeleteTarget`).
    pub fn has_delete_target(&self) -> bool {
        self.interaction.has_delete_target()
    }

    /// The clip edges selected by a click on a head or tail (`interaction.edgeSelection?.edges ?? []`).
    pub fn selected_edges(&self) -> Vec<sq_editor_session::EdgeRef> {
        self.interaction.edge_selection().map(|e| e.edges.clone()).unwrap_or_default()
    }

    /// Height of the zoom scroll bar.
    pub(crate) const ZOOM_BAR_HEIGHT: f64 = ZoomScrollBarControl::HEIGHT;

    /// An empty panel.
    pub fn new(theme: DrawTheme) -> TimelinePanel {
        let empty = Timeline::new(Id::from_u128(0), "", SequenceFormat::new(Time::new(1, 25)), Vec::new());
        let geometry = TimelineGeometry::new(empty.format.frame_duration, 40.0);
        let interaction = TimelineInteraction::new(empty.clone(), geometry.clone(), 0);
        let mut p = TimelinePanel {
            theme,
            timeline: empty.clone(),
            sync_badges: BTreeMap::new(),
            prefix_ends: BTreeMap::new(),
            content_revision: 0,
            transition_layer_tracks: BTreeSet::new(),
            lane_cache: LaneCache::default(),
            committed: empty,
            geometry,
            interaction,
            selection: BTreeSet::new(),
            caption_selection: BTreeSet::new(),
            playhead: Time::ZERO,
            selected_transition: None,
            labels: LabelResolver::default(),
            cached_ranges: Vec::new(),
            beat_level: BeatSnapLevel::EveryBeat,
            frame: Rect::ZERO,
            scale: 1.0,
            size: CGSize { width: 0.0, height: 0.0 },
            clock: Box::new(uptime),
            tool_hold: ToolHold::new(),
            fitted: false,
            scrolled_to_base: false,
            zoom_animation: None,
            fit_toggle: ZoomFitToggle::default(),
            key_handled: false,
            gesture: None,
            down_modifiers: InputModifiers::NONE,
            press_cursor: None,
            keep_attached_used: false,
            live_modifiers: None,
            last_drag: None,
            last_autoscroll: None,
            last_click: None,
            scrub_snap_time: None,
            hover_track: None,
            hover_point: None,
            slip_two_up_shown: false,
            drop_preview: DropPreview::new(),
            effect_drop_target: None,
            transition_drop_target: None,
            transition_layer_drop_target: None,
            last_hint: None,
            zoom_bar: ZoomScrollBarControl::new(),
            media: None,
            thumbnail_mode: ThumbnailMode::Head,
            silence_preview: Vec::new(),
            selected_line_keys: BTreeSet::new(),
            speed_band_clips: BTreeSet::new(),
            is_playing: false,
            track_weak_spans: None,
            follow: TimelineFollow::default(),
            wheel: TimelineWheelState::default(),
            follow_was_playing: false,
            grade_outline: BTreeSet::new(),
            analysis_progress: BTreeMap::new(),
            height_store: None,
            skimmer_time: None,
            line_step_open: false,
            key_lanes: None,
            duck_curve: None,
            source_patch_streams: None,
            patch_drop_track: None,
            keystone_bar: None,
            keystone_bar_clip: None,
            keystone_ghost: None,
            item_lanes: ItemLaneState::default(),
            word_field: None,
            word_field_press_at: None,
            word_field_drag: None,
            ui_now: 0.0,
            caption_search: None,
            id_serial: 0,
            id_salt: random_salt(),
        };
        p.refresh_draw_caches();
        p
    }

    // MARK: Tool state (the Mac view's `toolState`, set by the tool strip and the tool keys)

    /// The tool state the interaction reducer reads.
    pub fn tool_state(&self) -> &ToolState {
        &self.interaction.tool_state
    }
    /// Mutable tool state.
    pub fn tool_state_mut(&mut self) -> &mut ToolState {
        &mut self.interaction.tool_state
    }

    /// True while a press is held (the host keeps routing drags here even outside the frame).
    pub fn is_dragging(&self) -> bool {
        self.gesture.is_some()
    }

    /// Whether host pixels `x, y` are inside the panel.
    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.frame.contains(x, y)
    }

    /// Host pixels of a time on the content area (scripted input, the edit test).
    pub fn pixel_x(&self, t: Time) -> f32 {
        self.frame.x + self.geometry.x(t) as f32 * self.scale
    }

    /// Host pixels of the middle of a track's lower half (the clip body, below the name band's trim handles).
    pub fn pixel_y_body_of(&self, track: Id) -> Option<f32> {
        self.rows().iter().find(|r| r.track == track).map(|r| self.frame.y + (r.y + r.height * 0.7) as f32 * self.scale)
    }

    /// Host pixels of a track row, top to bottom (scripted input).
    pub fn pixel_row_of(&self, track: Id) -> Option<(f32, f32)> {
        self.rows()
            .iter()
            .find(|r| r.track == track)
            .map(|r| (self.frame.y + r.y as f32 * self.scale, self.frame.y + (r.y + r.height) as f32 * self.scale))
    }

    // MARK: Session sync

    /// Takes the session's state. Skipped while a gesture runs, so the drag's preview is not replaced under the
    /// pointer; a new sequence starts with a fresh view.
    pub fn sync(&mut self, v: SessionView<'_>) {
        let SessionView { timeline: t, selection: sel, captions, playhead, selected_transition, labels, line_keys } = v;
        self.labels = labels;
        self.playhead = playhead;
        self.selected_line_keys = line_keys;
        if self.gesture.is_some() {
            return;
        }
        // A caption track added to the open sequence (Create Captions): the caption rows sit above the video tracks and
        // scroll with them, so a view opened at the base would cut the new track off at the top. Scroll it into full view.
        let caption_track_added =
            t.id == self.committed.id && t.caption_tracks.len() > self.committed.caption_tracks.len();
        if t.id != self.committed.id {
            // The height preset and Fit All Tracks are app-wide, not per sequence: a fresh geometry would fall back
            // to `.auto` and stretch the rows past the Mix row.
            let (mode, fit) = (self.geometry.height_mode, self.geometry.fit_all_tracks);
            self.geometry = TimelineGeometry::new(t.format.frame_duration, self.geometry.points_per_second);
            self.geometry.height_mode = mode;
            self.geometry.fit_all_tracks = fit;
            self.geometry.viewport_height = self.track_area_height();
            let tool_state = self.interaction.tool_state;
            self.interaction = TimelineInteraction::new(t.clone(), self.geometry.clone(), self.interaction_seed());
            self.interaction.tool_state = tool_state;
            self.fitted = false;
            // The remembered `\` level and a running glide belong to the old sequence: restoring them in the new one
            // jumped to an unrelated zoom (the Fit press that should fit did nothing or went somewhere else).
            self.fit_toggle = ZoomFitToggle::default();
            self.zoom_animation = None;
            self.scrolled_to_base = false;
            if let Some(defaults) = &self.height_store {
                let mut defaults = defaults.borrow_mut();
                let store = TrackHeightStore::new(&mut *defaults);
                self.geometry.height_overrides = store.load(t.id);
                self.geometry.split_fraction = store.load_split(t.id);
            }
        }
        self.geometry.frame_duration = t.format.frame_duration;
        if *t != self.committed || *t != self.timeline {
            self.committed = t.clone();
            self.set_timeline(t.clone());
            self.interaction.reset(t.clone());
        }
        self.scroll_to_base_if_needed();
        if caption_track_added {
            self.geometry.scroll_y = 0.0;
            self.clamp_scroll();
        }
        self.sync_keystone_bar();
        self.sync_item_lanes();
        self.word_field_follows_timeline();
        if let Some(search) = &mut self.caption_search {
            search.resync(&self.timeline, self.playhead);
        }
        if self.interaction.selection() != sel {
            self.interaction.set_selection(sel.clone());
        }
        if self.interaction.caption_selection() != captions {
            self.interaction.set_caption_selection(captions.clone());
        }
        self.selection = sel.clone();
        self.caption_selection = captions.clone();
        self.selected_transition = selected_transition;
        if self.size.width > 0.0 {
            self.fit_if_needed();
            self.clamp_scroll();
        }
    }

    /// Fixes the id salt (tests that need reproducible ids; the app keeps the random one).
    #[cfg(test)]
    pub(crate) fn with_id_salt(mut self, salt: u128) -> Self {
        self.id_salt = salt;
        self
    }

    /// The seed for the ids the interaction mints (new tracks and copies inside a drag): the panel's salt, the
    /// timeline and its revision.
    fn interaction_seed(&self) -> u128 {
        self.id_salt ^ self.committed.id.as_u128() ^ (self.content_revision as u128) << 64
    }

    /// An id source for the panel's own edits: distinct per call, and per panel instance through the salt.
    pub(crate) fn fresh_ids(&mut self) -> PanelIds {
        self.id_serial += 1;
        PanelIds(self.interaction_seed() ^ (self.id_serial << 96))
    }

    /// Replaces the drawn timeline (`didSet { refreshDrawCaches() }`).
    pub(crate) fn set_timeline(&mut self, t: Timeline) {
        self.timeline = t;
        self.refresh_draw_caches();
    }

    // MARK: Layout

    /// Places the panel at `rect` (device pixels) with `scale` pixels per point.
    pub fn layout_px(&mut self, rect: Rect, scale: f32) {
        self.frame = rect;
        self.scale = scale.max(0.5);
        self.size = CGSize { width: f64::from(rect.w / self.scale), height: f64::from(rect.h / self.scale) };
        self.geometry.viewport_height = self.track_area_height();
        self.fit_if_needed();
        self.scroll_to_base_if_needed();
        self.clamp_scroll();
    }

    /// A timeline with more tracks than fit opens at its base, V1 and A1 around the middle of the lanes (the top
    /// would show V20 and hide the tracks the editor works on), once per shown timeline.
    pub(crate) fn scroll_to_base_if_needed(&mut self) {
        if self.scrolled_to_base || self.track_area_height() <= 0.0 || self.timeline.tracks.is_empty() {
            return;
        }
        self.scrolled_to_base = true;
        self.geometry.viewport_height = self.track_area_height();
        let rows = self.rows();
        let boundary = match Self::split_row(&rows) {
            Some(i) => rows[i].max_y(),
            None => rows.last().map_or(0.0, TrackRow::max_y),
        } + self.geometry.scroll_y;
        let middle = (TimelineGeometry::RULER_HEIGHT + self.track_area_height()) / 2.0;
        self.geometry.scroll_y = 0.0;
        let max = self.max_scroll_y().max(0.0);
        self.geometry.scroll_y = (boundary - middle).clamp(0.0, max);
        self.interaction.geometry = self.geometry.clone();
    }

    /// Height over the zoom scroll bar.
    pub(crate) fn track_area_height(&self) -> f64 {
        (self.size.height - Self::ZOOM_BAR_HEIGHT).max(0.0)
    }

    /// The laid-out track rows.
    pub(crate) fn rows(&self) -> Vec<TrackRow> {
        self.geometry.rows(&self.timeline)
    }

    pub(crate) fn content_viewport_width(&self) -> f64 {
        (self.size.width - TimelineGeometry::CONTENT_ORIGIN_X).max(0.0)
    }

    /// `TimelineView.contentEnd`.
    pub(crate) fn content_end(&self) -> Time {
        let clips = self.timeline.tracks.iter().filter_map(|t| t.clips().last().map(|c| c.timeline().end()));
        let captions = self.timeline.caption_tracks.iter().filter_map(|t| t.items().last().map(|i| i.range.end()));
        clips.chain(captions).max().unwrap_or(Time::ZERO)
    }

    /// Span `\` fits: In/Out when set, else the whole sequence.
    pub(crate) fn fit_span(&self) -> TimeRange {
        match self.timeline.in_out {
            Some(io) if !io.is_empty() => io,
            _ => TimeRange::new(Time::ZERO, self.content_end()),
        }
    }

    /// Whether the last key press was handled by the panel itself; the host must not hand it to the shell again.
    pub fn key_handled(&self) -> bool {
        self.key_handled
    }

    /// The fit span fills the content width with a 16 pt margin on each side.
    pub(crate) fn fit_scale(&self) -> f64 {
        Self::scale_filling(&self.fit_span(), self.content_viewport_width())
    }

    /// Like `fit_scale`, but always for the whole sequence (In/Out must not limit how far one can zoom out).
    pub(crate) fn whole_sequence_fit_scale(&self) -> f64 {
        if self.content_end() > Time::ZERO {
            Self::scale_filling(&TimeRange::new(Time::ZERO, self.content_end()), self.content_viewport_width())
        } else {
            self.fit_scale()
        }
    }

    pub(crate) fn scale_filling(span: &TimeRange, width: f64) -> f64 {
        if span.is_empty() {
            return 1.0;
        }
        let seconds = span.duration.value() as f64 / span.duration.timescale() as f64;
        (width - 2.0 * f64::from(spacing::LG)).max(1.0) / seconds
    }

    pub(crate) fn zoom_limits(&self) -> std::ops::RangeInclusive<f64> {
        let fd = self.geometry.frame_duration;
        TimelineZoom::limits(
            self.whole_sequence_fit_scale(),
            self.content_viewport_width(),
            fd.value() as f64 / fd.timescale() as f64,
        )
    }

    /// How much time an empty sequence shows when it opens.
    pub(crate) const EMPTY_SEQUENCE_SECONDS: i64 = 30;

    pub(crate) fn fit_if_needed(&mut self) {
        if self.fitted || self.content_viewport_width() <= 0.0 {
            return;
        }
        self.fitted = true;
        self.geometry.points_per_second = if self.content_end() > Time::ZERO {
            self.whole_sequence_fit_scale()
        } else {
            // An empty sequence has nothing to fit: show a few seconds, not the zoom for a span of one second per point.
            Self::scale_filling(
                &TimeRange::new(Time::ZERO, Time::seconds(Self::EMPTY_SEQUENCE_SECONDS)),
                self.content_viewport_width(),
            )
        };
        self.geometry.scroll_x = 0.0;
    }

    /// `\`: fit the span (In/Out when set, else the whole sequence); pressed again it returns to the previous zoom.
    /// Animated like the Mac, stepped by `tick`.
    pub fn zoom_to_fit(&mut self) {
        let now = self.zoom_target();
        match self.fit_toggle.press(now.0, now.1, self.fit_scale()) {
            sq_timeline_ui::ZoomFitAction::Restore { scale, scroll_x } => {
                let to = TimelineZoom::clamp(scale, &self.zoom_limits());
                self.start_zoom_animation(to, scroll_x, ZoomAnimationMode::Free);
            }
            sq_timeline_ui::ZoomFitAction::Fit => {
                let span = self.fit_span();
                if span.is_empty() {
                    return;
                }
                let start_seconds = span.start.value() as f64 / span.start.timescale() as f64;
                let scale = TimelineZoom::clamp(self.fit_scale(), &self.zoom_limits());
                self.start_zoom_animation(
                    scale,
                    start_seconds * scale - f64::from(spacing::LG),
                    ZoomAnimationMode::Free,
                );
            }
        }
    }

    /// `TimelineView.setZoom`: keeps the time under `anchor_x` (panel points) fixed; `None` = the playhead when visible.
    /// Immediate (wheel, pinch, bar); it ends a running zoom animation.
    pub fn set_zoom(&mut self, pps: f64, anchor_x: Option<f64>) {
        self.zoom_animation = None;
        self.end_spring_back(false);
        let new = TimelineZoom::clamp(pps, &self.zoom_limits());
        if new == self.geometry.points_per_second {
            return;
        }
        let anchor = anchor_x.unwrap_or_else(|| self.default_zoom_anchor());
        self.geometry.scroll_x = TimelineZoom::anchored_scroll(
            self.geometry.points_per_second,
            new,
            self.geometry.scroll_x,
            anchor - TimelineGeometry::CONTENT_ORIGIN_X,
        );
        self.geometry.points_per_second = new;
        self.clamp_scroll();
    }

    /// `=`: one step in (keyboard: lands at once).
    pub fn zoom_in(&mut self) {
        self.animate_zoom_step(TimelineZoom::KEY_STEP, None);
    }
    /// `-`: one step out (keyboard: lands at once).
    pub fn zoom_out(&mut self) {
        self.animate_zoom_step(1.0 / TimelineZoom::KEY_STEP, None);
    }

    // MARK: Zoom animation (keys, zoom-tool click, fit)

    /// Scale and scroll the view shows now, or the running animation's target.
    pub(crate) fn zoom_target(&self) -> (f64, f64) {
        match &self.zoom_animation {
            Some(z) => (z.anim.to_scale, z.anim.to_scroll),
            None => (self.geometry.points_per_second, self.geometry.scroll_x),
        }
    }

    /// A zoom animation runs: the host keeps drawing frames until it lands.
    pub fn is_zooming(&self) -> bool {
        self.zoom_animation.is_some()
    }

    pub(crate) fn animate_zoom_step(&mut self, factor: f64, anchor_x: Option<f64>) {
        let t = self.zoom_target();
        let new = TimelineZoom::clamp(t.0 * factor, &self.zoom_limits());
        let anchor = anchor_x.unwrap_or_else(|| self.default_zoom_anchor()) - TimelineGeometry::CONTENT_ORIGIN_X;
        let scroll = TimelineZoom::anchored_scroll(t.0, new, t.1, anchor);
        self.jump_zoom(new, scroll, ZoomAnimationMode::Anchored { x: anchor });
    }

    /// Animates from the shown state to `to_scale`/`to_scroll` (the anchored end state is derived from the shown
    /// state, so a restart mid-animation does not snap in the last frame).
    pub(crate) fn start_zoom_animation(&mut self, to_scale: f64, to_scroll: f64, mode: ZoomAnimationMode) {
        self.zoom_view(to_scale, to_scroll, mode, true);
    }

    /// Lands the view at once (keys, zoom-tool click, page turn): same state as the animation, no frames asked for.
    pub(crate) fn jump_zoom(&mut self, to_scale: f64, to_scroll: f64, mode: ZoomAnimationMode) {
        self.zoom_view(to_scale, to_scroll, mode, false);
    }

    fn zoom_view(&mut self, to_scale: f64, to_scroll: f64, mode: ZoomAnimationMode, animated: bool) {
        self.end_spring_back(true);
        let from = (self.geometry.points_per_second, self.geometry.scroll_x);
        self.zoom_animation = None;
        let mut to_scroll = to_scroll;
        if let ZoomAnimationMode::Anchored { x } = mode {
            to_scroll = TimelineZoom::anchored_scroll(from.0, to_scale, from.1, x);
        }
        if to_scale == from.0 && to_scroll == from.1 {
            return;
        }
        if !animated || sq_draw::motion::reduce_motion() {
            // Immediate (or reduce motion): the view lands at once (the state is the same, only the glide is gone).
            self.geometry.points_per_second = TimelineZoom::clamp(to_scale, &self.zoom_limits());
            self.geometry.scroll_x = to_scroll.max(0.0);
            self.clamp_scroll();
            return;
        }
        self.zoom_animation = Some(RunningZoom {
            anim: ZoomAnimation {
                from_scale: from.0,
                from_scroll: from.1,
                to_scale,
                to_scroll: to_scroll.max(0.0),
                mode,
            },
            start: (self.clock)(),
        });
    }

    /// One frame of a running zoom animation (`TimelineView.zoomAnimationTick`).
    pub(crate) fn step_zoom_animation(&mut self) {
        let Some(z) = &self.zoom_animation else { return };
        let p = ZoomAnimation::progress((self.clock)() - z.start);
        let s = z.anim.state(p);
        self.geometry.points_per_second = TimelineZoom::clamp(s.0, &self.zoom_limits());
        self.geometry.scroll_x = s.1;
        self.clamp_scroll();
        if p >= 1.0 {
            self.zoom_animation = None;
        }
    }

    /// Jumps a running zoom animation to its end state.
    pub fn settle_zoom_animation(&mut self) {
        let Some(z) = self.zoom_animation.take() else { return };
        let s = z.anim.state(1.0);
        self.geometry.points_per_second = TimelineZoom::clamp(s.0, &self.zoom_limits());
        self.geometry.scroll_x = s.1;
        self.clamp_scroll();
    }

    pub(crate) fn default_zoom_anchor(&self) -> f64 {
        let x = self.geometry.x(self.playhead);
        if x >= TimelineGeometry::CONTENT_ORIGIN_X && x <= self.size.width {
            x
        } else {
            TimelineGeometry::CONTENT_ORIGIN_X + self.content_viewport_width() / 2.0
        }
    }

    pub(crate) fn max_scroll_x(&self) -> f64 {
        TimelineZoom::max_scroll(self.geometry.width(self.content_end()), self.content_viewport_width())
    }

    /// `TimelineView.maxScrollY`: vertical overflow, under one point counts as none.
    pub(crate) fn max_scroll_y(&self) -> f64 {
        let rows = self.rows();
        let base = match rows.last() {
            Some(r) => r.max_y() + r.lane_space + self.geometry.scroll_y,
            None => TimelineGeometry::RULER_HEIGHT + self.geometry.caption_height(&self.timeline),
        };
        let content =
            base + if self.geometry.reserves_ghost_space { 2.0 * TimelineGeometry::GHOST_ROW_HEIGHT } else { 0.0 };
        let over = content + Self::ZOOM_BAR_HEIGHT - self.size.height;
        if over < 1.0 { 0.0 } else { over }
    }

    pub(crate) fn clamp_scroll(&mut self) {
        if self.wheel.allows_overscroll() {
            // A rubber-band pull or its spring back.
            self.interaction.geometry = self.geometry.clone();
            return;
        }
        self.geometry.scroll_x = self.geometry.scroll_x.clamp(0.0, self.max_scroll_x().max(0.0));
        self.geometry.scroll_y = self.geometry.scroll_y.clamp(0.0, self.max_scroll_y().max(0.0));
        self.interaction.geometry = self.geometry.clone();
    }

    // MARK: Shared row facts (`TimelineView.splitRow` / `isAltLane`, translated as they are)

    pub(crate) fn split_row(rows: &[TrackRow]) -> Option<usize> {
        let a = rows.iter().position(|r| r.kind == TrackKind::Audio)?;
        if a > 0 { Some(a - 1) } else { None }
    }

    pub(crate) fn is_alt_lane(index: usize, rows: &[TrackRow]) -> bool {
        let first_audio = rows.iter().position(|r| r.kind == TrackKind::Audio).unwrap_or(rows.len());
        if index < first_audio {
            !(first_audio - 1 - index).is_multiple_of(2)
        } else {
            (index - first_audio).is_multiple_of(2)
        }
    }

    /// `TimelineView.audioSoloActive`: some audio track is soloed.
    pub(crate) fn audio_solo_active(t: &Timeline) -> bool {
        t.tracks.iter().any(|t| t.kind == TrackKind::Audio && t.is_solo)
    }

    /// A track whose clips are veiled: hidden video, muted audio, or audio while another track is soloed.
    pub(crate) fn is_inactive(track: &Track, solo_active: bool) -> bool {
        if track.kind == TrackKind::Video {
            !track.is_visible
        } else {
            track.is_muted || (solo_active && !track.is_solo)
        }
    }

    /// The clip with `id` and the track it sits on.
    pub(crate) fn clip_and_track(&self, id: Id) -> Option<(&Clip, Id)> {
        self.timeline.tracks.iter().find_map(|t| t.clips().iter().find(|c| c.id == id).map(|c| (c, t.id)))
    }
}
