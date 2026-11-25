// Swift: EditorSession.swift (stored state, lifecycle, perform / undo core)
//! The `EditorSession` struct: every stored property of the Swift class, the change counters and the undo core
//! (`perform`, `end_gesture`, `register_side_step`, `undo`, `redo`). The rest of the Swift class lives in the
//! `esNN_*` modules as `impl EditorSession` blocks.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use sq_core_color::ProjectGradeLinksExt as _;
use sq_core_edit::history::History;
use sq_core_edit::playback_bounds::PlaybackBounds;
use sq_core_edit::timeline_clipboard::TimelineClipboard;
use sq_core_edit::timeline_edits::TimelineEditsExt as _;
use sq_core_edit::timeline_follow_selection::PlayheadFollow;
use sq_core_edit::timeline_solo_views::ColorSourceFileView;
use sq_core_effects::adjustment_extend::ProjectAdjustmentExtendExt as _;
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::{
    ClipEdge, ClipEffect, CowVec, MediaInfo, MediaRef, Project, ProjectLiveDucking, RenderCacheSpan, SequenceFormat,
    Timeline, TimelineEditMode, VideoTrackInfo,
};
use sq_core_project::recovery::{AutosavePolicy, AutosaveStore};
use sq_core_time::{Id, IdSource, Time, TimeRange, Timestamp};
use sq_library::media_file_stamp::MediaFileStampTracker;
use sq_playback::engine::preview_rate::PreviewRate;
use sq_runtime::JoinHandle;

use crate::{
    BuiltInClipboard, Change, ColorMattePreview, DetectedColor, GraphicLayerSelection, LineKeyRef, MediaDiskTracker,
    MediaPolicyDefaults, ProgramEngine, ProjectSaveQueue, SequenceTabs, SessionEvent, SessionMediaResolving,
    SessionProxyServing, SessionRenderCaching,
};

/// Why a save did not happen (Swift `EditorSession.SaveError`).
// Swift: EditorSession.swift:17
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveError {
    NoFileURL,
    ProjectChanged,
}

impl fmt::Display for SaveError {
    // Swift: EditorSession.swift:19
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            SaveError::NoFileURL => "The project has no file yet.",
            SaveError::ProjectChanged => "Another project was opened while saving.",
        })
    }
}

impl std::error::Error for SaveError {}

/// Playhead before and after an undo step that moved it, in the sequence it belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlayheadStep {
    pub timeline: Id,
    pub before: Time,
    pub after: Time,
}

/// The effect of an undo step outside the project (Magic mask frames deleted from the matte store). The closures
/// capture shared stores (`Arc`), never the session or the app. Several side steps of one undo step run as one:
/// undo newest first, redo oldest first.
pub struct SideStep(SideStepKind);

enum SideStepKind {
    One { undo: Box<dyn FnMut()>, redo: Box<dyn FnMut()> },
    Many(Vec<SideStep>),
}

impl SideStep {
    pub fn new(undo: impl FnMut() + 'static, redo: impl FnMut() + 'static) -> SideStep {
        SideStep(SideStepKind::One { undo: Box::new(undo), redo: Box::new(redo) })
    }

    /// The steps as one, `steps` oldest first.
    pub fn joined(steps: Vec<SideStep>) -> SideStep {
        SideStep(SideStepKind::Many(steps))
    }

    pub fn undo(&mut self) {
        match &mut self.0 {
            SideStepKind::One { undo, .. } => undo(),
            SideStepKind::Many(steps) => steps.iter_mut().rev().for_each(SideStep::undo),
        }
    }

    pub fn redo(&mut self) {
        match &mut self.0 {
            SideStepKind::One { redo, .. } => redo(),
            SideStepKind::Many(steps) => steps.iter_mut().for_each(SideStep::redo),
        }
    }
}

/// Where the last Cmd+K cut happened (Swift's `lastCutPoint` tuple).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CutPoint {
    pub timeline: Id,
    pub time: Time,
    pub depth: usize,
}

/// The sequence the engine was last given and every sequence reachable from it (Swift's `pushed` tuple).
#[derive(Clone, Debug, PartialEq)]
pub struct PushedTimeline {
    pub timeline: Timeline,
    pub sequences: BTreeMap<Id, Timeline>,
}

/// Probe of a file's media info, run on a worker (Swift's `@Sendable (URL) async -> MediaInfo?`).
pub type MediaInfoProbe = Arc<dyn Fn(&Path) -> Option<MediaInfo> + Send + Sync>;
/// Color detection of a file, run on a worker (Swift's `colorDetector`).
pub type ColorDetector = Arc<dyn Fn(&Path) -> Option<DetectedColor> + Send + Sync>;
/// The synchronous format question (Swift `confirmFormatChange`): true = adopt the clip's format.
pub type ConfirmFormatChange = Box<dyn FnMut(&SequenceFormat, &SequenceFormat) -> bool>;

/// One listing of a project's autosave folder and when it was read (`EditorSession::autosave_versions`).
pub(crate) struct AutosaveListing {
    pub(crate) at: std::time::Instant,
    /// `EditorSession::autosave_generation` when the folder was read: a newer one means the app changed the folder since.
    pub(crate) generation: u64,
    pub(crate) project: sq_core_time::Id,
    pub(crate) versions: Vec<sq_core_project::recovery::AutosaveVersion>,
}

