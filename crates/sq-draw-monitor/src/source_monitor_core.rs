// Swift: SourceMonitorCore.swift
//! The Source monitor without its view: plays one project media item on its own engine (a one-clip sequence in the
//! media's own format) and holds the item's In/Out marks (`Project.source_marks`). Insert and Overwrite go through
//! `EditorSession::source_edit`. Only one monitor plays at a time: starting one pauses the other (`pause()`).
//!
//! The Swift class stored the session and wired the model's hooks; here every call that needs the session takes it, the
//! model's hook events are applied by [`SourceMonitorCore::pump`], and the class's own hooks are [`SourceCoreEvent`]s.
//! The engine's `onPositionChange` is [`SourceMonitorCore::tick`] (the app polls it once per frame).

use crate::monitor_drop_indicator::SourceViewerMode;
use crate::monitor_panel_model::{MenuQueue, MonitorEvent, MonitorPanelModel, SourceItem};
use crate::source_timeline_builder::{Built, SourceTimelineBuilder};
use sq_core_edit::four_point_fit::FourPointFit;
use sq_core_edit::playback::{PlaybackRate, Shuttle, ShuttleAction, ShuttleKey};
use sq_core_edit::playback_bounds::{PlaybackAction, PlaybackBounds};
use sq_core_edit::source_markers::{SourceHistory, SourceMarkersExt, SourceMarksWholeClipExt};
use sq_core_edit::timeline_source_edit::{SourceStreams, TimelineSourceEditExt};
use sq_core_model::{Project, SequenceFormat, SourceMarks, ThreePointMode, Timeline};
use sq_core_time::{Id, IdSource, Time};
use sq_draw::monitor::monitor_footer::ScrubHit;
use sq_draw::monitor::monitor_modes::MonitorAction;
use sq_editor_session::{EditorSession, ProgramEngine};
use sq_media::waveform_data::WaveformData;
use sq_os::Platform;
use sq_playback::engine::preview_rate::PreviewRate;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::BTreeMap;
use std::rc::Rc;

/// Fit Clip choice of a four-mark Source edit whose source and sequence ranges differ in length; the last choice is
/// remembered (`sq.fourPointFit`). The Mac sheet and the Windows shell form both list these rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FourPointFitChoice {
    /// Change Speed (the session's `fitToFill`).
    ChangeSpeed,
    /// Trim Source End.
    TrimSourceEnd,
    /// Ignore Source In.
    IgnoreSourceIn,
    /// Ignore Sequence In.
    IgnoreSequenceIn,
    /// Ignore Sequence Out.
    IgnoreSequenceOut,
}

impl FourPointFitChoice {
    /// Every row, in sheet order.
    pub const ALL: [FourPointFitChoice; 5] =
        [Self::ChangeSpeed, Self::TrimSourceEnd, Self::IgnoreSourceIn, Self::IgnoreSequenceIn, Self::IgnoreSequenceOut];
    /// Defaults key of the remembered choice.
    pub const KEY: &'static str = "sq.fourPointFit";

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::ChangeSpeed => "changeSpeed",
            Self::TrimSourceEnd => "trimSourceEnd",
            Self::IgnoreSourceIn => "ignoreSourceIn",
            Self::IgnoreSequenceIn => "ignoreSequenceIn",
            Self::IgnoreSequenceOut => "ignoreSequenceOut",
        }
    }

    /// The row's text.
    pub fn title(self) -> &'static str {
        match self {
            Self::ChangeSpeed => "Change Speed (fit the source into the range)",
            Self::TrimSourceEnd => "Trim Source End (sequence range, source In)",
            Self::IgnoreSourceIn => "Ignore Source In (source Out ends the clip)",
            Self::IgnoreSequenceIn => "Ignore Sequence In (clip ends at Out)",
            Self::IgnoreSequenceOut => "Ignore Sequence Out (source length at In)",
        }
    }

    /// `None` for Change Speed (the session's `fitToFill`).
    pub fn fit(self) -> Option<FourPointFit> {
        match self {
            Self::ChangeSpeed => None,
            Self::TrimSourceEnd => Some(FourPointFit::TrimSourceEnd),
            Self::IgnoreSourceIn => Some(FourPointFit::IgnoreSourceIn),
            Self::IgnoreSequenceIn => Some(FourPointFit::IgnoreSequenceIn),
            Self::IgnoreSequenceOut => Some(FourPointFit::IgnoreSequenceOut),
        }
    }

    /// The remembered choice (Trim Source End when none).
    pub fn saved(d: &dyn UiDefaults) -> FourPointFitChoice {
        d.string(Self::KEY)
            .and_then(|s| Self::ALL.into_iter().find(|c| c.raw_value() == s))
            .unwrap_or(Self::TrimSourceEnd)
    }

    /// Remembers `c`.
    pub fn save(c: FourPointFitChoice, d: &mut dyn UiDefaults) {
        d.set_string(Self::KEY, c.raw_value());
    }
}

/// What a row of the Source monitor's context menu asks of the core (the rows hold no reference to it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceMenuCommand {
    /// Mark Clip.
    MarkClip,
    /// Mark In.
    MarkIn,
    /// Mark Out.
    MarkOut,
    /// Mark Audio In.
    MarkAudioIn,
    /// Mark Video In.
    MarkVideoIn,
    /// Go to In.
    GoToIn,
    /// Go to Out.
    GoToOut,
    /// Remove In.
    ClearIn,
    /// Remove Out.
    ClearOut,
    /// Remove In and Out.
    ClearMarks,
    /// Add Marker.
    AddMarker,
    /// Delete Marker.
    ClearMarkerAtPlayhead,
    /// Delete All Markers.
    ClearAllMarkers,
    /// Insert.
    Insert,
    /// Overwrite.
    Overwrite,
    /// Fit to Fill.
    FitToFill,
    /// Replace Clip from Source.
    Replace,
    /// Make Subclip.
    MakeSubclip,
    /// Export Frame.
    ExportFrame,
    /// Loop Playback.
    ToggleLoop,
    /// Reveal in Project.
    Reveal,
    /// Show All Angles.
    ToggleAngles,
}

