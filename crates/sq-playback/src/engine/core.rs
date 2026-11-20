// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Windows/SQWinApp WinProgramEngine.swift (1:1 logic; threads and proxies differ, see the shortcuts)
//! The Program engine. The position comes from the master clock; every video layer at that position is decoded through the
//! media opener on the decode lanes and `ProgramCompositor` draws the frame. State and rules are WinProgramEngine's: a
//! cache of decoded pictures by (media, index, divisor), a `wanted` frame (the keys its pictures need) and a `shown` one,
//! stand-ins while a decode is behind, a clock held until the first picture is up, warm-up while paused, scrub rules.
//!
//! Proxies: the opener offers a proxy per media (`MediaOpener::open_for`); it is opened beside the original and keys
//! with `proxy` read it while scrubbing or playing when `ProxyUse` allows. A paused frame always reads the original.
//! shortcut: a proxy reads on one decoder (no lanes; proxies are intra-only ProRes).
//! shortcut: PNG stills go through the video decoder (alpha via the RGBA path) instead of `PortablePNG`.
//! shortcut: the caption / title look-ahead (`prepareCaptions`, `prepareTitles` on WinCaptionLane) is the raster
//! provider's business; the engine only asks for the rasters of the frame it draws.

use super::activity::{PlayActivity, PlayMark};
use super::caption_plan;
use super::display_pacing::{DisplayPacer, PlayStart, PlayStep, loop_wrap, wrapped};
use super::handle::{Command, EngineDeps, Msg, Shared, Shown, Status};
use super::lanes::{CancelToken, LanePool};
use super::late_frames::LateFrames;
use super::look_preview::LookPreview;
use super::media_source::MediaSource;
use super::proxy_picture::ProxyUse;
use super::state::{CompositorSlot, EngineState, Event};
use super::stats::{PlayStats, Stage};
use super::types::{Key, MediaRef, Picture, WantGate, Wanted};
use sq_core_audio::caption_handover::CaptionSlotLookup;
use sq_core_color::ColorBypass;
use sq_core_edit::playback::PlaybackRate;
use sq_core_effects::evaluation::{LayerHooks, LayerRequest, TimelineEvaluation};
use sq_core_model::{ClipTransform, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_frame::sqframe::SQFrameColorSpace;
use sq_gpu::frames::{GpuFrame, PlaneLayout};
use sq_media::media_opener::MonitorUse;
use sq_media::video_decoding::DecodeScale;
use sq_render::program::{Inputs, LayerSource, ProgramCompositor, ProgramError, RenderOptions, Source};
use std::collections::{HashMap, HashSet};
use std::ops::RangeInclusive;
use std::sync::Arc;
use super::clock_hold::{ClockHold, FIRST_PICTURE_LIMIT, HoldStep, ahead_indices};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

/// How long the render thread waits for the GPU to finish an earlier frame while playing before it drops the frame. Short, so
/// the thread keeps taking decoded pictures and the clock; the wait is a fence wait, not a spin.
const GPU_WAIT_PLAYING: Duration = Duration::from_millis(8);
/// A decode that failed is not asked again for this long.
const FAILED_RETRY: Duration = Duration::from_secs(3);
/// While playing, a stand-in reaches this many frames.
pub const STAND_IN_REACH: i64 = 90;
/// Sources larger than this (1080p plus a margin) scrub in preview mode.
pub const PREVIEW_PIXELS: i64 = 2_400_000;
/// Paused or scrubbing: the playhead rests, then the cache fills this many frames on each side of it, more in the direction
/// the playhead moved last (decode ahead and behind: a scrub back and forth over a long-GOP file hits the cache).
const FILL_AHEAD: i64 = 16;
const FILL_BEHIND: i64 = 8;
/// Playing backwards: at most this many frames per decode window (see `request_reverse`), and how near the playhead gets
/// to a window's start before the one before it is asked for.
const REVERSE_WINDOW: i64 = 30;
const REVERSE_LEAD: i64 = 10;
/// One fill decode asks for at most this many frames, so the decoder is free for the next playhead position soon.
const FILL_CHUNK: i64 = 8;
/// A lane reads toward a picture that is at most this far past what it decodes.
const LANE_REACH: i64 = 45;
const MAX_LANES: usize = 3;

/// 1, 2 or 4: the divisor a layer's picture needs while playing or scrubbing (`PlaybackLayerDetail`): a layer drawn at half
/// its native size or less on its sequence's canvas is decoded at half, a quarter or less at a quarter. Tilted layers keep
/// The frame a stand-in shows for `wanted` among the decoded `cached` frames of the file. Scrubbing: the nearest either way.
/// Playing: the nearest frame the playhead has already passed and not older than `floor` (the newest frame of the file drawn
/// since play started), never one ahead of it: frames from before a click or a stand-in older than the picture on screen
/// would show the picture jumping back and forth. `None`: keep the picture on screen.
pub(crate) fn stand_in_index(
    cached: impl Iterator<Item = i64>,
    wanted: i64,
    scrubbing: bool,
    forward: bool,
    floor: Option<i64>,
) -> Option<i64> {
    if scrubbing {
        return cached.min_by_key(|c| (c - wanted).abs());
    }
    let passed = |c: &i64| if forward { *c <= wanted } else { *c >= wanted };
    let not_older = |c: &i64| floor.is_none_or(|f| if forward { *c >= f } else { *c <= f });
    cached.filter(|c| passed(c) && not_older(c)).min_by_key(|c| (c - wanted).abs())
}

/// full detail.
pub fn playback_layer_detail(l: &LayerRequest) -> u32 {
    const MARGIN: f64 = 1.1;
    fn drawn(t: &ClipTransform) -> f64 {
        t.scale.x.abs().max(t.scale.y.abs())
    }
    if l.transform.is_tilted() {
        return 1;
    }
    let mut s = drawn(&l.transform);
    for g in &l.groups {
        if g.transform.is_tilted() {
            return 1;
        }
        s *= drawn(&g.transform);
    }
    if s <= 0.25 * MARGIN {
        4
    } else if s <= 0.5 * MARGIN {
        2
    } else {
        1
    }
}

struct Lane {
    source: Arc<MediaSource>,
    /// The last picture asked of it.
    at: Option<i64>,
    /// The last one it decodes.
    to: i64,
    used: u64,
}

impl Lane {
    fn new(source: Arc<MediaSource>, used: u64) -> Lane {
        Lane { source, at: None, to: -1, used }
    }
    fn reaches(&self, index: i64) -> bool {
        self.at.is_some_and(|at| index >= at && index <= at.max(self.to) + LANE_REACH)
    }
}

pub struct ProgramEngine {
    deps: EngineDeps,
    tx: Sender<Msg>,
    shared: Arc<Shared>,
    pool: LanePool,
    stats: Arc<PlayStats>,
    want_gate: Arc<WantGate>,

    timeline: Timeline,
    sequences: HashMap<Id, Timeline>,
    captions: CaptionSlotLookup,
    position: Time,
    state: EngineState,
    quality: DecodeScale,
    /// `PowerPolicy::halves_prefetch`: the look-ahead of the prefetch is half as far.
    prefetch_halved: bool,
    /// The span the host stops or wraps at (None: the whole sequence); the picture never leads out of it.
    play_range: Option<TimeRange>,
    /// Loop: the engine wraps playback inside the play range (or the whole sequence) by itself, both directions.
    loops: bool,
    shows_captions: bool,
    shows_transparency_grid: bool,
    color_bypass: Option<ColorBypass>,
    look_preview: Option<LookPreview>,
    media_paths: HashMap<Id, String>,
    last_error: Option<String>,

    sources: HashMap<Id, Arc<MediaSource>>,
    /// The open proxy of a media, beside its original.
    proxy_sources: HashMap<Id, Arc<MediaSource>>,
    proxy_opening: HashSet<Id>,
    /// Media the opener has no proxy for (asked once until `proxies_changed`).
    no_proxy: HashSet<Id>,
    proxy_use: ProxyUse,
    /// The media whose proxy the monitor reads right now (for the one log line per switch).
    proxy_reading: HashSet<Id>,
    opening: HashSet<Id>,
    open_failed: HashMap<Id, String>,
    cancel: HashMap<Id, CancelToken>,
    lanes: HashMap<Id, Vec<Lane>>,
    lane_opening: HashSet<Id>,
    intra_files: HashMap<Id, bool>,
    refresh_count: u64,
    last_refresh: Instant,

    /// Decoded pictures by key; a window around the playhead.
    cache: HashMap<Key, Picture>,
    cache_bytes: usize,
    cache_generation: u64,
    frame_cache_bytes: usize,
    in_flight: HashSet<Key>,
    failed_keys: HashMap<Key, Instant>,
    preview_keys: HashSet<Key>,
    play_divisors: HashMap<Id, u32>,
    prefetch_countdown: i32,
    prefetch_keys: Vec<Key>,

    wanted: Option<Wanted>,
    shown: Option<Wanted>,
    shown_exact: bool,
    shown_lag: i64,
    wanted_requests: Vec<LayerRequest>,
    picture_present: bool,
    picture_generation: u64,
    compositor: CompositorSlot<ProgramCompositor>,
    /// Playing: the newest frame of each file drawn since play started (a stand-in never goes back behind it).
    played_through: HashMap<Id, i64>,

    compose_pending: bool,
    /// The last composite was dropped because the GPU was busy: the wanted frame is composited again on the next loop.
    compose_retry: bool,
    /// This engine in the process-wide count of playing engines (the automatic proxy holds back while any plays).
    activity: PlayMark,
    moved_since_tick: bool,
    /// After Play: the clock waits for the first picture and the pre-roll (`clock_hold.rs`).
    clock_hold: ClockHold,
    /// Diagnostics: when `play` was called, until the first decode and the first picture after it are logged.
    play_logged: Option<(Instant, bool)>,
    /// The clock start laid out on the display while the picture at the playhead is up (`awaiting_display_start`), and the
    /// display tick it last looked at.
    play_start: Option<(PlayStart, i64)>,
    shown_frames: u64,
    skipped_frames: u64,
    /// Counts every start of a measured run: Play, a seek while playing, a loop wrap (`Status::run`).
    run_serial: u64,
    last_shown_frame: Option<i64>,
    late: LateFrames,
    played_span: Option<(i64, i64)>,
    compose_sum: f64,
    compose_count: u64,

    warm_position: Option<Time>,
    warm_since: Option<Instant>,
    warm_queue: Vec<Key>,
    warm_last: Instant,
    pacer: DisplayPacer,
    /// +1 / -1: the way the paused playhead moved last.
    scrub_direction: i64,
    fill_enabled: bool,
}

impl ProgramEngine {
    /// An engine for the render thread (or for a test that drives `handle` and `tick` itself).
    pub(crate) fn new(deps: EngineDeps, tx: Sender<Msg>, shared: Arc<Shared>) -> ProgramEngine {
        let frame_duration = Time::new(1, 25);
        let mut format = sq_core_model::SequenceFormat::new(frame_duration);
        format.width = 1920;
        format.height = 1080;
        let timeline = Timeline::new(Id::from_u128(0), "", format, Vec::new());
        let now = Instant::now();
        if let Some(g) = &deps.gyro {
            // A Gyroflow analysis finished: draw again with the stabilized picture.
            let (tx, shared) = (tx.clone(), Arc::clone(&shared));
            g.maps.add_observer(Arc::new(move || {
                shared.post(&tx, Msg::Query(Box::new(|e: &mut ProgramEngine| e.compose())));
            }));
        }
        ProgramEngine {
            pool: LanePool::new(deps.workers),
            frame_cache_bytes: deps.frame_cache_bytes,
            captions: CaptionSlotLookup::new(&timeline),
            deps,
            tx,
            shared,
            stats: Arc::new(PlayStats::new()),
            want_gate: Arc::new(WantGate::default()),
            timeline,
            sequences: HashMap::new(),
            position: Time::ZERO,
            state: EngineState::Paused,
            quality: DecodeScale::Full,
            prefetch_halved: false,
            play_range: None,
            loops: false,
            shows_captions: true,
            shows_transparency_grid: false,
            color_bypass: None,
            look_preview: None,
            media_paths: HashMap::new(),
            last_error: None,
            sources: HashMap::new(),
            proxy_sources: HashMap::new(),
            proxy_opening: HashSet::new(),
            no_proxy: HashSet::new(),
            proxy_use: ProxyUse::DEFAULT,
            proxy_reading: HashSet::new(),
            opening: HashSet::new(),
            open_failed: HashMap::new(),
            cancel: HashMap::new(),
            lanes: HashMap::new(),
            lane_opening: HashSet::new(),
            intra_files: HashMap::new(),
            refresh_count: 0,
            last_refresh: now,
            cache: HashMap::new(),
            cache_bytes: 0,
            cache_generation: 0,
            in_flight: HashSet::new(),
            failed_keys: HashMap::new(),
            preview_keys: HashSet::new(),
            play_divisors: HashMap::new(),
            prefetch_countdown: 0,
            prefetch_keys: Vec::new(),
            wanted: None,
            shown: None,
            shown_exact: true,
            shown_lag: 0,
            wanted_requests: Vec::new(),
            picture_present: false,
            picture_generation: 0,
            compositor: CompositorSlot::NotCreated,
            played_through: HashMap::new(),
            compose_pending: false,
            compose_retry: false,
            activity: PlayMark::new(PlayActivity::shared()),
            moved_since_tick: false,
            clock_hold: ClockHold::Running,
            play_logged: None,
            play_start: None,
            shown_frames: 0,
            skipped_frames: 0,
            run_serial: 0,
            last_shown_frame: None,
            late: LateFrames::default(),
            played_span: None,
            compose_sum: 0.0,
            compose_count: 0,
            warm_position: None,
            warm_since: None,
            warm_queue: Vec::new(),
            warm_last: now,
            pacer: DisplayPacer::default(),
            scrub_direction: 1,
            fill_enabled: std::env::var_os("SQ_SCRUB_FILL").is_none_or(|v| v != "0"),
        }
    }

    // MARK: Thread loop

    /// The render thread: messages wake it at once, a tick runs at least every 2 ms while playing or scrubbing and every
    /// 10 ms otherwise.
    pub(crate) fn run(mut self, rx: &Receiver<Msg>) {
        loop {
            let busy = !self.state.rate().is_paused() || self.state.is_scrubbing();
            let wait = Duration::from_millis(if busy { 2 } else { 10 });
            match rx.recv_timeout(wait) {
                Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                Ok(m) => {
                    self.shared.taken(&m);
                    self.handle(m);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
            while let Ok(m) = rx.try_recv() {
                self.shared.taken(&m);
                if matches!(m, Msg::Stop) {
                    return;
                }
                self.handle(m);
            }
            self.tick();
            self.activity.set(!self.state.rate().is_paused() || self.state.is_scrubbing());
            if self.compose_retry {
                self.compose();
            }
        }
    }

    pub(crate) fn handle(&mut self, m: Msg) {
        match m {
            Msg::Command(c) => self.command(c),
            Msg::Decoded { key, picture, scale, preview } => {
                let stats = Arc::clone(&self.stats);
                stats.time(Stage::Arrive, || self.decoded(key, picture, scale, preview));
            }
            Msg::Finished { keys, error } => {
                let stats = Arc::clone(&self.stats);
                stats.time(Stage::Finish, || self.finished(&keys, error));
            }
            Msg::Opened { media, path, lane, result } => self.opened(media, &path, lane, result),
            Msg::ProxyOpened { media, path, result } => self.proxy_opened(media, &path, result),
            Msg::Query(f) => f(self),
            Msg::Stop => {}
        }
        self.publish_status();
    }

    fn command(&mut self, c: Command) {
        match c {
            Command::SetTimeline { timeline, sequences } => self.set_timeline(*timeline, sequences),
            Command::SetMedia(refs) => self.set_media(&refs),
            Command::MediaChanged(ids) => self.media_changed(&ids),
            Command::SetProxyUse(u) => self.set_proxy_use(u),
            Command::ProxiesChanged(ids) => self.proxies_changed(&ids),
            Command::Play(r) => self.play(r),
            Command::Pause => self.pause(),
            Command::Seek(t) => self.seek(t),
            Command::Step(n) => self.step(n),
            Command::BeginScrub => self.begin_scrub(),
            Command::Scrub(t) => self.move_to(t),
            Command::EndScrub => self.end_scrub(),
            Command::SetQuality(q) => self.set_quality(q),
            Command::SetPlayRange(r) => {
                self.play_range = r;
                self.pacer.set_bounds(r, self.loops);
            }
            Command::SetLoops(on) => {
                self.loops = on;
                self.pacer.set_bounds(self.play_range, on);
                self.refresh();
            }
            Command::SetPrefetchHalved(on) => {
                if on != self.prefetch_halved {
                    self.prefetch_halved = on;
                    self.prefetch_countdown = 0; // replan the window now (Swift `setPowerPolicy` bumps the generation)
                }
            }
            Command::SetShowsCaptions(on) => {
                if on != self.shows_captions {
                    self.shows_captions = on;
                    self.shown = None;
                    self.refresh();
                }
            }
            Command::SetTransparencyGrid(on) => {
                if on != self.shows_transparency_grid {
                    self.shows_transparency_grid = on;
                    self.shown = None;
                    self.refresh();
                }
            }
            Command::SetColorBypass(b) => self.set_color_bypass(b),
            Command::SetLookPreview(p) => {
                let p = p.map(|b| *b);
                if p != self.look_preview {
                    self.look_preview = p;
                    self.shown = None;
                    self.refresh();
                }
            }
            Command::SetFrameCacheBytes(n) => {
                self.frame_cache_bytes = n;
                self.refresh();
            }
        }
    }

    fn publish_status(&self) {
        let mut s = self.shared.status.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        s.position = self.position;
        s.rate = Some(self.state.rate());
        s.shown_frames = self.shown_frames;
        // Positions the playhead passed with nothing new on screen count already, not only once the next frame shows.
        let waiting = self.waiting_frames();
        s.skipped_frames = self.skipped_frames + waiting;
        s.late_frames = self.late.late();
        s.run = self.run_serial;
        s.clock_running = !self.clock_hold.is_held();
        s.max_lag = self.late.max_lag().max(if waiting > 0 { i64::try_from(waiting).unwrap_or(i64::MAX) } else { 0 });
        if s.first_late != self.late.first() {
            s.first_late = self.late.first().to_vec();
        }
        s.played_span = self.played_span;
        if s.last_error != self.last_error {
            s.last_error.clone_from(&self.last_error);
        }
        if s.compositor_failure.as_deref() != self.compositor.failure() {
            s.compositor_failure = self.compositor.failure().map(str::to_string);
        }
        s.cache_generation = self.cache_generation;
        s.cache_bytes = self.cache_bytes;
        s.mean_compose_ms = self.mean_compose_milliseconds();
        s.shown_lag = self.shown_lag;
    }

    // MARK: Public state (queries run on the render thread)

    pub fn position(&self) -> Time {
        self.position
    }
    pub fn rate(&self) -> PlaybackRate {
        self.state.rate()
    }
    pub fn state(&self) -> EngineState {
        self.state
    }
    pub fn timeline(&self) -> &Timeline {
        &self.timeline
    }
    pub fn stats(&self) -> &Arc<PlayStats> {
        &self.stats
    }
    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }
    pub fn shown_frames(&self) -> u64 {
        self.shown_frames
    }
    pub fn skipped_frames(&self) -> u64 {
        self.skipped_frames
    }
    /// Frame positions the playhead has passed since the last frame that reached the screen, while playing. `display` counts
    /// a gap only when the next frame shows; a layer whose decoder delivers no picture at all (not even an old one to stand
    /// in) keeps `compose` waiting, so that frame never comes and the gap would never be counted. The wanted frame itself is
    /// not in it: it may still arrive in time.
    fn waiting_frames(&self) -> u64 {
        let Some(last) = self.last_shown_frame else { return 0 };
        if self.state.rate().is_paused() {
            return 0;
        }
        let here = self.position.frame_index(self.timeline.frame_duration());
        skipped_in_run(Some(last), here, self.state.rate().is_forward())
    }
    pub fn cache_len(&self) -> usize {
        self.cache.len()
    }
    pub fn cache_bytes(&self) -> usize {
        self.cache_bytes
    }
    pub fn picture_generation(&self) -> u64 {
        self.picture_generation
    }
    /// The keys of the frame wanted at the playhead, bottom to top.
    /// The media's proxy is open (tests).
    pub fn proxy_open(&self, media: Id) -> bool {
        self.proxy_sources.contains_key(&media)
    }
    pub fn wanted_keys(&self) -> Vec<Key> {
        self.wanted.as_ref().map(|w| w.keys.clone()).unwrap_or_default()
    }
    /// The monitor shows the exact pictures of the wanted frame (not a nearby stand-in).
    pub fn is_showing_exact_frame(&self) -> bool {
        self.shown.is_some() && self.shown == self.wanted && self.shown_exact
    }
    /// Playing and the frame at the playhead is not on screen yet (its pictures are still decoding).
    pub fn is_waiting_for_frame(&self) -> bool {
        !self.state.rate().is_paused() && self.wanted.is_some() && self.shown != self.wanted
    }
    /// True when the shown picture is the exact one for the playhead (no stand-in, nothing still opening).
    pub fn is_picture_settled(&self) -> bool {
        match &self.wanted {
            None => self.picture_present,
            Some(w) => {
                self.shown.as_ref() == Some(w) && self.shown_exact && self.opening.is_empty() && self.picture_present
            }
        }
    }
    /// The wanted frame is on screen with its exact pictures and nothing it needs is still opening (a GPU composite or an
    /// empty frame; `is_picture_settled` additionally wants a composite).
    pub fn is_frame_settled(&self) -> bool {
        self.wanted.is_some()
            && self.shown == self.wanted
            && self.shown_exact
            && !self.wanted_requests.iter().any(|r| self.opening.contains(&r.media))
    }
    pub fn mean_compose_milliseconds(&self) -> f64 {
        if self.compose_count > 0 { self.compose_sum / self.compose_count as f64 } else { 0.0 }
    }

    // MARK: Setup

    fn set_timeline(&mut self, timeline: Timeline, sequences: HashMap<Id, Timeline>) {
        self.captions = CaptionSlotLookup::new(&timeline);
        self.timeline = timeline;
        self.sequences = sequences;
        self.warm_position = None;
        self.wanted = None;
        self.shown = None;
        self.refresh();
    }

    fn set_media(&mut self, refs: &[MediaRef]) {
        let paths: HashMap<Id, String> = refs.iter().map(|r| (r.id, r.path.clone())).collect();
        // A relinked item (Reconnect Media) reads from its new file; the open error of its old path goes away with it.
        let moved: HashSet<Id> = paths
            .iter()
            .filter(|(id, p)| self.media_paths.get(id).is_some_and(|old| old != *p))
            .map(|(id, _)| *id)
            .collect();
        self.media_paths = paths;
        if let Some(c) = &self.deps.color {
            c.invalidate();
        }
        if !moved.is_empty() {
            if self.last_error.as_deref().is_some_and(|e| e.starts_with("open ")) {
                self.last_error = None;
            }
            self.media_changed(&moved);
        }
    }

    fn media_changed(&mut self, ids: &HashSet<Id>) {
        for id in ids {
            self.sources.remove(id);
            self.proxy_sources.remove(id);
            self.no_proxy.remove(id);
            self.open_failed.remove(id);
            self.lanes.remove(id);
            self.intra_files.remove(id);
            // Jobs of the old file stop; a fresh token serves the new one.
            if let Some(t) = self.cancel.insert(*id, CancelToken::new()) {
                t.cancel();
            }
        }
        self.cache.retain(|k, _| !ids.contains(&k.media));
        self.in_flight.retain(|k| !ids.contains(&k.media));
        self.recount_cache();
        self.refresh();
    }

    fn set_quality(&mut self, q: DecodeScale) {
        if q == self.quality {
            return;
        }
        self.quality = q;
        self.cache.clear();
        self.recount_cache();
        self.play_divisors.clear();
        if let Some(c) = self.compositor.ready_mut() {
            c.drop_planes();
        }
        self.shown = None;
        self.refresh();
    }

    fn set_color_bypass(&mut self, bypass: Option<ColorBypass>) {
        let value = bypass.filter(|b| !b.is_empty());
        if value == self.color_bypass {
            return;
        }
        self.color_bypass = value;
        self.shown = None;
        self.refresh();
    }

    fn recount_cache(&mut self) {
        self.cache_bytes = self.cache.values().map(|p| p.bytes).sum();
        self.cache_generation += 1;
    }

    // MARK: Transport

    /// The one writer of `state`: a refused transition (see `EngineState::next`) leaves it as it was.
    fn transition(&mut self, event: Event) {
        if let Ok(next) = self.state.next(event) {
            self.state = next;
        }
    }

    fn play(&mut self, r: PlaybackRate) {
        if r.is_paused() {
            self.pause();
            return;
        }
        self.transition(Event::Play(r));
        // Play from behind a loop's end starts at its beginning (the running clock would wrap there at once).
        if let Some(l) = self.loop_region()
            && r.is_forward()
            && self.position >= l.end()
        {
            self.move_to(l.start);
        }
        self.pacer.reset();
        self.play_start = None;
        self.played_through.clear();
        // From the frame on screen: frames that never showed before the first new one count as dropped.
        self.shown_frames = 0;
        self.skipped_frames = 0;
        self.run_serial += 1;
        let here = self.position.frame_index(self.timeline.frame_duration());
        self.last_shown_frame = Some(here);
        self.late.start(here);
        self.played_span = Some((here, here));
        self.stats.reset();
        self.play_divisors.clear();
        self.compose_sum = 0.0;
        self.compose_count = 0;
        // The clock and the sound start when the picture at the playhead is on screen (`release_clock`): a cold 4K file
        // needs 0.2 to 1 s for its first frame, and a clock that ran meanwhile left the decoder chasing a playhead it never
        // caught.
        self.clock_hold = ClockHold::Held { since: Instant::now() };
        self.play_logged = Some((Instant::now(), false));
        sq_core_time::milestones::note("play: requested, clock held for the start picture");
    }

    /// Swift `PlayStart` on the engine's loop: with a display link that reports present times, the clock stays parked on the
    /// start position until the start is laid out so every tick's frame falls mid-frame; true while waiting. Without a link
    /// (headless, no present timestamps) it is false at once: the clock starts now, as before.
    fn awaiting_display_start(&mut self) -> bool {
        let Some(display) = self.deps.display.clone() else { return false };
        let Some(tick) = display.read().filter(|t| t.present_us.is_some()) else { return false };
        let fd = self.timeline.frame_duration();
        let rate = self.state.rate();
        let host_now = display.micros(Instant::now()) as f64 / 1e6;
        let start = self.play_start.is_none().then_some(self.position);
        let (ps, last) =
            self.play_start.get_or_insert_with(|| (PlayStart::new(start.unwrap_or(Time::ZERO), rate), i64::MIN));
        if *last != tick.at_us {
            *last = tick.at_us;
            let present = tick.present_us.map(|p| p as f64 / 1e6);
            let speed = (f64::from(rate.num().unsigned_abs()) / f64::from(rate.den().max(1))).max(1.0);
            match ps.tick(present, tick.at_us as f64 / 1e6, fd, tick.interval_us as f64 / 1e6 / speed) {
                PlayStep::StartNow => return false,
                PlayStep::Led { position, .. } => self.move_to(position),
                PlayStep::Hold => {}
            }
        }
        let Some((ps, _)) = &self.play_start else { return false };
        match ps.host_start() {
            Some(hs) if host_now >= hs => {
                self.position = ps.clock_position(host_now).snapped(fd);
                self.pacer.prime(ps.last_led(), ps.last_host_lead());
                false
            }
            _ => true,
        }
    }

    /// The next `PREROLL_FRAMES` frames of every visible video layer, in play direction and inside the clip, are cached (or
    /// failed); true when no layer needs a picture.
    fn frames_ahead_ready(&self) -> bool {
        let forward = self.state.rate().is_forward();
        self.wanted_requests.iter().filter(|l| l.generator.is_none()).all(|l| {
            // A layer whose file is not open yet has nothing cached ahead.
            let Some(k) = self.peek_key(l) else { return false };
            let Some(src) = self.sources.get(&l.media) else { return false };
            let count = if k.proxy { self.proxy_sources.get(&k.media) } else { Some(src) }
                .map_or(src.frame_count() as i64, |s| s.frame_count() as i64);
            let start = l.source_start.map(|t| src.frame_index(t));
            let end = l.source_end.map(|t| src.frame_index(t));
            ahead_indices(k.index, forward, count, start, end).into_iter().all(|i| {
                let key = Key { index: i, ..k };
                self.cache.contains_key(&key) || self.has_failed(&key)
            })
        })
    }

    fn release_clock(&mut self) {
        let held = self.clock_hold.waited();
        self.clock_hold = ClockHold::Running;
        // Starting the master clock starts the audio at the playhead (every rate: |rate| != 1 keeps the pitch).
        let started = Instant::now();
        self.deps.clock.start(self.position, self.state.rate());
        sq_core_time::milestones::note(&format!(
            "play: clock released after {:.0} ms held, clock.start took {:.1} ms",
            held.map_or(0.0, |h| h.as_secs_f64() * 1e3),
            started.elapsed().as_secs_f64() * 1e3
        ));
    }

    fn pause(&mut self) {
        if self.state.rate().is_paused() {
            return;
        }
        self.transition(Event::Pause);
        self.clock_hold = ClockHold::Running;
        self.play_start = None;
        self.deps.clock.stop();
        self.notify_position();
        self.refresh(); // the paused frame from the original at full detail (a no-op when the keys did not change)
    }

    fn seek(&mut self, t: Time) {
        self.played_through.clear();
        // A jump is not a dropped run: the next picture starts the count again.
        self.last_shown_frame = None;
        self.run_serial += 1;
        if !self.state.rate().is_paused() && !self.clock_hold.is_held() {
            // Playing: the master clock follows the jump (flushes the audio to the new place).
            self.deps.clock.seek(t.max(Time::ZERO).snapped(self.timeline.frame_duration()));
        }
        self.move_to(t);
    }

    fn step(&mut self, frames: i32) {
        self.pause();
        let fd = self.timeline.frame_duration();
        self.move_to(self.position + fd * i64::from(frames));
    }

    fn begin_scrub(&mut self) {
        self.pause();
        self.transition(Event::BeginScrub);
        self.play_divisors.clear();
    }

    fn end_scrub(&mut self) {
        if !self.state.is_scrubbing() {
            return;
        }
        self.transition(Event::EndScrub);
        // Preview pictures (software decoders without the loop filter) leave the cache; the exact ones decode again.
        for s in self.sources.values() {
            s.set_preview(false);
        }
        for all in self.lanes.values() {
            for l in all {
                l.source.set_preview(false);
            }
        }
        if !self.preview_keys.is_empty() {
            let doomed = std::mem::take(&mut self.preview_keys);
            self.cache.retain(|k, _| !doomed.contains(k));
            self.recount_cache();
            self.shown = None;
        }
        self.refresh();
    }

    fn notify_position(&self) {
        if let Some(f) = &self.deps.on_position {
            f(self.position);
        }
    }

    // MARK: Clock

    /// Once per loop: advances the playhead from the master clock while playing and keeps decoding.
    pub(crate) fn tick(&mut self) {
        if let Some(waited) = self.clock_hold.waited() {
            let first_picture = match &self.wanted {
                Some(w) => self.shown.as_ref() == Some(w),
                None => false,
            };
            let step = ClockHold::step(waited, first_picture, first_picture && self.frames_ahead_ready());
            let release = step == HoldStep::Release;
            let waited_out = waited > FIRST_PICTURE_LIMIT;
            if release && (waited_out || !self.awaiting_display_start()) {
                self.play_start = None;
                self.release_clock();
            } else if release {
                // The display link lays the clock start out: the start frame, then the frames for the glass, in order.
                self.refresh();
                self.publish_status();
                return;
            } else {
                self.refresh(); // nothing moves while the first picture decodes
                self.publish_status();
                return;
            }
        }
        if !self.state.rate().is_paused() {
            let fd = self.timeline.frame_duration();
            let rate = self.state.rate();
            let mut now = self.deps.clock.now();
            // Loop: the clock left the loop and continues at its other end (the audio follows the clock seek).
            let region = self.loop_region();
            if let Some(to) = region.and_then(|r| loop_wrap(now, r, rate)) {
                self.deps.clock.seek(to);
                now = to;
                self.last_shown_frame = None; // the wrap is a jump, not dropped frames
                self.run_serial += 1;
            }
            // The frame the clock is inside of (floor, as the Swift host clock).
            let t = fd * now.frame_index(fd);
            let end = self.timeline.duration();
            let forward = rate.is_forward();
            // A loop never reaches the timeline's edges: it wraps inside them.
            let edge = if region.is_some() {
                None
            } else if t >= end && forward {
                Some(if end > fd { end - fd } else { Time::ZERO })
            } else if t <= Time::ZERO && !forward {
                Some(Time::ZERO)
            } else {
                None
            };
            if let Some(at) = edge {
                self.move_to(at);
                self.pause();
                self.publish_status();
                return;
            }
            let led = self.led_position(now, t, end, forward, region);
            self.move_to(led);
        } else if self.state.is_scrubbing() {
            if self.compose_pending && !self.moved_since_tick {
                self.compose();
            }
            if !self.moved_since_tick {
                self.fill_step();
            }
            self.moved_since_tick = false;
        } else {
            self.fill_step();
            self.warm_step();
        }
        self.publish_status();
    }

    /// The frame position a playing tick shows: the clock frame `t`, or (with a running display) the frame for the clock
    /// plus the display lead, changing only at display ticks, phase-locked between them (`display_pacing`). The picture
    /// never leads out of the timeline: it stops at the last frame while the clock is still inside.
    fn led_position(&mut self, now: Time, t: Time, end: Time, forward: bool, region: Option<TimeRange>) -> Time {
        let Some(display) = self.deps.display.clone() else { return t };
        let fd = self.timeline.frame_duration();
        let host_now = display.micros(Instant::now());
        let p = self.pacer.position(display.read(), host_now, now, self.state.rate(), fd);
        if let Some(r) = region {
            // Looping: the picture, ahead of the clock, is past the wrap before the clock is.
            return if r.contains(now) { wrapped(p, r) } else { t };
        }
        if forward {
            if p >= end && t < end { t.max(if end > fd { end - fd } else { Time::ZERO }) } else { p }
        } else if p < Time::ZERO && t >= Time::ZERO {
            Time::ZERO
        } else {
            p
        }
    }

    /// The span a looping engine plays: the play range inside the timeline, at least one frame (Swift `loopRegion`).
    fn loop_region(&self) -> Option<TimeRange> {
        if !self.loops {
            return None;
        }
        let fd = self.timeline.frame_duration();
        let dur = self.timeline.duration();
        let last = if fd > Time::ZERO && dur > Time::ZERO {
            let n = dur.frame_index(fd);
            fd * (if fd * n == dur { n - 1 } else { n }).max(0)
        } else {
            Time::ZERO
        };
        let end = last + fd;
        let a = self.play_range.map_or(Time::ZERO, |r| r.start.max(Time::ZERO));
        let b = self.play_range.map_or(end, |r| r.end().min(end));
        (b - a >= fd).then(|| TimeRange::from_end(a, b))
    }

    fn move_to(&mut self, t: Time) {
        let snapped = t.max(Time::ZERO).snapped(self.timeline.frame_duration());
        if snapped == self.position && self.shown.is_some() {
            // Same frame: re-plan at most at display cadence (the loop ticks faster than frames change).
            if self.last_refresh.elapsed() >= Duration::from_millis(8) {
                self.refresh();
            }
            return;
        }
        if self.state.rate().is_paused() && snapped != self.position {
            self.scrub_direction = if snapped > self.position { 1 } else { -1 };
        }
        self.position = snapped;
        self.moved_since_tick = true;
        self.stats.time(Stage::Position, || self.notify_position());
        self.refresh();
    }

    // MARK: Planning

    fn layers_at(&self, t: Time) -> Vec<LayerRequest> {
        let seqs = &self.sequences;
        let resolve = |id: Id| seqs.get(&id);
        self.timeline.video_layers(t, &resolve, &LayerHooks::plain(), None)
    }

    /// Picks the frame for `position`: composites it when every picture it needs is decoded, else asks for them (and a few
    /// frames ahead while playing).
    fn refresh(&mut self) {
        let plan_start = Instant::now();
        self.last_refresh = plan_start;
        let stats = Arc::clone(&self.stats);
        let requests = stats.time(Stage::VideoLayers, || self.layers_at(self.position));
        let keys: Vec<Key> = requests.iter().filter_map(|l| self.key_for(l)).collect();
        self.wanted = Some(Wanted { position: self.position, keys: keys.clone() });
        self.wanted_requests = requests;
        let playing = !self.state.rate().is_paused();
        self.want_gate.set(&keys, playing);
        let ahead = if playing { 8 } else { 0 };
        self.refresh_count += 1;
        let mut claimed: HashMap<Id, HashSet<usize>> = HashMap::new();
        // Lowest index first: of two layers of one file, the earlier one keeps the lane that is reading toward it.
        let mut order: Vec<Key> = keys.iter().copied().collect::<HashSet<_>>().into_iter().collect();
        order.sort_by_key(|k| (k.index, k.media));
        for k in order {
            self.request(k, ahead, &mut claimed, false);
        }
        if playing {
            self.prefetch(&mut claimed);
        } else {
            self.prefetch_keys.clear();
        }
        self.drop_idle_lanes();
        self.failed_keys.retain(|_, t| t.elapsed() <= FAILED_RETRY);
        self.trim_cache(&keys);
        if playing {
            stats.add(Stage::Plan, plan_start.elapsed().as_secs_f64() * 1e3, 1);
        }
        self.compose();
    }

    /// The cache keeps what it holds up to the budget (the frames behind the playhead stay: the ruler's cache strip and a
    /// step back use them); over it, the pictures farthest from this frame (and the clips coming up) go first, down to
    /// three quarters of the budget so the trim does not run again at once.
    fn trim_cache(&mut self, keys: &[Key]) {
        let mut total = self.cache_bytes;
        if total <= self.frame_cache_bytes {
            return;
        }
        let keep: Vec<Key> = keys.iter().chain(self.prefetch_keys.iter()).copied().collect();
        let distance = |k: &Key| {
            keep.iter().filter(|w| w.media == k.media).map(|w| (w.index - k.index).abs()).min().unwrap_or(i64::MAX / 2)
        };
        // Each picture's distance once (not inside the sort's comparator).
        let mut ranked: Vec<(Key, i64)> = self.cache.keys().map(|k| (*k, distance(k))).collect();
        ranked.sort_by_key(|r| std::cmp::Reverse(r.1));
        let mut doomed = Vec::new();
        for (k, _) in ranked {
            if total <= self.frame_cache_bytes / 4 * 3 {
                break;
            }
            if let Some(p) = self.cache.remove(&k) {
                total -= p.bytes;
                doomed.push(p);
            }
        }
        self.recount_cache();
        // Freeing a few hundred MB of pictures is not for the render thread either.
        let _ = std::thread::Builder::new().name("sq-graveyard".into()).spawn(move || drop(doomed));
    }

    // MARK: Keys

    fn key_for(&mut self, l: &LayerRequest) -> Option<Key> {
        if l.generator.is_some() {
            return None;
        }
        let stats = Arc::clone(&self.stats);
        stats.time(Stage::Key, || self.media_key(l, true))
    }

    /// The key a layer shows now, without opening files or remembering divisors (the compositor's source lookup and the
    /// cache strip).
    fn peek_key(&self, l: &LayerRequest) -> Option<Key> {
        if l.generator.is_some() {
            return None;
        }
        let src = self.sources.get(&l.media)?;
        Some(self.key_of(l, src, None))
    }

    fn media_key(&mut self, l: &LayerRequest, remember: bool) -> Option<Key> {
        if l.generator.is_some() {
            return None;
        }
        let src = self.source(l.media)?;
        let mut remembered = None;
        let key = self.key_of(l, &src, if remember { Some(&mut remembered) } else { None });
        if let Some(d) = remembered {
            self.play_divisors.insert(l.media, d);
        }
        self.note_proxy_switch(l.media, key.proxy);
        Some(key)
    }

    fn key_of(&self, l: &LayerRequest, src: &MediaSource, remember: Option<&mut Option<u32>>) -> Key {
        let index = src.frame_index(l.source_time);
        let mut divisor = self.quality.divisor() as u32;
        // The Mac `ProxyUse` contexts: scrubbing, playing or warming read reduced pictures; paused reads the original.
        if self.state.is_warming() || self.state.is_scrubbing() || !self.state.rate().is_paused() {
            let d = self
                .play_divisors
                .get(&l.media)
                .copied()
                .unwrap_or(u32::MAX)
                .min(divisor.max(playback_layer_detail(l)));
            if let Some(r) = remember {
                *r = Some(d);
            }
            divisor = d;
        }
        // Scrub preview: a picture beyond 1080p is read at a quarter of each side (smaller download and upload per frame);
        // the paused frame after the scrub is the normal, exact one.
        if self.state.is_scrubbing() && src.info.width * src.info.height > PREVIEW_PIXELS {
            divisor = divisor.max(4);
        }
        let mut key = Key::new(l.media, index, divisor);
        key.proxy = self.reads_proxy(l.media);
        key
    }

    /// One log line when a media's pictures start or stop coming from its proxy.
    fn note_proxy_switch(&mut self, media: Id, reads: bool) {
        if reads == self.proxy_reading.contains(&media) {
            return;
        }
        if reads {
            self.proxy_reading.insert(media);
        } else {
            self.proxy_reading.remove(&media);
        }
        let name = self.media_paths.get(&media).map_or_else(String::new, |p| p.clone());
        let (state, uses) = (self.state, self.proxy_use);
        sq_core_time::milestones::note(&format!(
            "proxy: monitor {} the proxy of {name} ({state:?}, use scrubbing={} playback={})",
            if reads { "switched to" } else { "left" },
            uses.scrubbing,
            uses.playback
        ));
    }

    /// Scrubbing or playing, the state allows proxies and the media's proxy is open (paused and warming: the original).
    fn reads_proxy(&self, media: Id) -> bool {
        let scrubbing = self.state.is_scrubbing();
        let playing = !scrubbing && !self.state.is_warming() && !self.state.rate().is_paused();
        ((scrubbing && self.proxy_use.scrubbing) || (playing && self.proxy_use.playback))
            && self.proxy_sources.contains_key(&media)
    }

    fn source_of(&self, k: &Key) -> Option<Arc<MediaSource>> {
        if k.proxy { self.proxy_sources.get(&k.media) } else { self.sources.get(&k.media) }.cloned()
    }

    fn set_proxy_use(&mut self, u: ProxyUse) {
        if u == self.proxy_use {
            return;
        }
        self.proxy_use = u;
        let ids: Vec<Id> = self.sources.keys().copied().collect();
        ids.into_iter().for_each(|m| self.ensure_proxy(m));
        self.refresh();
    }

    /// Their proxies were made, replaced or deleted: the pictures and decoders of them go, the open runs again.
    fn proxies_changed(&mut self, ids: &HashSet<Id>) {
        for id in ids {
            self.proxy_sources.remove(id);
            self.no_proxy.remove(id);
        }
        self.cache.retain(|k, _| !(k.proxy && ids.contains(&k.media)));
        self.in_flight.retain(|k| !(k.proxy && ids.contains(&k.media)));
        self.recount_cache();
        let open: Vec<Id> = ids.iter().filter(|m| self.sources.contains_key(m)).copied().collect();
        open.into_iter().for_each(|m| self.ensure_proxy(m));
        self.refresh();
    }

    /// Opens the media's proxy off the render thread when a state may use it and the opener has not said no.
    fn ensure_proxy(&mut self, media: Id) {
        if !(self.proxy_use.scrubbing || self.proxy_use.playback)
            || self.proxy_sources.contains_key(&media)
            || self.proxy_opening.contains(&media)
            || self.no_proxy.contains(&media)
        {
            return;
        }
        let Some(path) = self.media_paths.get(&media).cloned() else { return };
        self.proxy_opening.insert(media);
        let (opener, tx, stats) = (Arc::clone(&self.deps.opener), self.tx.clone(), Arc::clone(&self.stats));
        let _ = std::thread::Builder::new().name("sq-open-proxy".into()).spawn(move || {
            let result = opener
                .open_for(std::path::Path::new(&path), media, MonitorUse::Playing)
                .map(|r| r.map(|o| Box::new(MediaSource::from_opened(o, &stats))).map_err(|e| e.to_string()));
            let _ = tx.send(Msg::ProxyOpened { media, path, result });
        });
    }

    fn proxy_opened(&mut self, media: Id, path: &str, result: Option<Result<Box<MediaSource>, String>>) {
        self.proxy_opening.remove(&media);
        if self.media_paths.get(&media).map(String::as_str) != Some(path) {
            return;
        }
        match result {
            Some(Ok(s)) => {
                self.proxy_sources.insert(media, Arc::new(*s));
            }
            other => {
                let why = match other {
                    Some(Err(e)) => e,
                    _ => "none ready".to_string(),
                };
                sq_core_time::milestones::note(&format!("proxy: no proxy for {path}: {why}"));
                self.no_proxy.insert(media);
            }
        }
        self.refresh();
    }

    /// The media's open file; `None` while it opens (off the render thread: an open reads the index and starts a decoder,
    /// up to 400 ms for a 4K file) or when it failed to open.
    fn source(&mut self, media: Id) -> Option<Arc<MediaSource>> {
        if let Some(s) = self.sources.get(&media) {
            return Some(Arc::clone(s));
        }
        let path = self.media_paths.get(&media)?.clone();
        if self.open_failed.contains_key(&media) || self.opening.contains(&media) {
            return None;
        }
        self.opening.insert(media);
        self.spawn_open(media, path, false);
        None
    }

    fn spawn_open(&self, media: Id, path: String, lane: bool) {
        let (opener, tx, stats) = (Arc::clone(&self.deps.opener), self.tx.clone(), Arc::clone(&self.stats));
        let _ = std::thread::Builder::new().name("sq-open".into()).spawn(move || {
            let name =
                std::path::Path::new(&path).file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned());
            sq_core_time::milestones::mark(&format!("media open started {name}"));
            let result = opener
                .open(std::path::Path::new(&path), media)
                .map(|o| Box::new(MediaSource::from_opened(o, &stats)))
                .map_err(|e| e.to_string());
            sq_core_time::milestones::mark(&format!("media opened (probe + decoder) {name}"));
            let _ = tx.send(Msg::Opened { media, path, lane, result });
        });
    }

    fn opened(&mut self, media: Id, path: &str, lane: bool, result: Result<Box<MediaSource>, String>) {
        if lane {
            self.lane_opening.remove(&media);
        } else {
            self.opening.remove(&media);
        }
        if self.media_paths.get(&media).map(String::as_str) != Some(path) {
            self.refresh(); // relinked while opening: open the new file
            return;
        }
        match result {
            Ok(s) if lane => {
                let used = self.refresh_count;
                if let Some(all) = self.lanes.get_mut(&media) {
                    all.push(Lane::new(Arc::new(*s), used));
                }
                self.prefetch_countdown = 0; // the prefetch that asked for it runs again now
            }
            Ok(s) => {
                self.sources.insert(media, Arc::new(*s));
                self.ensure_proxy(media);
            }
            Err(e) if lane => {
                self.last_error = Some(format!("open {path}: {e}"));
            }
            Err(e) => {
                self.open_failed.insert(media, e.clone());
                self.last_error = Some(format!("open {path}: {e}"));
            }
        }
        self.refresh();
    }

    // MARK: Decode requests

    fn has_failed(&self, k: &Key) -> bool {
        self.failed_keys.get(k).is_some_and(|t| t.elapsed() <= FAILED_RETRY)
    }

    /// Decodes `k` and up to `ahead` frames after it that are neither cached nor on their way, on the lane of its file that
    /// reads toward it.
    fn request(&mut self, k: Key, ahead: i64, claimed: &mut HashMap<Id, HashSet<usize>>, prefetching: bool) {
        if !prefetching && !self.state.rate().is_paused() && !self.state.rate().is_forward() {
            self.request_reverse(k, claimed);
            return;
        }
        let Some(src) = self.lane_for(&k, ahead, claimed, prefetching) else { return };
        let last = (src.frame_count() as i64 - 1).min(k.index + ahead);
        self.decode_missing(&src, &k, k.index, last);
    }

    /// Decodes the frames of `lo..=hi` that are neither cached, in flight nor failed (one call, first to last missing).
    fn decode_missing(&mut self, src: &Arc<MediaSource>, k: &Key, lo: i64, hi: i64) {
        let missing: Vec<i64> = (lo..=lo.max(hi))
            .filter(|i| {
                let key = Key { index: *i, ..*k };
                !self.cache.contains_key(&key) && !self.in_flight.contains(&key) && !self.has_failed(&key)
            })
            .collect();
        if let (Some(first), Some(last)) = (missing.first(), missing.last()) {
            self.decode(src, k, *first..=*last);
        }
    }

    /// Playing backwards: a long-GOP decoder reaches a frame only from its GOP's sync sample, so asking for one frame per
    /// tick decoded the GOP once per frame and the monitor showed stand-ins only. Instead the window from the sync sample
    /// up to the playhead decodes forward once and plays backwards out of the cache; once the playhead is within
    /// `REVERSE_LEAD` frames of the window's start, the window before it is asked for too (Swift: `Prefetch` reverse
    /// window, one GOP per decode).
    fn request_reverse(&mut self, k: Key, claimed: &mut HashMap<Id, HashSet<usize>>) {
        let Some(base) = self.source_of(&k) else { return };
        let window = |i: i64| -> i64 {
            let start = usize::try_from(i).map_or(0, |u| base.demuxer.index().decode_start_index(u)) as i64;
            // shortcut: a GOP longer than REVERSE_WINDOW decodes from its sync sample again for each window (bounded
            // memory, more decoding); a per-GOP decode that keeps every picture would need the budget to allow it.
            start.max(i - REVERSE_WINDOW).max(0)
        };
        let lo = window(k.index);
        let Some(src) = self.lane_for(&Key { index: lo, ..k }, k.index - lo, claimed, false) else { return };
        self.decode_missing(&src, &k, lo, k.index);
        if lo > 0 && k.index - lo < REVERSE_LEAD {
            let before = lo - 1;
            self.decode_missing(&src, &k, window(before), before);
        }
    }

    /// While playing, every 10 refreshes: opens the files of the clips 0.5 to 3.5 s ahead and decodes their first frames
    /// there, so a cut does not wait for an open and a cold decoder. A picture a playing lane reads toward is left to it.
    fn prefetch(&mut self, claimed: &mut HashMap<Id, HashSet<usize>>) {
        self.prefetch_countdown -= 1;
        if self.prefetch_countdown > 0 {
            return;
        }
        self.prefetch_countdown = 10;
        let fd = self.timeline.frame_duration();
        let speed = f64::from(self.state.rate().num()) / f64::from(self.state.rate().den());
        let mut keys: Vec<Key> = Vec::new();
        for seconds in super::power_policy::prefetch_seconds(self.prefetch_halved) {
            let frames = (seconds * speed * fd.timescale() as f64 / fd.value() as f64).round() as i64;
            let mut t = self.position + fd * frames;
            // Looping: what lies past the wrap is decoded before the clock gets there.
            if let Some(r) = self.loop_region()
                && r.contains(self.position)
            {
                t = wrapped(t, r);
            }
            if t < Time::ZERO {
                continue;
            }
            for l in self.layers_at(t).into_iter().filter(|l| l.generator.is_none()) {
                // Deviation from the Swift engine: a clip already on screen keeps reading on its own lane (the Swift loop
                // opened a lane for every far-ahead index of the clip it was playing: 4 decoders for one clip in 5 s).
                if self.wanted_requests.iter().any(|w| w.clip == l.clip) {
                    continue;
                }
                // A clip that shows up before `t`: warm its first visible frame, where the cut (or a transition's incoming
                // side, which shows the clip before its own start) lands.
                let first = self.first_visible(l.clip, self.position, t).unwrap_or_else(|| l.clone());
                if let Some(k) = self.key_for(&first)
                    && !keys.contains(&k)
                {
                    keys.push(k);
                }
            }
        }
        self.prefetch_keys.clone_from(&keys);
        for k in keys {
            self.request(k, 3, claimed, true);
        }
    }

    /// The layer of `clip` at the first frame in (`from`, `to`] where it shows, `to` being a frame where it does and `from` one
    /// where it does not (`first_visible.rs`: a coarse scan, then halving, so a look-ahead of seconds costs a handful of layer
    /// plans and a hidden middle part cannot hide the first visible one). A transition's incoming clip shows before its own
    /// start (the dissolve starts a second early): warming only its start left the first frames of the dissolve to a cold
    /// decode, one frame lost at the dissolve and stand-ins while the lane caught up.
    fn first_visible(&self, clip: Id, from: Time, to: Time) -> Option<LayerRequest> {
        let fd = self.timeline.frame_duration();
        let layer_at = |frame: i64| self.layers_at(fd * frame).into_iter().find(|x| x.clip == clip);
        let end = to.frame_index(fd);
        let at_end = layer_at(end)?;
        let frame = super::first_visible::earliest_visible(
            from.frame_index(fd),
            end,
            super::first_visible::scan_stride(fd),
            |f| layer_at(f).is_some(),
        );
        Some(if frame == end { at_end } else { layer_at(frame).unwrap_or(at_end) })
    }

    fn decode(&mut self, src: &Arc<MediaSource>, key: &Key, range: RangeInclusive<i64>) {
        sq_core_time::milestones::mark("first decode request");
        let media = key.media;
        let keys: Vec<Key> = range.clone().map(|i| Key { index: i, ..*key }).collect();
        self.in_flight.extend(keys.iter().copied());
        let scale = self.quality;
        let reduce = key.divisor.max(1);
        let name = self
            .media_paths
            .get(&media)
            .and_then(|p| std::path::Path::new(p).file_name())
            .map_or_else(|| media.to_string(), |n| n.to_string_lossy().into_owned());
        // Scrubbing a clip only software can decode: the decoder skips its loop filter.
        let preview = self.state.is_scrubbing() && src.can_preview();
        if self.state.is_scrubbing() {
            src.set_preview(preview);
        }
        let threaded = !self.state.rate().is_paused();
        let token = self.cancel.entry(media).or_default().clone();
        let (gate, tx, stats, src) =
            (Arc::clone(&self.want_gate), self.tx.clone(), Arc::clone(&self.stats), Arc::clone(src));
        let proxy = key.proxy;
        self.pool.submit(src.id, move || {
            // The finish message goes out even when the job panics or is dropped as stale.
            struct Finish {
                tx: Sender<Msg>,
                keys: Vec<Key>,
                error: Option<String>,
            }
            impl Drop for Finish {
                fn drop(&mut self) {
                    let _ =
                        self.tx.send(Msg::Finished { keys: std::mem::take(&mut self.keys), error: self.error.take() });
                }
            }
            let mut finish = Finish { tx: tx.clone(), keys, error: None };
            // The decoder is free now: a scrub moved on if nothing in the range is wanted any more.
            if token.is_cancelled() || gate.is_stale(media, &range) {
                return;
            }
            let deliver: Arc<dyn Fn(i64, Picture) + Send + Sync> = {
                let (tx, token) = (tx.clone(), token.clone());
                Arc::new(move |i, picture| {
                    if !token.is_cancelled() {
                        let key = Key { media, index: i, proxy, divisor: reduce };
                        let _ = tx.send(Msg::Decoded { key, picture, scale, preview });
                    }
                })
            };
            if let Err(e) = src.stream_pictures(range.clone(), reduce, threaded, &stats, deliver) {
                finish.error = Some(format!("decode {name} {range:?}: {e}"));
            }
        });
    }

    /// A picture arrived from a lane.
    fn decoded(&mut self, key: Key, p: Picture, scale: DecodeScale, preview: bool) {
        if let Some((at, false)) = self.play_logged {
            self.play_logged = Some((at, true));
            sq_core_time::milestones::note(&format!(
                "play: first decode after Play at {:.0} ms (frame {}, divisor {}, proxy {})",
                at.elapsed().as_secs_f64() * 1e3,
                key.index,
                key.divisor,
                key.proxy
            ));
        }
        sq_core_time::milestones::mark(&format!("first frame decoded media {}", key.media));
        self.in_flight.remove(&key);
        if preview {
            if !self.state.is_scrubbing() {
                return;
            }
            self.preview_keys.insert(key);
        }
        if scale != self.quality {
            return; // decoded for the quality before a change (the cache was dropped)
        }
        // A long-GOP decode delivers every picture from the keyframe on; composing for each one stalls the thread many
        // times per frame. Compose only when this picture is wanted or is nearer to a wanted one than anything cached.
        let useful = match &self.wanted {
            None => true,
            Some(w) => w.keys.iter().any(|wk| {
                if wk.media != key.media || wk.proxy != key.proxy {
                    return false;
                }
                if *wk == key {
                    return true;
                }
                let d = (key.index - wk.index).abs();
                !self
                    .cache
                    .keys()
                    .any(|c| c.media == wk.media && c.proxy == wk.proxy && (c.index - wk.index).abs() <= d)
            }),
        };
        if let Some(old) = self.cache.insert(key, p.clone()) {
            self.cache_bytes -= old.bytes;
        }
        self.cache_bytes += p.bytes;
        self.cache_generation += 1;
        if !useful {
            return;
        }
        // Scrubbing: the playhead moves every frame and composes then; an arrival only marks the picture (tick draws it
        // when the playhead stood still), so one frame never uploads and composes a 4K picture twice.
        if self.state.is_scrubbing() {
            self.compose_pending = true;
        } else {
            self.compose();
        }
    }

    /// A decode ended: keys it did not deliver are free to ask for again.
    fn finished(&mut self, keys: &[Key], error: Option<String>) {
        let left: Vec<Key> = keys.iter().copied().filter(|k| self.in_flight.contains(k)).collect();
        for k in &left {
            self.in_flight.remove(k);
        }
        let failed = error.is_some();
        if let Some(e) = error {
            self.last_error = Some(e);
            let now = Instant::now();
            for k in &left {
                if !self.cache.contains_key(k) && !k.proxy {
                    self.failed_keys.insert(*k, now);
                }
            }
            self.compose();
        }
        // A scrub drops most of its queued decodes as stale (nothing delivered): refreshing for each one planned and composed
        // the frame again. Refresh only when a picture the monitor still wants is missing.
        let wants_missing = self.wanted.as_ref().is_none_or(|w| w.keys.iter().any(|k| left.contains(k)));
        if !left.is_empty() && (failed || !self.state.rate().is_paused() || wants_missing) {
            self.refresh();
        }
    }

    // MARK: Lanes

    /// One decoder over a file and where it reads. Two clips of one long-GOP file on screen at once each read on their own
    /// lane; on one decoder every frame would seek back to the other clip's GOP.
    /// The decoder for `k`: a lane not yet claimed in this frame that reads toward it, else a free lane (which seeks), else
    /// a new lane opened off the render thread (`None` until it is open; at most `MAX_LANES` per file). A prefetch picture
    /// that any lane already reads toward is left to it. Intra-only files read on one decoder.
    fn lane_for(
        &mut self,
        k: &Key,
        ahead: i64,
        claimed: &mut HashMap<Id, HashSet<usize>>,
        prefetching: bool,
    ) -> Option<Arc<MediaSource>> {
        if k.proxy {
            return self.proxy_sources.get(&k.media).cloned();
        }
        let base = Arc::clone(self.sources.get(&k.media)?);
        if !self.lanes.contains_key(&k.media) {
            self.lanes.insert(k.media, vec![Lane::new(Arc::clone(&base), self.refresh_count)]);
        }
        if self.intra_only(k.media, &base) {
            // One decoder serves every clip of the file; a prefetch of a file on screen would only decode twice.
            if prefetching && claimed.contains_key(&k.media) {
                return None;
            }
            claimed.entry(k.media).or_default().insert(0);
            return Some(base);
        }
        let taken = claimed.get(&k.media).cloned().unwrap_or_default();
        let refresh_count = self.refresh_count;
        let all = self.lanes.get_mut(&k.media)?;
        if prefetching && all.iter().any(|l| l.reaches(k.index)) {
            return None;
        }
        let free: Vec<usize> = (0..all.len()).filter(|i| !taken.contains(i)).collect();
        let pick = free
            .iter()
            .copied()
            .find(|i| all[*i].reaches(k.index))
            .or_else(|| free.iter().copied().find(|i| all[*i].at.is_none()))
            .or_else(|| free.first().copied());
        let Some(i) = pick else {
            // Every lane serves another picture of this frame: open one more; past the limit (or for a prefetch while one
            // opens) a current picture shares lane 0, which seeks but keeps the frame coming.
            if all.len() < MAX_LANES {
                self.open_lane(k.media);
                return None;
            }
            return if prefetching { None } else { Some(base) };
        };
        claimed.entry(k.media).or_default().insert(i);
        let seeks = !all[i].reaches(k.index);
        let lane = &mut all[i];
        if seeks {
            lane.to = k.index - 1; // this lane seeks
        }
        lane.at = Some(k.index);
        lane.to = lane.to.max((lane.source.frame_count() as i64 - 1).min(k.index + ahead));
        lane.used = refresh_count;
        Some(Arc::clone(&lane.source))
    }

    fn open_lane(&mut self, media: Id) {
        let Some(path) = self.media_paths.get(&media).cloned() else { return };
        if !self.lane_opening.insert(media) {
            return;
        }
        self.spawn_open(media, path, true);
    }

    /// Every frame of the file decodes alone (ProRes, MJPEG): a jump costs one frame, one decoder serves all clips.
    fn intra_only(&mut self, media: Id, s: &MediaSource) -> bool {
        if let Some(v) = self.intra_files.get(&media) {
            return *v;
        }
        let v = s.demuxer.index().entries().iter().all(|e| e.is_sync);
        self.intra_files.insert(media, v);
        v
    }

    /// Closes extra lanes no frame used for about 90 refreshes (each holds a decoder with its threads and buffers).
    fn drop_idle_lanes(&mut self) {
        if !self.refresh_count.is_multiple_of(30) {
            return;
        }
        let now = self.refresh_count;
        let mut graveyard = Vec::new();
        for all in self.lanes.values_mut().filter(|a| a.len() > 1) {
            let mut kept = Vec::new();
            for (n, l) in std::mem::take(all).into_iter().enumerate() {
                if n == 0 || now - l.used < 90 {
                    kept.push(l);
                } else {
                    graveyard.push(l);
                }
            }
            *all = kept;
        }
        if !graveyard.is_empty() {
            // Closing a decoder takes 15-30 ms: not on the render thread.
            let _ = std::thread::Builder::new().name("sq-graveyard".into()).spawn(move || drop(graveyard));
        }
    }

    // MARK: Scrub fill

    /// The pictures a resting playhead may fill the cache with, nearest first, in the direction it moved first: the
    /// missing frames of `position - FILL_BEHIND ..= position + FILL_AHEAD` (the longer side is the scrub direction).
    fn fill_keys(&self, key: &Key, max_index: i64) -> Vec<Key> {
        let (ahead, behind) =
            if self.scrub_direction >= 0 { (FILL_AHEAD, FILL_BEHIND) } else { (FILL_BEHIND, FILL_AHEAD) };
        let lo = (key.index - behind).max(0);
        let hi = (key.index + ahead).min(max_index);
        let mut keys: Vec<Key> = (lo..=hi).filter(|i| *i != key.index).map(|i| Key { index: i, ..*key }).collect();
        keys.sort_by_key(|k| ((k.index - key.index).abs(), k.index));
        keys
    }

    /// While paused (also between scrub steps): once the frame on screen is settled, one decode per tick fills the cache
    /// around the playhead (ahead and behind, `FILL_*`), a chunk of at most `FILL_CHUNK` frames. A long-GOP decode
    /// starts at the keyframe and keeps every picture it passes, so a step back or a drag over the same stretch finds its
    /// pictures cached. The next playhead position makes queued fills stale (the want gate); the cache trim drops the
    /// farthest pictures first, and no fill runs once the cache holds three quarters of its budget.
    fn fill_step(&mut self) {
        let settled = self.shown.is_some()
            && self.shown == self.wanted
            && self.in_flight.is_empty()
            && self.opening.is_empty()
            && self.lane_opening.is_empty();
        // `SQ_SCRUB_FILL=0` turns the fill off (A/B in the engine benchmark).
        if !self.fill_enabled || !settled || self.cache_bytes > self.frame_cache_bytes / 4 * 3 {
            return;
        }
        let Some(w) = self.wanted.clone() else { return };
        let mut claimed: HashMap<Id, HashSet<usize>> = HashMap::new();
        for key in w.keys.iter().filter(|k| !k.proxy) {
            let Some(src) = self.sources.get(&key.media).cloned() else { continue };
            let missing: Vec<Key> = self
                .fill_keys(key, src.frame_count() as i64 - 1)
                .into_iter()
                .filter(|k| !self.cache.contains_key(k) && !self.in_flight.contains(k) && !self.has_failed(k))
                .collect();
            let Some(first) = missing.first() else { continue };
            // The run of missing frames around the nearest one, capped; frames behind the playhead are decoded forward from
            // their start, so the run is asked from its lowest index.
            let side = if first.index < key.index { -1 } else { 1 };
            let run: Vec<i64> = missing.iter().map(|k| k.index).filter(|i| (i < &key.index) == (side < 0)).collect();
            let (lo, hi) =
                (run.iter().copied().min().unwrap_or(first.index), run.iter().copied().max().unwrap_or(first.index));
            let (lo, hi) =
                if side < 0 { ((hi - FILL_CHUNK + 1).max(lo), hi) } else { (lo, (lo + FILL_CHUNK - 1).min(hi)) };
            let span: Vec<Key> = (lo..=hi).map(|i| Key { index: i, ..*key }).collect();
            self.want_gate.extend(&span);
            self.fill_request(key, lo, hi, &mut claimed);
            return; // one decode per tick
        }
    }

    fn fill_request(&mut self, key: &Key, lo: i64, hi: i64, claimed: &mut HashMap<Id, HashSet<usize>>) {
        let start = Key { index: lo, ..*key };
        self.request(start, hi - lo, claimed, false);
    }

    // MARK: Warm-up

    /// Decoder warm-up while paused: after the playhead rests 0.1 s, the layers at it decode their first playback frames
    /// (playback divisor), one layer per 80 ms once the last decode is done, so a play right after an open finds the
    /// decoders open, positioned and ahead instead of six 4K decoders starting at once.
    fn warm_step(&mut self) {
        let now = Instant::now();
        let settled = self.shown.is_some()
            && self.shown == self.wanted
            && self.in_flight.is_empty()
            && self.opening.is_empty()
            && self.lane_opening.is_empty();
        if !settled {
            return;
        }
        if self.warm_position != Some(self.position) {
            self.warm_position = Some(self.position);
            self.warm_since = Some(now);
            self.warm_queue.clear();
            return;
        }
        if self.warm_since.is_some_and(|s| now - s >= Duration::from_millis(100)) {
            self.warm_since = None;
            self.transition(Event::BeginWarm);
            let layers = self.layers_at(self.position);
            let keys: Vec<Key> = layers.iter().filter_map(|l| self.key_for(l)).collect();
            self.transition(Event::EndWarm);
            // The grades of these layers (LUT files read, first-use setup) are assembled off the render thread now, so the
            // first play frame finds them served. The clips of the next 12 s too: a cut during play must not stall.
            if let Some(resolver) = self.deps.color.clone() {
                let fd = self.timeline.frame_duration();
                let mut ahead = layers.clone();
                let mut seen: HashSet<Id> = layers.iter().map(|l| l.clip).collect();
                for half in 1..=24i64 {
                    let step = (half as f64 * 0.5 * fd.timescale() as f64 / fd.value() as f64).round() as i64;
                    let t = (self.position + fd * step).snapped(fd);
                    for l in self.layers_at(t) {
                        if l.generator.is_none() && seen.insert(l.clip) {
                            ahead.push(l);
                        }
                    }
                }
                let pairs: Vec<_> =
                    ahead.iter().filter(|l| l.generator.is_none()).map(|l| (l.color.clone(), l.media)).collect();
                resolver.warm(&pairs);
            }
            let mut seen = HashSet::new();
            self.warm_queue = keys.into_iter().filter(|k| seen.insert(*k)).collect();
        }
        if self.warm_queue.is_empty() || now - self.warm_last < Duration::from_millis(80) {
            return;
        }
        self.warm_last = now;
        let k = self.warm_queue.remove(0);
        let mut claimed = HashMap::new();
        self.transition(Event::BeginWarm);
        self.request(k, 8, &mut claimed, false);
        self.transition(Event::EndWarm);
    }

    // MARK: Compose

    /// Creates the compositor once. A failure is final, kept as `compositor_failure` (the monitor shows it) and also
    /// reported as `last_error`; the picture stays empty, but never silently.
    pub(crate) fn ensure_compositor(&mut self, make: impl FnOnce() -> Result<ProgramCompositor, String>) {
        if !self.compositor.needs_creation() {
            return;
        }
        sq_core_time::milestones::mark("compositor creation start");
        let made = make();
        sq_core_time::milestones::mark("compositor created");
        self.compositor.settle(made);
        if let Some(e) = self.compositor.failure() {
            self.last_error = Some(format!("compositor: {e}"));
        }
    }

    /// Why the picture cannot be drawn (the compositor could not be created), or `None`.
    pub fn compositor_failure(&self) -> Option<&str> {
        self.compositor.failure()
    }

    /// The decoded picture for `k`, or the same frame of the same file at another size (play start after a paused
    /// full-detail frame, a divisor change). While playing (`stand_in`), a frame still decoding shows the nearest decoded
    /// one of the same file (at most `STAND_IN_REACH` frames away) instead of nothing, and the exact picture replaces it on
    /// arrival (`shown_exact`).
    /// Returns the key of the picture handed out: a stand-in or another size is drawn (and its planes cached) as what it is,
    /// never under the wanted key (the exact picture would reuse the stand-in's planes).
    fn picture_for(&self, k: &Key, stand_in: bool) -> Option<(Key, Picture)> {
        if let Some(p) = self.cache.get(k) {
            return Some((*k, p.clone()));
        }
        if let Some((c, p)) =
            self.cache.iter().find(|(c, _)| c.media == k.media && c.index == k.index && c.proxy == k.proxy)
        {
            return Some((*c, p.clone()));
        }
        if !(stand_in && (!self.state.rate().is_paused() || self.state.is_scrubbing())) {
            return None;
        }
        let near: Vec<(&Key, &Picture)> = self
            .cache
            .iter()
            .filter(|(c, _)| c.media == k.media && c.proxy == k.proxy && (c.index - k.index).abs() <= STAND_IN_REACH)
            .collect();
        let forward = self.state.rate().num() >= 0;
        let floor = self.played_through.get(&k.media).copied();
        let index =
            stand_in_index(near.iter().map(|(c, _)| c.index), k.index, self.state.is_scrubbing(), forward, floor)?;
        near.into_iter().filter(|(c, _)| c.index == index).min_by_key(|(c, _)| c.divisor).map(|(c, p)| (*c, p.clone()))
    }

    fn caption_layers(&self) -> Vec<caption_plan::CaptionLayerRequest> {
        let Some(planner) = &self.deps.planner else { return Vec::new() };
        if !self.shows_captions || self.timeline.caption_tracks.is_empty() {
            return Vec::new();
        }
        let slots = self.captions.slots(self.position);
        if slots.is_empty() {
            return Vec::new();
        }
        let previewed = self.look_preview.as_ref().and_then(|p| planner.previewed(p));
        let planner = previewed.as_ref().unwrap_or(planner);
        caption_plan::layers(&self.timeline, &slots, self.position, planner.as_ref(), self.state.rate().num() >= 0)
    }

    /// Draws the wanted frame once all its pictures are decoded (and no file it needs is still opening).
    fn compose(&mut self) {
        self.compose_pending = false;
        self.compose_retry = false;
        let Some(want) = self.wanted.clone() else { return };
        if self.shown.as_ref() == Some(&want) && self.shown_exact {
            return;
        }
        if !want.keys.iter().all(|k| self.picture_for(k, true).is_some() || self.has_failed(k)) {
            return;
        }
        if !self.opening.is_empty() && self.wanted_requests.iter().any(|r| self.opening.contains(&r.media)) {
            return;
        }
        let captions = self.caption_layers();
        let has_generator = self.wanted_requests.iter().any(|r| r.generator.is_some());
        if want.keys.is_empty() && !self.shows_transparency_grid && captions.is_empty() && !has_generator {
            self.display(None, None, &want);
            return;
        }
        let Some(gpu) = self.deps.gpu.clone() else {
            // Headless: nothing to draw on; the frame counts as shown so the clock and statistics keep running.
            self.display(None, None, &want);
            return;
        };
        self.ensure_compositor(|| ProgramCompositor::new(&gpu).map_err(|e| e.to_string()));
        let Some(mut comp) = self.compositor.take() else {
            self.display(None, None, &want);
            return;
        };
        let result = self.render_with(&mut comp, &captions);
        self.compositor.give_back(comp);
        match result {
            Ok((frame, linear, ms)) => {
                sq_core_time::milestones::mark("first composite done");
                if !self.state.rate().is_paused() {
                    self.compose_sum += ms;
                    self.compose_count += 1;
                    self.stats.add(Stage::Compose, ms, 1);
                    self.stats.frame(want.keys.len(), 0);
                    self.stats.av_drift(self.deps.clock.now(), self.position);
                    let forward = self.state.rate().num() >= 0;
                    for k in &want.keys {
                        if let Some((drawn, _)) = self.picture_for(k, true) {
                            let f = self.played_through.entry(k.media).or_insert(drawn.index);
                            *f = if forward { (*f).max(drawn.index) } else { (*f).min(drawn.index) };
                        }
                    }
                }
                self.display(Some(frame), Some(linear), &want);
            }
            // Dropped, not failed: the GPU still runs two earlier frames. The frame position that never shows counts as
            // skipped, and the wanted frame is composited again on the next loop.
            Err(ProgramError::GpuBusy) => {
                self.compose_retry = true;
                if !self.state.rate().is_paused() {
                    self.stats.add(Stage::GpuBusy, GPU_WAIT_PLAYING.as_secs_f64() * 1e3, 1);
                }
            }
            Err(e) => self.last_error = Some(format!("compose: {e}")),
        }
    }

    fn render_with(
        &self,
        comp: &mut ProgramCompositor,
        captions: &[caption_plan::CaptionLayerRequest],
    ) -> Result<(sq_gpu::frames::GpuTexture, sq_gpu::frames::GpuTexture, f64), sq_render::program::ProgramError> {
        let format = self.timeline.format.clone();
        let resolver = self.deps.color.clone();
        let graded =
            |l: &LayerRequest| resolver.as_ref().and_then(|r| r.pipeline_blocking(&l.color, l.media, Some(l.clip)));
        // Before: the bypassed clips ungraded; Split: graded, the ungraded composite over the left half.
        let bypass = self.color_bypass.clone();
        let ungraded = |l: &LayerRequest| match bypass.as_ref().and_then(|b| b.ungraded(l.clip, &l.color)) {
            Some((color, owner)) => resolver.as_ref().and_then(|r| r.pipeline_blocking(&color, l.media, Some(owner))),
            None => graded(l),
        };
        let split = bypass.as_ref().is_some_and(ColorBypass::is_split);
        let grade: &dyn Fn(&LayerRequest) -> Option<Arc<sq_render::color::pipeline::ColorPipeline>> =
            if bypass.is_none() || split { &graded } else { &ungraded };
        let columns = u32::try_from(ColorBypass::split_width(format.width)).unwrap_or(0);
        let rasters = self.deps.rasters.clone();
        let source = |l: &LayerRequest| -> LayerSource {
            if l.generator.is_some() {
                // A plain text clip's animations need its length (the out phase); only graphics layers carry it.
                let mut sized;
                let l = if l.clip_duration.is_none() {
                    sized = l.clone();
                    sized.clip_duration = self.clip_length(l.clip);
                    &sized
                } else {
                    l
                };
                // A Look hover preview swaps the text drawn (display only).
                let mut previewed;
                let l = match (&l.generator, &self.look_preview) {
                    (Some(g), Some(preview)) => {
                        let container = l.groups.last().map_or(l.clip, |g| g.clip);
                        let to = LookPreview::text(Some(preview), g, container, l.clip);
                        if to == g {
                            l
                        } else {
                            previewed = l.clone();
                            previewed.generator = Some(to.clone());
                            &previewed
                        }
                    }
                    _ => l,
                };
                let Some(p) = rasters.as_ref() else { return LayerSource::Hidden };
                return match p.layer(l, &format) {
                    Some(r) => LayerSource::Raster(r),
                    None if p.is_offline(l, &format) => LayerSource::Offline,
                    None => LayerSource::Hidden,
                };
            }
            let missing = || {
                if self.open_failed.contains_key(&l.media) || !self.media_paths.contains_key(&l.media) {
                    LayerSource::Offline
                } else {
                    LayerSource::Hidden
                }
            };
            let Some(k) = self.peek_key(l) else { return missing() };
            let (Some((shown, pic)), Some(src)) = (self.picture_for(&k, true), self.sources.get(&k.media)) else {
                return missing();
            };
            // Gyroflow Stabilizer: the decoded frame is warped by the camera's gyro data before anything else (the same call
            // for export; a proxy frame is warped with the original's gyro data, the map is normalized).
            let gyro = l.gyro.as_ref().and_then(|o| {
                let hook = self.deps.gyro.as_ref()?;
                let path = self.media_paths.get(&l.media)?;
                let ts = sq_core_masks::GyroflowOptions::timestamp_microseconds(pic.frame.presentation_time);
                hook.maps.map(path, o, ts, hook.wait)
            });
            LayerSource::Media(Source {
                media: shown.media,
                index: shown.index,
                gyro,
                frame: pic.frame,
                info: src.info.clone(),
                proxy: shown.proxy,
                divisor: shown.divisor,
            })
        };
        let caption_rasters: Vec<_> = rasters
            .as_ref()
            .map(|p| captions.iter().filter_map(|c| p.caption(c, &format)).collect())
            .unwrap_or_default();
        // Playing drops a frame the GPU cannot take yet; a paused picture and every export frame wait for it.
        let playing = !self.state.rate().is_paused();
        // A paused picture on a GPU that stopped answering waits up to 30 s: a Stop or Seek queued meanwhile ends that wait
        // (the frame is drawn again after the command). Playing waits 8 ms at most, so it needs no such look.
        let shared = Arc::clone(&self.shared);
        let abandon_wait: Option<Arc<dyn Fn() -> bool + Send + Sync>> =
            (!playing).then(|| Arc::new(move || shared.command_waiting()) as _);
        let options = RenderOptions {
            transparent: self.shows_transparency_grid,
            captions: caption_rasters,
            gpu_wait: playing.then_some(GPU_WAIT_PLAYING),
            abandon_wait,
            ..RenderOptions::default()
        };
        let inputs =
            Inputs { grade, split: split.then_some((&ungraded as &_, columns)), mattes: None, source: &source };
        let frame = comp.render(&self.wanted_requests, &format, &options, &inputs)?;
        if playing {
            self.stats.add(Stage::GpuWait, frame.gpu_wait_ms, 1);
        }
        Ok((frame.output, frame.working, frame.milliseconds))
    }

    /// Length of a clip of the top sequence on the timeline.
    fn clip_length(&self, clip: Id) -> Option<Time> {
        self.timeline.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == clip).map(|c| c.duration())
    }

    /// How far behind a layer is that has no picture of its file at all: every frame since Play started (0 when not playing).
    fn frames_without_picture(&self) -> i64 {
        if self.state.rate().is_paused() {
            return 0;
        }
        let here = self.position.frame_index(self.timeline.frame_duration());
        self.played_span.map_or(0, |(start, _)| (here - start).abs())
    }

    fn display(
        &mut self,
        output: Option<sq_gpu::frames::GpuTexture>,
        linear: Option<sq_gpu::frames::GpuTexture>,
        want: &Wanted,
    ) {
        self.shown = Some(want.clone());
        self.shown_lag = want
            .keys
            .iter()
            .map(|k| {
                if self.cache.contains_key(k) {
                    0
                } else {
                    self.cache
                        .keys()
                        .filter(|c| c.media == k.media && c.proxy == k.proxy)
                        .map(|c| (c.index - k.index).abs())
                        .min()
                        .unwrap_or_else(|| self.frames_without_picture())
                }
            })
            .max()
            .unwrap_or(0);
        self.shown_exact = want.keys.iter().all(|k| self.cache.contains_key(k));
        self.picture_present = output.is_some();
        self.picture_generation += 1;
        let frame = output.map(|t| {
            let size = (t.width(), t.height());
            Arc::new(GpuFrame {
                planes: vec![t],
                layout: PlaneLayout::Rgba8Straight,
                size,
                color: SQFrameColorSpace::Rec709,
                pts: self.position,
                keep: None,
            })
        });
        if crate::probe::enabled() {
            let probe = crate::probe::PlayProbe::shared();
            if probe.awaiting_frame() == Some(self.position) {
                let now = crate::probe::now();
                probe.note(crate::probe::Stage::FirstFrame, None, now);
                if self.shown_exact {
                    probe.note(crate::probe::Stage::Exact, None, now);
                }
            }
        }
        if let Some((at, _)) = self.play_logged.take() {
            sq_core_time::milestones::note(&format!(
                "play: first picture after Play published at {:.0} ms (frame {})",
                at.elapsed().as_secs_f64() * 1e3,
                self.position.frame_index(self.timeline.frame_duration())
            ));
        }
        self.shared.publish(Shown {
            generation: self.picture_generation,
            position: self.position,
            frame,
            linear,
            exact: self.shown_exact,
        });
        if let Some(f) = &self.deps.on_shown {
            f();
        }
        if !self.state.rate().is_paused() {
            let frame = self.position.frame_index(self.timeline.frame_duration());
            self.skipped_frames += skipped_in_run(self.last_shown_frame, frame, self.state.rate().is_forward());
            if Some(frame) != self.last_shown_frame {
                self.shown_frames += 1; // not again when the exact picture replaces a stand-in
            }
            self.last_shown_frame = Some(frame);
            self.late.shown(frame, self.shown_exact, self.shown_lag);
            if let Some(s) = self.played_span.as_mut() {
                s.1 = frame;
            }
        }
    }

    // MARK: Cache strip

    /// Timeline spans whose pictures are all decoded (the ruler's cache strip): the frames around the playhead the cache
    /// window covers; a gap or a clip with a missing picture ends a span. Generated layers need no picture.
    pub fn cached_spans(&self) -> Vec<TimeRange> {
        let fd = self.timeline.frame_duration();
        let here = self.position.frame_index(fd);
        let ids: HashSet<(Id, i64)> = self.cache.keys().map(|k| (k.media, k.index)).collect();
        let playing = !self.state.rate().is_paused();
        let first = (here - if playing { 240 } else { 450 }).max(0);
        let last = here + if playing { 120 } else { 450 };
        let mut spans = Vec::new();
        let mut open: Option<i64> = None;
        let mut f = first;
        while f <= last {
            let layers = self.layers_at(fd * f);
            let ready = !layers.is_empty()
                && layers.iter().all(|l| {
                    l.generator.is_some() || self.peek_key(l).is_some_and(|k| ids.contains(&(k.media, k.index)))
                });
            if ready {
                open.get_or_insert(f);
            } else if let Some(a) = open.take() {
                spans.push(TimeRange::from_end(fd * a, fd * f));
            }
            f += 4;
        }
        if let Some(a) = open {
            spans.push(TimeRange::from_end(fd * a, fd * (last + 1)));
        }
        spans
    }
}

impl Status {
    pub fn is_playing(&self) -> bool {
        self.rate.is_some_and(|r| !r.is_paused())
    }
}

/// Frame positions that went by unseen between two shown frames of a normal run in the play direction; a jump against the
/// direction or no earlier frame counts nothing.
pub(super) fn skipped_in_run(last: Option<i64>, frame: i64, forward: bool) -> u64 {
    let Some(last) = last else { return 0 };
    let step = if forward { frame - last } else { last - frame };
    u64::try_from(step - 1).unwrap_or(0)
}