/// The editing document: one project with undo history, the active sequence, playhead, selection, file state and the
/// Program engine. Every edit goes through [`EditorSession::perform`] (one undo step each); after each commit, undo
/// and redo the active timeline is pushed to the engine with `set_timeline`.
///
/// Fields are `pub(crate)` so every ES module reaches them; the public surface is methods (getters and setters of
/// the Swift `public var`s are ES1's, listed in TASKS.md). Swift `@ObservationIgnored`
/// fields need no version bump; all others are covered by `notify`.
// Swift: EditorSession.swift:16
// shortcut: skeleton state the ES groups read; drop the allow when TASKS.md shows no pending! left.
#[allow(dead_code)]
pub struct EditorSession {
    /// Longest UI frame (microseconds) the window loop reported since the Auto quality governor last asked.
    present_stall_micros: AtomicU64,
    pub(crate) history: History<Project>,
    pub(crate) file_url: Option<PathBuf>,
    pub(crate) active_timeline_id: Option<Id>,
    /// The format variant the Program monitor shows per sequence (view state: not undoable, saved with the project).
    pub(crate) active_variants: BTreeMap<Id, Id>,
    pub(crate) sequence_tabs: SequenceTabs,
    pub(crate) playhead: Time,
    /// Playhead records of undo steps that moved it, keyed by the undo depth the step produced.
    pub(crate) playhead_steps: BTreeMap<usize, PlayheadStep>,
    /// Playhead records of the redo steps the running gesture replaced: back with them when it is canceled.
    pub(crate) held_playhead_steps: BTreeMap<usize, PlayheadStep>,
    /// Side steps by the tag of the history step they belong to.
    pub(crate) side_steps: BTreeMap<Id, SideStep>,
    /// Set through `set_selection_raw` only: Swift's `didSet` clears `selected_line_keys` on a change.
    pub(crate) selection: BTreeSet<Id>,
    pub(crate) selected_line_keys: BTreeSet<LineKeyRef>,
    pub(crate) linked_selection: bool,
    pub(crate) selection_follows_playhead: bool,
    /// Preference "Use proxies when exporting", copied into the export snapshot.
    pub(crate) use_proxies_for_export: bool,
    pub(crate) follow_state: Option<PlayheadFollow>,
    pub(crate) follow_pending: bool,
    pub(crate) follow_task: Option<JoinHandle<()>>,
    /// Clock reading (`sq_runtime::Clock::now`) when the deferred follow evaluation is due.
    pub(crate) follow_deadline: Duration,
    pub(crate) follow_last_step: Option<Duration>,
    pub(crate) follow_was_playing: bool,
    pub(crate) follow_settle: Duration,
    pub(crate) follow_step_run: Duration,
    pub(crate) follow_evaluations: i64,
    pub(crate) keep_attached_held: bool,
    pub(crate) new_sequence_edit_mode: TimelineEditMode,
    pub(crate) place_sequences_as_clips: bool,
    pub(crate) caption_selection: BTreeSet<Id>,
    pub(crate) caption_track_focus: Option<Id>,
    pub(crate) graphic_layer_selection: Option<GraphicLayerSelection>,
    /// Counts the changes of `graphic_layer_selection`, which posts no `Change`: hosts key their follow-up on it.
    pub(crate) graphic_layer_selection_version: u64,
    pub(crate) selected_transition: Option<Id>,
    pub(crate) clipboard: Option<TimelineClipboard>,
    /// Set through a setter: Swift's `didSet` clears `built_in_clipboard` when it gets a value.
    pub(crate) effect_clipboard: Option<ClipEffect>,
    pub(crate) built_in_clipboard: Option<BuiltInClipboard>,
    pub(crate) effect_defaults: EffectDefaults,
    pub(crate) is_playing: bool,
    /// Set through a setter: Swift's `didSet` passes range and loop on to the engine.
    pub(crate) bounds: PlaybackBounds,
    pub(crate) last_autosave: Option<Timestamp>,
    pub(crate) last_error: Option<String>,
    /// Counts every `set_error`, so the status line can tell a message raised again from one that is still standing.
    pub(crate) error_serial: u64,
    pub(crate) engine: Box<dyn ProgramEngine>,
    pub(crate) pushed_live_ducking: Option<ProjectLiveDucking>,
    pub(crate) cut_out_start: Option<Time>,
    pub(crate) last_cut_point: Option<CutPoint>,
    pub(crate) media: Arc<dyn SessionMediaResolving>,
    pub(crate) auto_proxy: Option<Box<dyn SessionProxyServing>>,
    /// Extra monitors (the Trim monitor's engines); dead ones (`is_alive` false) are dropped when one is added.
    pub(crate) auxiliary_engines: Vec<Box<dyn ProgramEngine>>,
    pub(crate) autosave_store: AutosaveStore,
    /// The last folder listing of `autosave_versions`: the menus ask on every frame and a listing is file IO.
    pub(crate) autosave_listing: std::sync::Mutex<Option<AutosaveListing>>,
    /// Bumped whenever the app writes or deletes an autosave (also from the recovery snapshot worker), so a listing read
    /// before that is never served again; the time window only covers changes from outside.
    pub(crate) autosave_generation: Arc<std::sync::atomic::AtomicU64>,
    pub(crate) save_queue: ProjectSaveQueue,
    pub(crate) clock: Box<dyn Fn() -> Timestamp>,
    pub(crate) confirm_format_change: Option<ConfirmFormatChange>,
    pub(crate) force_dirty: bool,
    /// Set through a setter: Swift's `didSet` pushes the timeline and notifies.
    pub(crate) color_solo_clip: Option<Id>,
    pub(crate) color_source_view: Option<ColorSourceFileView>,
    /// Set through a setter: Swift's `didSet` pushes the timeline and notifies.
    pub(crate) color_matte_preview: Option<ColorMattePreview>,
    pub(crate) pushed_matte: Option<ColorMattePreview>,
    pub(crate) pushed_solo: Option<Id>,
    pub(crate) pushed_solo_picture: Option<VideoTrackInfo>,
    pub(crate) pushed_solo_still_size: Option<Vec<i64>>,
    pub(crate) pushed_cache_spans: Vec<RenderCacheSpan>,
    pub(crate) render_cache: Option<Box<dyn SessionRenderCaching>>,
    pub(crate) pushed: Option<PushedTimeline>,
    pub(crate) media_snapshot: CowVec<MediaRef>,
    pub(crate) rendered_infos: BTreeMap<Id, Option<MediaInfo>>,
    pub(crate) requested_media: BTreeSet<Id>,
    pub(crate) disk_tracker: MediaDiskTracker,
    pub(crate) disk_refresh_running: bool,
    pub(crate) grow_tracker: MediaFileStampTracker,
    pub(crate) grow_quiet_polls: i64,
    pub(crate) grow_poll_running: bool,
    pub(crate) gesture_counter: i64,
    pub(crate) speed_gesture_key: Option<String>,
    pub(crate) stabilizer_replan_task: Option<JoinHandle<()>>,
    pub(crate) queued_stabilizer_analysis: BTreeMap<Id, BTreeSet<Id>>,
    pub(crate) rolling_shutter_requests: BTreeMap<Id, BTreeSet<Id>>,
    pub(crate) autosave_task: Option<JoinHandle<()>>,
    pub(crate) reveal_range: Option<TimeRange>,
    pub(crate) media_policy_defaults: Box<dyn Fn() -> MediaPolicyDefaults>,
    pub(crate) skim_time: Option<Time>,
    pub(crate) preview_rate: PreviewRate,
    pub(crate) salvaged_from: Option<PathBuf>,
    /// What the repair of `salvaged_from` left out; the shell's after-open step tells the user.
    pub(crate) salvage_report: Option<sq_core_file::ProjectSalvageReport>,
    pub(crate) media_info_probe: MediaInfoProbe,
    pub(crate) color_detector: ColorDetector,
    // Rust only: ids for new tags and edits (Swift calls `UUID()`), the change counters and the event outbox.
    pub ids: Box<dyn IdSource>,
    pub(crate) versions: [u64; Change::COUNT],
    pub(crate) pending_changes: Change,
    pub(crate) events: Vec<SessionEvent>,
}