/// What the Swift core's hooks reported.
#[derive(Clone, Debug, PartialEq)]
pub enum SourceCoreEvent {
    /// `onMediaChange`: the loaded clip changed (the timeline's source patch column follows it).
    MediaChange,
    /// `onStatus`.
    Status(String),
    /// `onStartedPlaying`: playback started here, the Program monitor must stop.
    StartedPlaying,
    /// `onRevealInProject`.
    RevealInProject(Id),
    /// `onToggleAngles`.
    ToggleAngles,
    /// `onExportFrame`: Export Frame on the platform (the Mac full-size render, the Windows engine's shown picture).
    ExportFrame,
    /// `chooseFourPointFit`: ask which Fit Clip rule decides a four-mark edit; answer with
    /// [`SourceMonitorCore::resolve_four_point_fit`].
    ChooseFourPointFit,
}

/// A four-mark edit waiting for the Fit Clip answer.
#[derive(Clone, Copy, Debug)]
struct PendingEdit {
    media: Id,
    streams: SourceStreams,
    mode: ThreePointMode,
    place_on_top: bool,
}

/// Peaks of an audio-only clip for the waveform view (the host asks its peak store; `None` until they are built).
pub type WaveformProvider = Box<dyn Fn(Id) -> Option<WaveformData>>;

/// The Source monitor's player and mark keeper.
pub struct SourceMonitorCore {
    /// The Source engine.
    pub engine: Box<dyn ProgramEngine>,
    /// The state the panel shows.
    pub model: MonitorPanelModel,
    media_id: Option<Id>,
    shuttle: Shuttle,
    frame_duration: Time,
    duration: Time,
    /// Picture shape the loaded source timeline was built with; a pixel aspect change alters it (re-derived in `sync`).
    loaded_shape: Vec<i64>,
    is_playing: bool,
    preview_rate: PreviewRate,
    position: Time,
    /// The engine wraps a loop by itself (the Mac PlaybackEngine); otherwise `position_changed` seeks back.
    pub engine_wraps_loops: bool,
    bounds: PlaybackBounds,
    history: SourceHistory,
    /// Preroll of Play In to Out with roll and of Play Around (Preferences > Playback).
    pub preroll: Time,
    /// Postroll of Play In to Out with roll and of Play Around.
    pub postroll: Time,
    /// Streams of the drag in flight (video-only / audio-only icons); read by the timeline's drop handler.
    pub drag_streams: SourceStreams,
    /// Peaks of an audio-only clip for the waveform view.
    pub waveform_provider: Option<WaveformProvider>,
    /// "Show All Angles" row of the context menu (`false` = no row); `angles_available`: an Angles clip is under the playhead.
    pub shows_angles_row: bool,
    /// An Angles clip is under the playhead.
    pub angles_available: bool,
    /// The host asks which Fit Clip rule decides a four-mark edit (`false` = no question, Trim Source End).
    pub asks_four_point_fit: bool,
    /// What the hooks reported since the owner last took it.
    pub events: Vec<SourceCoreEvent>,
    pending_edit: Option<PendingEdit>,
    menu: MenuQueue<SourceMenuCommand>,
    ids: Box<dyn IdSource>,
}

impl SourceMonitorCore {
    /// A core over `engine`; `model` is the host's Source model when its view is built before the core. `ids` makes the
    /// ids of the one-clip timelines.
    pub fn new(
        engine: Box<dyn ProgramEngine>,
        model: Option<MonitorPanelModel>,
        ids: Box<dyn IdSource>,
    ) -> SourceMonitorCore {
        let mut model = model.unwrap_or_else(|| {
            MonitorPanelModel::new(Time::new(1, 30), sq_draw::monitor::monitor_modes::MonitorMode::Source)
        });
        // The hooks Swift's `wire()` assigned: this core consumes them.
        model.wired.mark_edit = true;
        model.wired.preview_rate = true;
        model.wired.scrub = true;
        SourceMonitorCore {
            engine,
            model,
            media_id: None,
            shuttle: Shuttle::new(),
            frame_duration: Time::new(1, 30),
            duration: Time::ZERO,
            loaded_shape: Vec::new(),
            is_playing: false,
            preview_rate: PreviewRate::NORMAL,
            position: Time::ZERO,
            engine_wraps_loops: false,
            bounds: PlaybackBounds::default(),
            history: SourceHistory::new(),
            preroll: PlaybackBounds::DEFAULT_PREROLL,
            postroll: PlaybackBounds::DEFAULT_POSTROLL,
            drag_streams: SourceStreams::Both,
            waveform_provider: None,
            shows_angles_row: false,
            angles_available: false,
            asks_four_point_fit: false,
            events: Vec::new(),
            pending_edit: None,
            menu: MenuQueue::default(),
            ids,
        }
    }

    /// Takes the hook calls since the last take.
    pub fn take_events(&mut self) -> Vec<SourceCoreEvent> {
        std::mem::take(&mut self.events)
    }

    /// The clip loaded.
    pub fn media_id(&self) -> Option<Id> {
        self.media_id
    }
    /// The loaded clip's frame duration.
    pub fn frame_duration(&self) -> Time {
        self.frame_duration
    }
    /// The loaded clip's length.
    pub fn duration(&self) -> Time {
        self.duration
    }
    /// The clip plays.
    pub fn is_playing(&self) -> bool {
        self.is_playing
    }
    /// Clips opened earlier (title popup): at most 20, most recent first.
    pub fn history(&self) -> &SourceHistory {
        &self.history
    }
    /// The play range and loop.
    pub fn bounds(&self) -> &PlaybackBounds {
        &self.bounds
    }
    /// Mutable play range and loop: the engine follows (the Swift `didSet`).
    pub fn set_bounds(&mut self, b: PlaybackBounds) {
        // The picture leads the clock while playing (display lead): it must not show frames past the range end, and
        // the engine wraps a loop itself (the frames after the wrap are picked before the clock gets there).
        if b.range() != self.bounds.range() {
            self.engine.set_play_range(b.range());
        }
        if b.loop_playback != self.bounds.loop_playback {
            self.engine.set_loops(b.loop_playback);
        }
        self.bounds = b;
    }
    fn set_range(&mut self, range: Option<sq_core_time::TimeRange>) {
        let mut b = self.bounds;
        b.set_range(range);
        self.set_bounds(b);
    }
    fn toggle_loop(&mut self) {
        let mut b = self.bounds;
        b.loop_playback = !b.loop_playback;
        self.model.is_looping = b.loop_playback;
        self.set_bounds(b);
    }
    /// The playhead.
    pub fn current_time(&self) -> Time {
        self.position
    }
    /// Displayed picture size of the loaded clip [width, height] (the panel's aspect and zoom percentages).
    pub fn picture_shape(&self) -> &[i64] {
        &self.loaded_shape
    }
    /// The loaded clip's marks.
    pub fn marks(&self, s: &EditorSession) -> SourceMarks {
        self.media_id.map(|id| s.project().source_marks_for(id)).unwrap_or_default()
    }

    /// The monitor's buttons, keys and menus.
    pub fn perform(&mut self, s: &mut EditorSession, a: MonitorAction) {
        match a {
            MonitorAction::MarkIn => self.mark_in(s),
            MonitorAction::MarkOut => self.mark_out(s),
            MonitorAction::GoToIn => self.go_to_in(s),
            MonitorAction::GoToOut => self.go_to_out(s),
            MonitorAction::ClearIn => self.clear_in(s),
            MonitorAction::ClearOut => self.clear_out(s),
            MonitorAction::ClearInOut => self.clear_marks(s),
            MonitorAction::StepBack => self.step_frames(-1),
            MonitorAction::StepForward => self.step_frames(1),
            MonitorAction::PlayPause => self.play_pause(),
            MonitorAction::AddMarker => self.add_marker(s),
            MonitorAction::Insert => self.edit(s, ThreePointMode::Insert, SourceStreams::Both, false, false, false),
            MonitorAction::Overwrite => {
                self.edit(s, ThreePointMode::Overwrite, SourceStreams::Both, false, false, false)
            }
            MonitorAction::FitToFill => {
                self.edit(s, ThreePointMode::Overwrite, SourceStreams::Both, false, false, true)
            }
            MonitorAction::Replace => self.replace_selected_clip(s),
            MonitorAction::ExportFrame => self.export_frame(),
            MonitorAction::Loop => self.toggle_loop(),
            MonitorAction::PlayInToOut => self.play_in_to_out(s, false),
            MonitorAction::Lift | MonitorAction::Extract | MonitorAction::ToggleSafeMargins => {}
        }
    }

    /// Applies the hook events the model reported (Swift wired these in `wire()`) and the context menu's queued rows.
    /// Events this core does not own stay in the model for the panel's owner.
    pub fn pump(&mut self, s: &mut EditorSession) {
        self.model.apply_menu_commands();
        for c in self.menu.take() {
            self.run_menu(s, c);
        }
        for e in self.model.take_events() {
            match e {
                MonitorEvent::Seek(t) => self.seek(t),
                MonitorEvent::ScrubBegan => self.begin_scrub(),
                MonitorEvent::Scrub(t) => self.scrub(t),
                MonitorEvent::ScrubEnded => self.end_scrub(),
                MonitorEvent::PreviewRateChange(r) => {
                    self.preview_rate = r;
                    if self.is_playing && self.engine.rate().is_forward() {
                        self.play(r.rate);
                    }
                }
                MonitorEvent::QualityChange(q) => self.engine.set_quality(q.decode_scale()),
                MonitorEvent::Action(a) => self.perform(s, a),
                MonitorEvent::DragEnded => self.drag_streams = SourceStreams::Both,
                MonitorEvent::MarkEdit(ScrubHit::MarkIn, t) => self.set_marks(s, |p, id| p.set_source_in(t, id)),
                MonitorEvent::MarkEdit(ScrubHit::MarkOut, t) => self.set_marks(s, |p, id| p.set_source_out(t, id)),
                MonitorEvent::MarkEdit(ScrubHit::Playhead, _) => {}
                MonitorEvent::PickSource(id) => {
                    self.open(s, id, None);
                }
                MonitorEvent::CloseSource => self.close_current(s),
                MonitorEvent::CloseAllSources => self.close_all(s),
                MonitorEvent::DropMedia(ids) => {
                    self.open_all(s, &ids);
                }
                other => self.model.emit(other),
            }
        }
        self.model.context_menu = self.context_menu_items(s);
    }

    /// Per frame: the engine reported a new position (Swift `engine.onPositionChange`).
    pub fn tick(&mut self, s: &mut EditorSession) {
        if let Some(t) = self.engine.take_position_change() {
            self.position_changed(s, t);
        }
    }

    // MARK: Loading

    /// Loads `id`, parked at `time` (the start when `None`). False for unknown media or one without a duration.
    pub fn open(&mut self, s: &mut EditorSession, id: Id, time: Option<Time>) -> bool {
        let Some(r) = s.project().media(id).cloned() else { return false };
        let Some(built) = SourceTimelineBuilder::build(&r, self.ids.as_mut()) else {
            if Some(id) == self.media_id {
                // even on failure: no repeated status on every project change
                self.loaded_shape = SourceTimelineBuilder::shape(&r);
            }
            self.events.push(SourceCoreEvent::Status(SQL10n::format("“%@” has no readable duration yet.", &[&r.name])));
            return false;
        };
        let fd = built.format.frame_duration;
        let total = built.total;
        self.pause();
        self.set_media_id(Some(id));
        self.set_range(None);
        self.engine.set_timeline(&built.timeline, &BTreeMap::new());
        self.apply_built(&r, &built);
        let start = time.unwrap_or(Time::ZERO).snapped(fd);
        self.position = start.min(Time::ZERO.max(total - fd));
        self.engine.seek(self.position);
        self.model.current_time = self.position;
        self.history.open(id);
        self.refresh_marks(s);
        true
    }