/// The collaborators of a session (the Swift initializer's parameters after `project`). [`SessionDeps::headless`]
/// gives the Swift defaults that need no platform: stub engine, ref-only resolver, project-file queue.
pub struct SessionDeps {
    pub file_url: Option<PathBuf>,
    pub engine: Box<dyn ProgramEngine>,
    pub media: Arc<dyn SessionMediaResolving>,
    pub save_queue: ProjectSaveQueue,
    pub autosave_store: AutosaveStore,
    pub clock: Box<dyn Fn() -> Timestamp>,
    pub ids: Box<dyn IdSource>,
}

impl SessionDeps {
    /// Stub engine, `RefOnlyMediaResolver`, `ProjectFile` save queue, autosaves under `autosave_base`, clock at the
    /// reference date, sequential ids.
    pub fn headless(autosave_base: PathBuf) -> SessionDeps {
        SessionDeps {
            file_url: None,
            engine: Box::new(crate::StubProgramEngine::new()),
            media: Arc::new(crate::RefOnlyMediaResolver::new()),
            save_queue: ProjectSaveQueue::new(),
            autosave_store: AutosaveStore::new(autosave_base, AutosavePolicy::default()),
            clock: Box::new(|| Timestamp::from_reference_seconds(0.0)),
            // shortcut: sequential ids for headless sessions (tests); the app sets `RandomIds` in `deps.ids`.
            ids: Box::new(sq_core_time::SequentialIds::default()),
        }
    }
}

impl SessionDeps {
    /// The clock reads the system time: autosave names and the crash marker need the real time.
    pub fn with_wall_clock(mut self) -> SessionDeps {
        self.clock = Box::new(|| {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
            Timestamp::from_unix_seconds(now.map(|d| d.as_secs_f64()).unwrap_or(0.0))
        });
        self
    }
}