    fn set_media_id(&mut self, id: Option<Id>) {
        if self.media_id != id {
            self.media_id = id;
            self.events.push(SourceCoreEvent::MediaChange);
        }
    }

    /// What the opened timeline says about the clip: shape, frame rate, length, drop frame, viewer mode and waveform.
    fn apply_built(&mut self, r: &sq_core_model::MediaRef, built: &Built) {
        let fd = built.format.frame_duration;
        let video = r.info.as_ref().and_then(|i| i.video.as_ref());
        self.loaded_shape = vec![built.format.width, built.format.height];
        self.frame_duration = fd;
        self.duration = built.total;
        self.model.frame_duration = fd;
        self.model.drop_frame = fd == Time::new(1001, 30000) || fd == Time::new(1001, 60000);
        self.model.duration = built.total;
        let mode = SourceViewerMode::resolve(
            true,
            video.is_some() || built.still || r.info.is_none(),
            r.info.as_ref().is_some_and(|i| i.audio.is_some()),
        );
        self.model.viewer_mode = mode;
        // An audio-only source has nothing to see while dragging: scrubbing always plays grains (tape scrub).
        self.engine.set_audio_scrubbing(mode == SourceViewerMode::Waveform);
        self.model.source_waveform = if mode == SourceViewerMode::Waveform {
            self.waveform_provider.as_ref().and_then(|p| p(r.id))
        } else {
            None
        };
    }

    /// A new displayed shape (pixel aspect, or probe info that arrived late): the source timeline is built again in
    /// place. Playback keeps running; the frame rate, length and mode follow the new info, the playhead and the play
    /// In to Out range are clamped to the new end.
    fn reshape(&mut self, r: &sq_core_model::MediaRef) {
        self.loaded_shape = SourceTimelineBuilder::shape(r);
        let Some(built) = SourceTimelineBuilder::build(r, self.ids.as_mut()) else { return };
        self.engine.set_timeline(&built.timeline, &BTreeMap::new());
        self.apply_built(r, &built);
        if let Some(range) = self.bounds.range() {
            let c = SourceTimelineBuilder::clamped_range(Some(range), built.total);
            if c != Some(range) {
                self.set_range(c);
            }
        }
        let p = SourceTimelineBuilder::clamped_position(self.position, built.total, built.format.frame_duration);
        if p != self.position {
            self.position = p;
            self.model.current_time = p;
            if !self.is_playing {
                self.engine.seek(p);
            }
        } else if !self.is_playing {
            self.engine.seek(self.position);
        }
    }

    /// Peaks for the audio-only view arrive after the open (the host's peak store builds them off the main actor).
    pub fn waveform_ready(&mut self, id: Id) {
        if Some(id) != self.media_id || self.model.viewer_mode != SourceViewerMode::Waveform {
            return;
        }
        self.model.source_waveform = self.waveform_provider.as_ref().and_then(|p| p(id));
    }

    /// Several clips at once (a drop or a multi-selection): the first one shows, the rest join the history in order.
    pub fn open_all(&mut self, s: &mut EditorSession, ids: &[Id]) -> bool {
        let known: Vec<Id> = ids.iter().copied().filter(|i| s.project().media(*i).is_some()).collect();
        let Some(first) = known.first().copied() else { return false };
        self.history.open_all(&known);
        self.open(s, first, None)
    }

    /// Title popup > Close: the current clip leaves the history; the next one (if any) shows.
    pub fn close_current(&mut self, s: &mut EditorSession) {
        let Some(id) = self.media_id else { return };
        self.history.close(id);
        match self.history.ids().first().copied() {
            Some(next) => {
                self.open(s, next, None);
            }
            None => self.close(s),
        }
    }

    /// Title popup > Close All.
    pub fn close_all(&mut self, s: &mut EditorSession) {
        self.history.close_all();
        self.close(s);
    }

    /// Unloads the clip.
    pub fn close(&mut self, s: &EditorSession) {
        self.pause();
        self.set_media_id(None);
        self.duration = Time::ZERO;
        self.position = Time::ZERO;
        self.model.viewer_mode = SourceViewerMode::Picture;
        self.model.source_waveform = None;
        self.model.duration = Time::ZERO;
        self.model.current_time = Time::ZERO;
        self.model.mark_in = None;
        self.model.mark_out = None;
        self.refresh_marks(s);
        let empty = Timeline::new(self.ids.next_id(), "", SequenceFormat::new(self.frame_duration), Vec::new());
        self.engine.set_timeline(&empty, &BTreeMap::new());
    }

    /// The session changed (Swift `sync(_ change:)`, called with `Change::PROJECT` flagged).
    pub fn sync(&mut self, s: &mut EditorSession, project_changed: bool) {
        let Some(id) = self.media_id else { return };
        if s.project().media(id).is_none() {
            self.history.close(id);
            match self.history.ids().first().copied() {
                Some(next) => {
                    self.open(s, next, None);
                }
                None => self.close(s),
            }
            return;
        }
        if project_changed {
            self.refresh_marks(s);
            // The pixel aspect changes the displayed size: build the source timeline again in the new shape, same place.
            if let Some(r) = s.project().media(id).cloned()
                && SourceTimelineBuilder::needs_reshape(&r, &self.loaded_shape)
            {
                self.reshape(&r);
            }
        }
    }

    fn refresh_marks(&mut self, s: &EditorSession) {
        let existing = s.project().media.iter().map(|m| m.id).collect();
        self.history.prune(&existing);
        self.model.source_items = self
            .history
            .ids()
            .iter()
            .filter_map(|id| s.project().media(*id).map(|m| SourceItem { id: *id, name: m.name.clone() }))
            .collect();
        self.model.source_current = self.media_id;
        let Some(id) = self.media_id else {
            self.model.marker_times = Vec::new();
            return;
        };
        let m = s.project().source_marks_for(id);
        self.model.mark_in = m.mark_in;
        self.model.mark_out = m.mark_out;
        self.model.marker_times = s.project().source_markers(id).iter().map(|m| m.time).collect();
    }

    // MARK: Transport

    /// Pauses the engine.
    pub fn pause(&mut self) {
        if self.is_playing || !self.engine.rate().is_paused() {
            self.engine.pause();
        }
        self.is_playing = false;
        self.shuttle.stopped();
        self.model.is_playing = false;
    }

    /// Scrub gesture on the ruler or waveform: the engine seeks and, for audio-only sources, plays short grains.
    fn begin_scrub(&mut self) {
        self.pause();
        if self.media_id.is_some() {
            self.engine.begin_scrub();
        }
    }

    fn last_frame(&self) -> Time {
        Time::ZERO.max(self.duration - self.frame_duration)
    }

    fn scrub(&mut self, t: Time) {
        if self.media_id.is_none() {
            return;
        }
        let target = Time::ZERO.max(t.snapped(self.frame_duration)).min(self.last_frame());
        self.position = target;
        self.engine.scrub(target);
        self.model.current_time = target;
    }

    fn end_scrub(&mut self) {
        if self.media_id.is_some() {
            self.engine.end_scrub();
        }
    }

    /// Parks on `t` (on the frame grid, inside the clip).
    pub fn seek(&mut self, t: Time) {
        if self.media_id.is_none() {
            return;
        }
        if self.is_playing {
            self.pause();
        }
        let target = Time::ZERO.max(t.snapped(self.frame_duration)).min(self.last_frame());
        self.position = target;
        self.engine.seek(target);
        self.model.current_time = target;
    }

    /// Steps `n` frames.
    pub fn step_frames(&mut self, n: i64) {
        self.seek(self.position + self.frame_duration * n);
    }
    /// Go to the start.
    pub fn go_to_start(&mut self) {
        self.seek(Time::ZERO);
    }
    /// Go to the last frame.
    pub fn go_to_end(&mut self) {
        self.seek(self.last_frame());
    }
    /// Go to In.
    pub fn go_to_in(&mut self, s: &EditorSession) {
        if let Some(i) = self.marks(s).mark_in {
            self.seek(i);
        }
    }
    /// Out is stored exclusive: show the marked (last included) frame.
    pub fn go_to_out(&mut self, s: &EditorSession) {
        if let Some(o) = self.marks(s).mark_out {
            self.seek(o - self.frame_duration);
        }
    }

    /// Plays at `rate` (paused: pauses).
    pub fn play(&mut self, rate: PlaybackRate) {
        if self.media_id.is_none() {
            return;
        }
        if rate.is_paused() {
            self.pause();
            return;
        }
        self.events.push(SourceCoreEvent::StartedPlaying);
        self.set_range(None);
        if rate.is_forward() && self.position + self.frame_duration >= self.duration {
            self.seek(Time::ZERO);
        }
        self.engine.play(rate);
        self.is_playing = true;
        self.model.is_playing = true;
    }

    /// Space.
    pub fn play_pause(&mut self) {
        if self.is_playing {
            self.pause();
        } else {
            self.play(self.preview_rate.rate);
        }
    }

    /// A shuttle key's result.
    pub fn apply_shuttle(&mut self, action: ShuttleAction) {
        match action {
            ShuttleAction::SetRate(r) => self.play(r),
            ShuttleAction::Step(n) => self.step_frames(n),
            ShuttleAction::None => {}
        }
    }

    /// Shift+J / Shift+L.
    pub fn nudge(&mut self, forward: bool) {
        self.play(self.engine.rate().nudged(forward));
        self.shuttle.adopt(self.engine.rate());
    }

    /// J, K, L.
    pub fn press(&mut self, key: ShuttleKey) {
        let a = self.shuttle.press(key);
        self.apply_shuttle(a);
        let _ = self.shuttle.release(key);
    }

    /// Option+K plays In..Out; Shift+Space (`with_roll`) starts `preroll` before In and ends `postroll` after Out.
    pub fn play_in_to_out(&mut self, s: &EditorSession, with_roll: bool) {
        if self.media_id.is_none() {
            return;
        }
        let mut range = Timeline::source_edit_range(&self.marks(s), self.duration);
        if with_roll && let Some(r) = range {
            range = PlaybackBounds::extended(r, self.preroll, self.postroll, self.duration).or(Some(r));
        }
        self.seek(range.map_or(Time::ZERO, |r| r.start));
        self.play(PlaybackRate::FORWARD);
        self.set_range(range);
    }

    /// Shift+K: from `preroll` before the playhead to `postroll` after it, then back to where it was.
    pub fn play_around(&mut self) {
        if self.media_id.is_none() {
            return;
        }
        let here = self.position;
        let Some(range) = PlaybackBounds::play_around(here, self.preroll, self.postroll, self.duration) else { return };
        self.seek(range.start);
        self.play(PlaybackRate::FORWARD);
        self.set_range(Some(range));
        let mut b = self.bounds;
        b.return_to = Some(here);
        self.set_bounds(b);
    }