impl EditorSession {
    /// Opens `project` (Swift `init`). The active sequence is the project's saved one, else the first.
    // Swift: EditorSession.swift:272
    pub fn new(project: Project, deps: SessionDeps) -> EditorSession {
        let active_timeline_id = project.active_timeline.or_else(|| Self::pickable_first(&project));
        let active_variants = project.active_variants.clone();
        let media_snapshot = CowVec::new();
        let mut session = EditorSession {
            present_stall_micros: AtomicU64::new(0),
            history: History::with_default_limit(project),
            file_url: deps.file_url,
            active_timeline_id,
            active_variants,
            sequence_tabs: SequenceTabs::default(),
            playhead: Time::ZERO,
            playhead_steps: BTreeMap::new(),
            held_playhead_steps: BTreeMap::new(),
            side_steps: BTreeMap::new(),
            selection: BTreeSet::new(),
            selected_line_keys: BTreeSet::new(),
            linked_selection: true,
            selection_follows_playhead: true,
            use_proxies_for_export: false,
            follow_state: None,
            follow_pending: false,
            follow_task: None,
            follow_deadline: Duration::ZERO,
            follow_last_step: None,
            follow_was_playing: false,
            follow_settle: Duration::from_millis(90),
            follow_step_run: Duration::from_millis(200),
            follow_evaluations: 0,
            keep_attached_held: false,
            new_sequence_edit_mode: TimelineEditMode::Normal,
            place_sequences_as_clips: false,
            caption_selection: BTreeSet::new(),
            caption_track_focus: None,
            graphic_layer_selection: None,
            graphic_layer_selection_version: 0,
            selected_transition: None,
            clipboard: None,
            effect_clipboard: None,
            built_in_clipboard: None,
            effect_defaults: EffectDefaults::default(),
            is_playing: false,
            bounds: PlaybackBounds::default(),
            last_autosave: None,
            last_error: None,
            error_serial: 0,
            engine: deps.engine,
            pushed_live_ducking: None,
            cut_out_start: None,
            last_cut_point: None,
            media: deps.media,
            auto_proxy: None,
            auxiliary_engines: Vec::new(),
            autosave_store: deps.autosave_store,
            autosave_listing: std::sync::Mutex::new(None),
            autosave_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            save_queue: deps.save_queue,
            clock: deps.clock,
            confirm_format_change: None,
            force_dirty: false,
            color_solo_clip: None,
            color_source_view: None,
            color_matte_preview: None,
            pushed_matte: None,
            pushed_solo: None,
            pushed_solo_picture: None,
            pushed_solo_still_size: None,
            pushed_cache_spans: Vec::new(),
            render_cache: None,
            pushed: None,
            media_snapshot,
            rendered_infos: BTreeMap::new(),
            requested_media: BTreeSet::new(),
            disk_tracker: MediaDiskTracker::default(),
            disk_refresh_running: false,
            grow_tracker: MediaFileStampTracker::new(),
            grow_quiet_polls: 0,
            grow_poll_running: false,
            gesture_counter: 0,
            speed_gesture_key: None,
            stabilizer_replan_task: None,
            queued_stabilizer_analysis: BTreeMap::new(),
            rolling_shutter_requests: BTreeMap::new(),
            autosave_task: None,
            reveal_range: None,
            media_policy_defaults: Box::new(MediaPolicyDefaults::default),
            skim_time: None,
            preview_rate: PreviewRate::NORMAL,
            salvaged_from: None,
            salvage_report: None,
            // Off the Mac nothing is probed yet (Swift's `#else` branch); `install_color_detector` replaces it.
            media_info_probe: Arc::new(|_| None),
            color_detector: Arc::new(|_| None),
            ids: deps.ids,
            versions: [0; Change::COUNT],
            pending_changes: Change::empty(),
            events: Vec::new(),
        };
        session.media.set_project_folder(session.file_url.as_deref().and_then(Path::parent).map(Path::to_path_buf));
        if let Some(id) = session.active_timeline_id {
            session.sequence_tabs.open(id);
        }
        session.begin_marker();
        session.sync_media();
        // Swift's `syncStyleKit()` is not ported: captions render through `CaptionLookRegistry::library_for_project`, per project.
        session.push_timeline(true);
        session
    }

    fn pickable_first(project: &Project) -> Option<Id> {
        project.pickable_timelines().next().map(|t| t.id)
    }

    // MARK: Read access