    fn position_changed(&mut self, _s: &mut EditorSession, t: Time) {
        if !self.is_playing {
            return;
        }
        let rate = self.engine.rate();
        match self.bounds.action(t, rate, self.frame_duration, self.duration) {
            PlaybackAction::Wrap(_) if self.engine_wraps_loops && self.engine.loops() => {} // the engine wraps by itself
            PlaybackAction::Wrap(to) => {
                self.position = to;
                self.model.current_time = to;
                self.engine.seek(to);
                self.engine.play(rate);
                return;
            }
            PlaybackAction::Stop(at) => {
                // Park on the last frame (the end itself is one frame past the picture).
                // Reverse playback stops on the range start itself.
                let parked = if rate.is_reverse() {
                    Time::ZERO.max(at)
                } else {
                    Time::ZERO.max(at.min(self.duration) - self.frame_duration)
                };
                self.pause();
                self.position = parked;
                self.model.current_time = parked;
                self.engine.seek(parked);
                return;
            }
            PlaybackAction::StopAndReturn(back) => {
                self.pause();
                self.set_range(None);
                self.seek(back);
                return;
            }
            PlaybackAction::None => {}
        }
        // A paused engine reports where its pause parked (the frame on the glass): that is the position.
        self.position = t;
        self.model.current_time = t;
        if self.engine.rate().is_paused() {
            self.pause();
        }
    }

    // MARK: Marks

    /// Edits the loaded clip's marks through the project rules and hands the result to the session.
    // shortcut: the Project mark rules run on a scratch project holding just this clip's marks; move them to a
    // `SourceMarks` method when the core model gets one.
    fn set_marks(&mut self, s: &mut EditorSession, body: impl FnOnce(&mut Project, Id)) {
        let Some(id) = self.media_id else { return };
        let mut p = Project::new(Id::from_u128(0), "", Vec::new(), Vec::new());
        let current = s.project().source_marks_for(id);
        if !current.is_empty() {
            p.source_marks.insert(id, current);
        }
        body(&mut p, id);
        s.set_source_marks(p.source_marks.get(&id).cloned(), id);
        self.refresh_marks(s);
    }

    /// I.
    pub fn mark_in(&mut self, s: &mut EditorSession) {
        let t = self.position;
        self.set_marks(s, |p, id| p.set_source_in(t, id));
    }
    /// O.
    pub fn mark_out(&mut self, s: &mut EditorSession) {
        let t = self.position + self.frame_duration;
        self.set_marks(s, |p, id| p.set_source_out(t, id));
    }
    /// Mark Audio In: split edit starts (the next Insert / Overwrite lays sound and picture apart).
    pub fn mark_audio_in(&mut self, s: &mut EditorSession) {
        let t = self.position;
        self.set_marks(s, |p, id| p.set_source_audio_in(t, id));
    }
    /// Mark Video In.
    pub fn mark_video_in(&mut self, s: &mut EditorSession) {
        let t = self.position;
        self.set_marks(s, |p, id| p.set_source_video_in(t, id));
    }
    /// Remove In.
    pub fn clear_in(&mut self, s: &mut EditorSession) {
        self.set_marks(s, |p, id| p.clear_source_in(id));
    }
    /// Remove Out.
    pub fn clear_out(&mut self, s: &mut EditorSession) {
        self.set_marks(s, |p, id| p.clear_source_out(id));
    }
    /// Remove In and Out.
    pub fn clear_marks(&mut self, s: &mut EditorSession) {
        self.set_marks(s, |p, id| p.clear_source_marks(id));
    }
    /// X: In at the start, Out at the end of the whole clip. The sequence's In/Out stay as they are.
    pub fn mark_clip(&mut self, s: &mut EditorSession) {
        let d = self.duration;
        self.set_marks(s, |p, id| {
            if let Some(m) = SourceMarks::whole_clip(d) {
                p.source_marks.insert(id, m);
            }
        });
    }

    // MARK: Markers (M)

    /// M: a marker on the clip at the playhead. A second M on the same frame says so (no dialog for clip markers yet).
    pub fn add_marker(&mut self, s: &mut EditorSession) {
        let Some(id) = self.media_id else {
            self.events.push(SourceCoreEvent::Status("Open a clip in the Source monitor first.".to_string()));
            return;
        };
        let Some(media) = s.project().media(id).cloned() else { return };
        let mut p = Project::new(Id::from_u128(0), "", vec![media], Vec::new());
        let Some((_, is_new)) = p.add_source_marker(self.position, self.frame_duration, id, self.ids.as_mut()) else {
            return;
        };
        if !is_new {
            self.events.push(SourceCoreEvent::Status("There is already a marker on this frame.".to_string()));
            return;
        }
        s.set_source_markers(Some(p.source_markers(id)), id);
        self.refresh_marks(s);
    }

    /// Delete Marker at the playhead.
    pub fn clear_marker_at_playhead(&mut self, s: &mut EditorSession) {
        let Some(id) = self.media_id else { return };
        let Some(media) = s.project().media(id).cloned() else { return };
        let Some(m) = s.project().source_markers(id).into_iter().find(|m| m.time == self.position) else { return };
        let mut p = Project::new(Id::from_u128(0), "", vec![media], Vec::new());
        p.remove_source_marker(m.id, id);
        s.set_source_markers(Some(p.source_markers(id)), id);
        self.refresh_marks(s);
    }

    /// Delete All Markers.
    pub fn clear_all_markers(&mut self, s: &mut EditorSession) {
        let Some(id) = self.media_id else { return };
        s.set_source_markers(None, id);
        self.refresh_marks(s);
    }

    /// Next / previous marker.
    pub fn go_to_marker(&mut self, s: &EditorSession, forward: bool) {
        let Some(id) = self.media_id else { return };
        let times: Vec<Time> = s.project().source_markers(id).iter().map(|m| m.time).collect();
        let found = if forward {
            times.iter().copied().find(|t| *t > self.position)
        } else {
            times.iter().copied().rev().find(|t| *t < self.position)
        };
        if let Some(t) = found {
            self.seek(t);
        }
    }

    // MARK: Editing