    /// The current project (the history's present state).
    // Swift: EditorSession.swift:261
    pub fn project(&self) -> &Project {
        self.history.current()
    }
    // Swift: EditorSession.swift:263
    pub fn is_dirty(&self) -> bool {
        self.history.is_dirty() || self.force_dirty
    }
    // Swift: EditorSession.swift:264
    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }
    // Swift: EditorSession.swift:265
    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }
    // Swift: EditorSession.swift:266
    pub fn undo_name(&self) -> Option<&str> {
        self.history.undo_name()
    }
    // Swift: EditorSession.swift:267
    pub fn redo_name(&self) -> Option<&str> {
        self.history.redo_name()
    }
    // Swift: EditorSession.swift:268
    pub fn active_timeline(&self) -> Option<&Timeline> {
        self.active_timeline_id.and_then(|id| self.project().timeline(id))
    }
    /// The file name without extension, else the project name.
    // Swift: EditorSession.swift:269
    pub fn display_name(&self) -> String {
        match self.file_url.as_deref().and_then(Path::file_stem) {
            Some(stem) => stem.to_string_lossy().into_owned(),
            None => self.project().name.clone(),
        }
    }
    pub fn history(&self) -> &History<Project> {
        &self.history
    }
    pub fn file_url(&self) -> Option<&Path> {
        self.file_url.as_deref()
    }
    pub fn active_timeline_id(&self) -> Option<Id> {
        self.active_timeline_id
    }
    pub fn playhead(&self) -> Time {
        self.playhead
    }
    pub fn selection(&self) -> &BTreeSet<Id> {
        &self.selection
    }
    pub fn caption_selection(&self) -> &BTreeSet<Id> {
        &self.caption_selection
    }
    /// The window loop reports a UI frame (acquire, draw and present) that took `took`: a stall the engine's counters cannot
    /// see. The Auto quality governor reads it with `take_present_stall`.
    pub fn note_present_stall(&self, took: Duration) {
        let micros = u64::try_from(took.as_micros()).unwrap_or(u64::MAX);
        self.present_stall_micros.fetch_max(micros, Ordering::Relaxed);
    }

    /// The longest reported UI frame since the last call, if any.
    pub fn take_present_stall(&self) -> Option<Duration> {
        match self.present_stall_micros.swap(0, Ordering::Relaxed) {
            0 => None,
            micros => Some(Duration::from_micros(micros)),
        }
    }
    pub fn is_playing(&self) -> bool {
        self.is_playing
    }
    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    /// How many errors the session has raised. A message that is set again (same text) raises this, so the status
    /// line shows it again; `last_error` itself stays set until something clears it.
    pub fn error_serial(&self) -> u64 {
        self.error_serial
    }
    pub fn reveal_range(&self) -> Option<TimeRange> {
        self.reveal_range
    }
    /// The Program engine (tests downcast it with `as_any`).
    pub fn engine(&self) -> &dyn ProgramEngine {
        self.engine.as_ref()
    }
    /// The Program engine for the app's frame pump and hosts (Swift's `engine` is a class reference).
    pub fn engine_mut(&mut self) -> &mut dyn ProgramEngine {
        self.engine.as_mut()
    }
    /// The selected transition, if any (Swift `selectedTransition`).
    pub fn selected_transition(&self) -> Option<Id> {
        self.selected_transition
    }

    // MARK: Changes and events

    /// Records what changed: bumps the version of every flag and keeps the flags until `take_changes`.
    // Swift: EditorSession.swift:349
    pub fn notify(&mut self, c: Change) {
        // Like Swift: transport changes are seen before every notification (a stop evaluates the follow once).
        self.follow_transport_changed();
        for i in c.indices() {
            self.versions[i] += 1;
        }
        self.pending_changes |= c;
    }

    /// The flags notified since the last call (what Swift's `onChange` delivered), cleared.
    pub fn take_changes(&mut self) -> Change {
        std::mem::take(&mut self.pending_changes)
    }

    /// Version counter of one flag (`Change::PLAYHEAD`); 0 for an empty or combined value. Caches key on it.
    pub fn version(&self, flag: Change) -> u64 {
        flag.index().map_or(0, |i| self.versions[i])
    }

    /// All version counters, indexed like the flags.
    pub fn versions(&self) -> &[u64; Change::COUNT] {
        &self.versions
    }

    /// The hook calls since the last call, in order.
    pub fn take_events(&mut self) -> Vec<SessionEvent> {
        std::mem::take(&mut self.events)
    }

    pub(crate) fn emit(&mut self, event: SessionEvent) {
        self.events.push(event);
    }

    #[allow(dead_code)] // shortcut: first callers come with ES1-ES10
    /// The status line message (Swift `setError`, localized there; the UI localizes here).
    // Swift: EditorSession.swift:960
    pub fn set_error(&mut self, message: impl Into<String>) {
        self.last_error = Some(message.into());
        self.error_serial = self.error_serial.wrapping_add(1);
        self.notify(Change::STATUS);
    }

    #[allow(dead_code)] // shortcut: first callers come with ES1 (set_selection)
    /// Replaces the selection; a change clears the selected line keys (Swift `selection.didSet`).
    pub(crate) fn set_selection_raw(&mut self, clips: BTreeSet<Id>) {
        if clips != self.selection && !self.selected_line_keys.is_empty() {
            self.selected_line_keys.clear();
        }
        self.selection = clips;
    }

    // MARK: Editing

    /// One undo step. `key`: consecutive edits with the same key merge into one step.
    // Swift: EditorSession.swift:356
    pub fn perform(&mut self, name: &str, key: Option<&str>, edit: impl FnOnce(&mut Project)) {
        let r: Result<(), std::convert::Infallible> = self.try_perform(name, key, |p| {
            edit(p);
            Ok(())
        });
        let Ok(()) = r;
    }

    /// `perform` for an edit that can fail (Swift `rethrows`): an error leaves the project untouched and is returned.
    pub fn try_perform<E>(
        &mut self,
        name: &str,
        key: Option<&str>,
        edit: impl FnOnce(&mut Project) -> Result<(), E>,
    ) -> Result<(), E> {
        let depth = self.history.undo_depth();
        let ids = &mut *self.ids;
        self.history.try_commit_coalescing(name, key, |p| Self::perform_steps(p, ids, edit))?;
        // A new step replaces the redo steps: their playhead records go with them. A gesture keeps them aside while it
        // can still be canceled; canceled back to its start, Redo is what it was before, playhead records included.
        let now = self.history.undo_depth();
        if now > depth {
            self.held_playhead_steps = if self.history.holds_redo() {
                self.playhead_steps.iter().filter(|(k, _)| **k >= now).map(|(k, v)| (*k, *v)).collect()
            } else {
                BTreeMap::new()
            };
            self.playhead_steps.retain(|k, _| *k < now);
        } else if now < depth {
            self.playhead_steps.retain(|k, _| *k <= now);
            if self.history.can_redo() {
                let held = std::mem::take(&mut self.held_playhead_steps);
                self.playhead_steps.extend(held);
            }
            self.held_playhead_steps.clear();
        }
        self.settle_side_steps();
        self.prune_side_steps();
        self.project_did_change();
        Ok(())
    }

    /// The project `perform` would produce, without committing anything (edit API dry run): same extra steps.
    // Swift: EditorSession.swift:412
    pub fn preview_perform<E>(&self, edit: impl FnOnce(&mut Project) -> Result<(), E>) -> Result<Project, E> {
        let mut p = self.history.current().clone();
        let mut ids = sq_core_time::SequentialIds::default();
        Self::perform_steps(&mut p, &mut ids, edit)?;
        Ok(p)
    }

    fn perform_steps<E>(
        p: &mut Project,
        ids: &mut dyn IdSource,
        edit: impl FnOnce(&mut Project) -> Result<(), E>,
    ) -> Result<(), E> {
        let before = p.clone();
        edit(p)?;
        // An edited member's grade goes to the clips linked with it, in the same undo step.
        p.propagate_grade_links(&before, ids);
        // Adjustment Layers with "Extend to sequence end" follow the cut, in the same undo step.
        p.extend_adjustment_layers_to_sequence_end(&mut |tl, id, by| {
            let _ = tl.trim(id, ClipEdge::Tail, by);
        });
        // ES5: token-bound text clips take the kit's current values (Swift `resolveStyleTokens`).
        sq_text::style_kit_text::ProjectTextExt::resolve_text_tokens(p);
        p.apply_pending_scale_migration();
        Ok(())
    }

    /// A drag ended (mouse up): its undo step is final; the next edit starts a step of its own.
    // Swift: EditorSession.swift:379
    pub fn end_gesture(&mut self) {
        self.history.end_coalescing();
        self.held_playhead_steps.clear();
        self.prune_side_steps();
    }

    /// Current undo depth: take it before an edit, hand it to `register_side_step` after.
    // Swift: EditorSession.swift:386
    pub fn undo_step_depth(&self) -> usize {
        self.history.undo_depth()
    }

    /// Renames the undo steps made since `depth` (from `undo_step_depth`); returns how many.
    pub fn rename_steps_since(&mut self, depth: usize, name: &str) -> usize {
        self.history.rename_steps_since(depth, name)
    }

    /// Ties `undo` / `redo` (a change outside the project) to the undo step the edit since `depth` made, so it is ONE
    /// step; an edit that made none gets a named step of its own. The project counts as changed.
    // Swift: EditorSession.swift:391
    pub fn register_side_step(
        &mut self,
        name: &str,
        depth: usize,
        undo: impl FnMut() + 'static,
        redo: impl FnMut() + 'static,
    ) {
        let tag = self.ids.next_id();
        let mut step = SideStep::new(undo, redo);
        // The step may already carry one (a second frame delete of one drag): both run, as one, in order.
        // Replacing the tag alone would lose the first without ever running it.
        if self.history.undo_depth() > depth
            && let Some(held) = self.history.undo_tag()
            && let Some(first) = self.side_steps.remove(&held)
        {
            step = SideStep::joined(vec![first, step]);
        }
        if !(self.history.undo_depth() > depth && self.history.tag_newest_step(tag)) {
            self.history.push_marker(name, tag);
            let now = self.history.undo_depth();
            self.playhead_steps.retain(|k, _| *k < now); // Redo is gone, so are its playhead records
        }
        self.side_steps.insert(tag, step);
        self.force_dirty = true;
        self.prune_side_steps();
        self.project_did_change();
    }

    /// Undoes one step with its side step. Returns false when there is nothing to undo.
    // Swift: EditorSession.swift:463
    pub fn undo(&mut self) -> bool {
        let before = self.active_timeline().cloned();
        let step = self.playhead_steps.get(&self.history.undo_depth()).copied();
        let tag = self.history.undo_tag();
        if !self.history.undo() {
            return false;
        }
        if let Some(side) = tag.and_then(|t| self.side_steps.get_mut(&t)) {
            side.undo();
            self.force_dirty = true;
        }
        self.last_cut_point = None; // the next cut is not "the second of two" any more
        self.project_did_change();
        let to = step.filter(|s| Some(s.timeline) == self.active_timeline_id).map(|s| s.before);
        self.after_undo_redo(before.as_ref(), to);
        true
    }

    /// Redoes one step with its side step. Returns false when there is nothing to redo.
    // Swift: EditorSession.swift:478
    pub fn redo(&mut self) -> bool {
        let before = self.active_timeline().cloned();
        let tag = self.history.redo_tag();
        if !self.history.redo() {
            return false;
        }
        if let Some(side) = tag.and_then(|t| self.side_steps.get_mut(&t)) {
            side.redo();
            self.force_dirty = true;
        }
        self.last_cut_point = None;
        self.project_did_change();
        let step = self.playhead_steps.get(&self.history.undo_depth()).copied();
        let to = step.filter(|s| Some(s.timeline) == self.active_timeline_id).map(|s| s.after);
        self.after_undo_redo(before.as_ref(), to);
        true
    }

    /// Settles what `History` took out of the stack without undoing it: side steps of withdrawn steps are reverted
    /// now, newest first; side steps of folded steps become one step of the merged undo step.
    pub(crate) fn settle_side_steps(&mut self) {
        for tag in self.history.take_withdrawn_tags() {
            if let Some(mut side) = self.side_steps.remove(&tag) {
                side.undo();
                self.force_dirty = true;
            }
        }
        let folded: Vec<SideStep> =
            self.history.take_folded_tags().into_iter().filter_map(|t| self.side_steps.remove(&t)).collect();
        if folded.is_empty() {
            return;
        }
        let tag = self.ids.next_id();
        if !self.history.tag_newest_step(tag) {
            return;
        }
        self.side_steps.insert(tag, SideStep::joined(folded));
    }

    pub(crate) fn prune_side_steps(&mut self) {
        if self.side_steps.is_empty() {
            return;
        }
        let live = self.history.live_tags();
        self.side_steps.retain(|k, _| live.contains(k));
    }

    /// Gives the engine the active sequence and every sequence it can reach.
    // Swift: EditorSession.swift:752
    pub(crate) fn push_timeline(&mut self, force: bool) {
        let ducking = self.project().live_ducking.clone();
        if force || self.pushed_live_ducking != ducking {
            self.pushed_live_ducking = ducking.clone();
            self.engine.set_project_live_ducking(ducking);
        }
        use sq_core_graphics::format_variants_view::ProjectVariantsExt;
        let view = self.active_timeline_id.and_then(|id| self.project().variant_view(id, self.active_variant_id()));
        let Some(view) = view else {
            self.pushed = None;
            return;
        };
        let next = PushedTimeline { timeline: view.timeline, sequences: view.sequences };
        use sq_core_edit::timeline_solo_views::TimelineSoloExt;
        let matte = self.color_matte_preview;
        let solo = self.color_solo_clip;
        // Raw file + grade only (the Color solo shows the raw source plus its grade): the file's own size and rate when
        // probed, so probe info arriving later (relink, background probe) refreshes the solo too.
        let solo_clip =
            solo.and_then(|id| next.timeline.tracks.iter().find_map(|tr| tr.clips().iter().find(|c| c.id == id)));
        let picture = solo_clip
            .and_then(|c| self.project().media(c.media))
            .and_then(|m| m.info.as_ref())
            .and_then(|i| i.video.clone());
        let still_size = solo_clip.and_then(|c| self.project().picture_size(c)).map(|(w, h)| vec![w, h]);
        // Cached heavy segments playback reads instead of the clips; not with the solo or matte views (they show other pictures).
        let spans = if solo.is_none() && matte.is_none() {
            match self.render_cache.as_mut() {
                Some(rc) => rc.spans(&next.timeline, &next.sequences),
                None => Vec::new(),
            }
        } else {
            Vec::new()
        };
        if !force
            && self.pushed.as_ref() == Some(&next)
            && self.pushed_solo == solo
            && self.pushed_solo_picture == picture
            && self.pushed_solo_still_size == still_size
            && self.pushed_matte == matte
            && self.pushed_cache_spans == spans
        {
            return;
        }
        self.pushed_cache_spans = spans.clone();
        self.pushed_matte = matte;
        self.pushed_solo = solo;
        self.pushed_solo_picture = picture.clone();
        self.pushed_solo_still_size = still_size.clone();
        let before = self.color_source_view.as_ref().map(|v| (v.clip_id, v.position));
        // The engine sees the sequence with the matte view substituted; `pushed` keeps the real one.
        let (shown, shown_nested): (Timeline, BTreeMap<Id, Timeline>) = match &matte {
            Some(m) => (
                crate::es04_effects::showing_matte(&next.timeline, m),
                next.sequences.iter().map(|(k, t)| (*k, crate::es04_effects::showing_matte(t, m))).collect(),
            ),
            None => (next.timeline.clone(), next.sequences.clone()),
        };
        let file_view =
            solo.and_then(|id| shown.color_source_file_view(id, self.playhead, picture.as_ref(), &mut *self.ids));
        match (solo, file_view) {
            (Some(solo), Some(mut v)) => {
                let kept = before.filter(|(clip, _)| *clip == solo);
                if let Some((_, kept_at)) = kept {
                    // An edit of the graded clip keeps the file frame.
                    let fd = v.timeline.format.frame_duration;
                    let last = (v.timeline.duration() - fd).max(Time::ZERO);
                    v.position = sq_core_model::floored_to_frame(kept_at.min(last), fd);
                } else {
                    self.stop_for_viewer_switch();
                }
                let moved = before != Some((solo, v.position));
                self.engine.set_timeline(&v.timeline, &shown_nested);
                let position = v.position;
                self.color_source_view = Some(v);
                if moved {
                    self.engine.seek(position);
                }
            }
            (solo, _) => {
                self.color_source_view = None;
                if before.is_some() {
                    self.stop_for_viewer_switch();
                }
                let mut engine_timeline = match solo {
                    Some(id) => shown.soloing_video_clip(id, still_size.as_deref().map(|s| (s[0], s[1]))),
                    None => shown,
                };
                engine_timeline.render_cache_spans = spans;
                self.engine.set_timeline(&engine_timeline, &shown_nested);
                if before.is_some() {
                    self.engine.seek(self.playhead);
                }
            }
        }
        self.pushed = Some(next);
    }
}