    /// Insert / Overwrite the marked range into the sequence. A four-mark edit of different lengths asks for the Fit
    /// Clip rule first (`SourceCoreEvent::ChooseFourPointFit`, then `resolve_four_point_fit`).
    pub fn edit(
        &mut self,
        s: &mut EditorSession,
        mode: ThreePointMode,
        streams: SourceStreams,
        place_on_top: bool,
        backtimed: bool,
        fit_to_fill: bool,
    ) {
        let Some(id) = self.media_id else {
            self.events.push(SourceCoreEvent::Status(
                "Open a clip in the Source monitor first (double-click it in the Project panel).".to_string(),
            ));
            return;
        };
        self.pause();
        // Four marks of different lengths: ask what decides the edit (Fit Clip); the last choice is preselected.
        if !fit_to_fill && !backtimed && s.four_point_needs_choice(id, None) && self.asks_four_point_fit {
            self.pending_edit = Some(PendingEdit { media: id, streams, mode, place_on_top });
            self.events.push(SourceCoreEvent::ChooseFourPointFit);
            return;
        }
        s.source_edit(id, None, streams, mode, place_on_top, backtimed, fit_to_fill, FourPointFit::TrimSourceEnd);
    }

    /// The answer to `ChooseFourPointFit` (`None` = canceled).
    pub fn resolve_four_point_fit(&mut self, s: &mut EditorSession, choice: Option<FourPointFitChoice>) {
        let Some(p) = self.pending_edit.take() else { return };
        let Some(choice) = choice else { return };
        s.source_edit(
            p.media,
            None,
            p.streams,
            p.mode,
            p.place_on_top,
            false,
            choice == FourPointFitChoice::ChangeSpeed,
            choice.fit().unwrap_or(FourPointFit::TrimSourceEnd),
        );
    }

    /// Replace Clip from Source: the one selected clip plays this Source clip, the frame shown here lined up with the playhead.
    pub fn replace_selected_clip(&mut self, s: &mut EditorSession) {
        let Some(id) = self.media_id else {
            self.events.push(SourceCoreEvent::Status(
                "Open a clip in the Source monitor first (double-click it in the Project panel).".to_string(),
            ));
            return;
        };
        // One clip, or a linked pair (Linked Selection selects both): the video clip, its partner follows.
        let clip = s.single_selected_clip().map(|c| c.id);
        let Some(clip) = clip else {
            self.events.push(SourceCoreEvent::Status("Select one clip in the timeline to replace.".to_string()));
            return;
        };
        self.pause();
        s.replace_media(clip, id, Some(self.position));
    }

    // MARK: Commands (keyboard focus on the Source monitor)

    /// Handles a command while the Source monitor has focus. False = not a source command, the caller runs its default.
    pub fn handle(&mut self, s: &mut EditorSession, c: EditorCommand) -> bool {
        match c {
            EditorCommand::PlayPause => self.play_pause(),
            EditorCommand::StepBackward => self.step_frames(-1),
            EditorCommand::StepForward => self.step_frames(1),
            EditorCommand::StepBackward5 => self.step_frames(-10),
            EditorCommand::StepForward5 => self.step_frames(10),
            EditorCommand::GoToStart => self.go_to_start(),
            EditorCommand::GoToEnd => self.go_to_end(),
            EditorCommand::MarkIn => self.mark_in(s),
            EditorCommand::MarkOut => self.mark_out(s),
            EditorCommand::GoToIn => self.go_to_in(s),
            EditorCommand::GoToOut => self.go_to_out(s),
            EditorCommand::ClearIn => self.clear_in(s),
            EditorCommand::ClearOut => self.clear_out(s),
            EditorCommand::ClearInOut => self.clear_marks(s),
            EditorCommand::PlayInToOut => self.play_in_to_out(s, false),
            EditorCommand::PlayInToOutRoll => self.play_in_to_out(s, true),
            EditorCommand::PlayAround => self.play_around(),
            EditorCommand::MarkClip => self.mark_clip(s),
            EditorCommand::NextMarker => self.go_to_marker(s, true),
            EditorCommand::PreviousMarker => self.go_to_marker(s, false),
            EditorCommand::ToggleLoop => self.toggle_loop(),
            EditorCommand::ShuttleReverse => self.press(ShuttleKey::J),
            EditorCommand::ShuttleStop => self.press(ShuttleKey::K),
            EditorCommand::ShuttleSlowReverse => self.nudge(false),
            EditorCommand::ShuttleSlowForward => self.nudge(true),
            EditorCommand::ShuttleForward => self.press(ShuttleKey::L),
            EditorCommand::AddMarker => self.add_marker(s),
            _ => return false,
        }
        true
    }

    // MARK: Export frame and menu

    /// Export Frame: the platform renders and writes the picture.
    pub fn export_frame(&mut self) {
        if self.media_id.is_none() {
            return;
        }
        self.pause();
        self.events.push(SourceCoreEvent::ExportFrame);
    }

    /// Make Subclip: the In/Out range becomes a Project item (refusals land in the session's status line).
    pub fn make_subclip(&mut self, s: &mut EditorSession) {
        if let Some(id) = self.media_id {
            s.make_subclip(id, None);
        }
    }

    fn run_menu(&mut self, s: &mut EditorSession, c: SourceMenuCommand) {
        use SourceMenuCommand as M;
        match c {
            M::MarkClip => self.mark_clip(s),
            M::MarkIn => self.mark_in(s),
            M::MarkOut => self.mark_out(s),
            M::MarkAudioIn => self.mark_audio_in(s),
            M::MarkVideoIn => self.mark_video_in(s),
            M::GoToIn => self.go_to_in(s),
            M::GoToOut => self.go_to_out(s),
            M::ClearIn => self.clear_in(s),
            M::ClearOut => self.clear_out(s),
            M::ClearMarks => self.clear_marks(s),
            M::AddMarker => self.add_marker(s),
            M::ClearMarkerAtPlayhead => self.clear_marker_at_playhead(s),
            M::ClearAllMarkers => self.clear_all_markers(s),
            M::Insert => self.edit(s, ThreePointMode::Insert, SourceStreams::Both, false, false, false),
            M::Overwrite => self.edit(s, ThreePointMode::Overwrite, SourceStreams::Both, false, false, false),
            M::FitToFill => self.edit(s, ThreePointMode::Overwrite, SourceStreams::Both, false, false, true),
            M::Replace => self.replace_selected_clip(s),
            M::MakeSubclip => self.make_subclip(s),
            M::ExportFrame => self.export_frame(),
            M::ToggleLoop => self.toggle_loop(),
            M::Reveal => {
                if let Some(id) = self.media_id {
                    self.events.push(SourceCoreEvent::RevealInProject(id));
                }
            }
            M::ToggleAngles => self.events.push(SourceCoreEvent::ToggleAngles),
        }
    }