impl fmt::Debug for EditorSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EditorSession")
            .field("project", &self.project().name)
            .field("file_url", &self.file_url)
            .field("active_timeline_id", &self.active_timeline_id)
            .field("playhead", &self.playhead)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EngineCall, StubProgramEngine};
    use std::cell::RefCell;
    use std::rc::Rc;

    fn session() -> EditorSession {
        let mut ids = sq_core_time::SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-editor-session-tests"));
        deps.ids = Box::new(ids);
        EditorSession::new(project, deps)
    }

    fn stub(s: &EditorSession) -> &StubProgramEngine {
        s.engine().as_any().downcast_ref::<StubProgramEngine>().unwrap_or_else(|| panic!("stub engine"))
    }

    #[test]
    fn new_session_pushes_the_first_sequence() {
        let s = session();
        assert!(s.active_timeline().is_some());
        assert_eq!(stub(&s).calls, vec![EngineCall::SetTimeline]);
        assert!(!s.is_dirty() && !s.can_undo());
        assert_eq!(s.display_name(), "Untitled");
    }

    #[test]
    fn perform_commits_one_step_and_notifies() {
        let mut s = session();
        s.take_changes();
        s.perform("Rename", None, |p| p.name = "Film".into());
        assert_eq!(s.project().name, "Film");
        assert_eq!(s.undo_name(), Some("Rename"));
        assert!(s.is_dirty());
        assert!(s.take_changes().contains(Change::PROJECT | Change::SELECTION));
        assert_eq!(s.version(Change::PROJECT), 1);
        assert!(s.undo());
        assert_eq!(s.project().name, "Untitled");
        assert!(s.redo());
        assert_eq!(s.project().name, "Film");
        assert_eq!(s.version(Change::PROJECT), 3);
    }

    #[test]
    fn try_perform_error_leaves_the_project_untouched() {
        let mut s = session();
        let r: Result<(), &str> = s.try_perform("Fail", None, |p| {
            p.name = "Changed".into();
            Err("refused")
        });
        assert_eq!(r, Err("refused"));
        assert_eq!(s.project().name, "Untitled");
        assert!(!s.can_undo());
    }

    #[test]
    fn coalescing_edits_merge_until_end_gesture() {
        let mut s = session();
        s.perform("Drag", Some("k"), |p| p.name = "a".into());
        s.perform("Drag", Some("k"), |p| p.name = "b".into());
        assert_eq!(s.undo_step_depth(), 1);
        s.end_gesture();
        s.perform("Drag", Some("k"), |p| p.name = "c".into());
        assert_eq!(s.undo_step_depth(), 2);
    }

    #[test]
    fn side_step_runs_with_its_undo_step() {
        let mut s = session();
        let log = Rc::new(RefCell::new(Vec::new()));
        let depth = s.undo_step_depth();
        s.perform("Delete Frames", None, |p| p.name = "x".into());
        let (u, r) = (Rc::clone(&log), Rc::clone(&log));
        s.register_side_step(
            "Delete Frames",
            depth,
            move || u.borrow_mut().push("undo"),
            move || r.borrow_mut().push("redo"),
        );
        assert_eq!(s.undo_step_depth(), 1); // tied to the edit's step, no extra step
        assert!(s.undo());
        assert!(s.redo());
        assert_eq!(*log.borrow(), vec!["undo", "redo"]);
    }

    #[test]
    fn side_step_without_an_edit_gets_its_own_step() {
        let mut s = session();
        let log = Rc::new(RefCell::new(0));
        let depth = s.undo_step_depth();
        let u = Rc::clone(&log);
        s.register_side_step("Clear Matte", depth, move || *u.borrow_mut() += 1, || {});
        assert_eq!(s.undo_name(), Some("Clear Matte"));
        assert!(s.is_dirty());
        assert!(s.undo());
        assert_eq!(*log.borrow(), 1);
    }

    #[test]
    fn events_drain_in_order() {
        let mut s = session();
        s.emit(SessionEvent::ProjectReplaced);
        s.emit(SessionEvent::MediaFilesChanged(BTreeSet::new()));
        assert_eq!(s.take_events().len(), 2);
        assert!(s.take_events().is_empty());
    }
}