    /// The right-click rows of the Source picture.
    pub fn context_menu_items(&self, s: &EditorSession) -> Vec<SQMenuItem> {
        let map = CommandMap::current();
        let mut rows: Vec<SQMenuItem> = Vec::new();
        let add = |rows: &mut Vec<SQMenuItem>,
                   title: &str,
                   enabled: bool,
                   checked: bool,
                   command: Option<EditorCommand>,
                   c: SourceMenuCommand| {
            let q = self.menu.clone();
            let mut i = SQMenuItem::new(title);
            i.shortcut = command
                .and_then(|c| map.shown_binding_here(&c))
                .map(|b| KeyBindingText::text(&b, Platform::current()))
                .unwrap_or_default();
            i.is_enabled = enabled;
            i.is_checked = checked;
            i.action = Some(Rc::new(move || q.push(c)));
            rows.push(i);
        };
        let has = self.media_id.is_some();
        let m = self.marks(s);
        if self.shows_angles_row {
            add(
                &mut rows,
                "Show All Angles",
                self.angles_available,
                self.model.angle_tiles.is_some(),
                None,
                SourceMenuCommand::ToggleAngles,
            );
            rows.push(SQMenuItem::separator());
        }
        add(&mut rows, "Mark Clip", has, false, Some(EditorCommand::MarkClip), SourceMenuCommand::MarkClip);
        add(&mut rows, "Mark In", has, false, Some(EditorCommand::MarkIn), SourceMenuCommand::MarkIn);
        add(&mut rows, "Mark Out", has, false, Some(EditorCommand::MarkOut), SourceMenuCommand::MarkOut);
        add(
            &mut rows,
            "Mark Audio In",
            has && self.duration > Time::ZERO,
            m.audio_in.is_some(),
            None,
            SourceMenuCommand::MarkAudioIn,
        );
        add(
            &mut rows,
            "Mark Video In",
            has && self.duration > Time::ZERO,
            m.video_in.is_some(),
            None,
            SourceMenuCommand::MarkVideoIn,
        );
        add(&mut rows, "Go to In", m.mark_in.is_some(), false, Some(EditorCommand::GoToIn), SourceMenuCommand::GoToIn);
        add(
            &mut rows,
            "Go to Out",
            m.mark_out.is_some(),
            false,
            Some(EditorCommand::GoToOut),
            SourceMenuCommand::GoToOut,
        );
        rows.push(SQMenuItem::separator());
        add(
            &mut rows,
            "Remove In",
            m.mark_in.is_some(),
            false,
            Some(EditorCommand::ClearIn),
            SourceMenuCommand::ClearIn,
        );
        add(
            &mut rows,
            "Remove Out",
            m.mark_out.is_some(),
            false,
            Some(EditorCommand::ClearOut),
            SourceMenuCommand::ClearOut,
        );
        add(
            &mut rows,
            "Remove In and Out",
            !m.is_empty(),
            false,
            Some(EditorCommand::ClearInOut),
            SourceMenuCommand::ClearMarks,
        );
        rows.push(SQMenuItem::separator());
        let markers = self.media_id.map(|id| s.project().source_markers(id)).unwrap_or_default();
        add(&mut rows, "Add Marker", has, false, Some(EditorCommand::AddMarker), SourceMenuCommand::AddMarker);
        if markers.iter().any(|mk| mk.time == self.position) {
            add(&mut rows, "Delete Marker", true, false, None, SourceMenuCommand::ClearMarkerAtPlayhead);
        }
        if !markers.is_empty() {
            add(&mut rows, "Delete All Markers", true, false, None, SourceMenuCommand::ClearAllMarkers);
        }
        rows.push(SQMenuItem::separator());
        add(&mut rows, "Insert", has, false, Some(EditorCommand::Insert), SourceMenuCommand::Insert);
        add(&mut rows, "Overwrite", has, false, Some(EditorCommand::Overwrite), SourceMenuCommand::Overwrite);
        add(&mut rows, "Fit to Fill", has, false, None, SourceMenuCommand::FitToFill);
        add(&mut rows, "Replace Clip from Source", has, false, None, SourceMenuCommand::Replace);
        rows.push(SQMenuItem::separator());
        add(
            &mut rows,
            "Make Subclip",
            has && !m.is_empty(),
            false,
            Some(EditorCommand::MakeSubclip),
            SourceMenuCommand::MakeSubclip,
        );
        rows.push(SQMenuItem::separator());
        add(&mut rows, "Export Frame…", has, false, Some(EditorCommand::ExportFrame), SourceMenuCommand::ExportFrame);
        add(
            &mut rows,
            "Loop Playback",
            true,
            self.bounds.loop_playback,
            Some(EditorCommand::ToggleLoop),
            SourceMenuCommand::ToggleLoop,
        );
        rows.push(SQMenuItem::separator());
        let mut zoom = SQMenuItem::new("Zoom");
        zoom.submenu = Some(self.model.zoom_menu());
        rows.push(zoom);
        if has {
            rows.push(SQMenuItem::separator());
            add(&mut rows, "Reveal in Project", true, false, None, SourceMenuCommand::Reveal);
        }
        rows
    }
}
