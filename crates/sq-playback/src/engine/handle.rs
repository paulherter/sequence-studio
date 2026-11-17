// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: the @MainActor surface of WinProgramEngine (ProgramEngine protocol), as messages to the render thread
//! The thread shell: `ProgramHandle` is what the UI thread holds. Every call becomes a message over `mpsc` to the render
//! thread that owns the [`ProgramEngine`]; the latest shown frame goes back through a mailbox, positions through the
//! `on_position` callback (the host posts it to its UI queue).

use super::caption_plan::{CaptionLayerRequest, CaptionPlanner};
use super::core::ProgramEngine;
use super::look_preview::LookPreview;
use super::types::Key;
use super::types::{MediaRef, Picture};
use sq_audio_out::clock::PlaybackClock;
use sq_core_color::ColorBypass;
use sq_core_edit::playback::PlaybackRate;
use sq_core_effects::evaluation::LayerRequest;
use sq_core_model::{SequenceFormat, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_gpu::frames::GpuFrame;
use sq_gpu::gpu::Gpu;
use sq_media::media_opener::MediaOpener;
use sq_media::video_decoding::DecodeScale;
use sq_render::compositor::LayerColorResolver;
use sq_render::program::Raster;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;

/// Draws the rasters the engine does not own: titles, shapes and Lottie layers, and caption layers (premultiplied linear
/// Rec.709 floats). Must answer without blocking for long; the engine calls it on the render thread.
pub trait RasterProvider: Send + Sync {
    fn layer(&self, request: &LayerRequest, canvas: &SequenceFormat) -> Option<Raster>;
    fn caption(&self, layer: &CaptionLayerRequest, canvas: &SequenceFormat) -> Option<Raster>;
    /// A generator layer that cannot be read at all (an unreadable Lottie file, an undecodable Date Stamp) shows the offline
    /// slate instead of nothing. Asked only after `layer` returned `None`.
    fn is_offline(&self, _request: &LayerRequest, _canvas: &SequenceFormat) -> bool {
        false
    }
}

/// What the engine runs on.
pub struct EngineDeps {
    /// The device: `None` = headless without a GPU, the engine plans and decodes but shows nothing.
    pub gpu: Option<Arc<Gpu>>,
    pub opener: Arc<dyn MediaOpener>,
    /// The master clock: a `SwitchingClock` (audio clock, host clock as fallback) or a host / manual clock.
    pub clock: Arc<dyn PlaybackClock>,
    pub color: Option<Arc<LayerColorResolver>>,
    /// The Gyroflow engine: layers whose Stabilizer uses Gyroflow are warped with its maps (playback and export alike).
    pub gyro: Option<GyroHook>,
    pub rasters: Option<Arc<dyn RasterProvider>>,
    pub planner: Option<Arc<dyn CaptionPlanner>>,
    /// Called on the render thread when the position changed (the host posts it to its UI queue).
    pub on_position: Option<Arc<dyn Fn(Time) + Send + Sync>>,
    /// Called on the render thread after a new composite was published (the host wakes its idle window).
    pub on_shown: Option<Arc<dyn Fn() + Send + Sync>>,
    /// The Program monitor's share of `MemoryBudget` (bytes of pictures; GPU bytes count).
    pub frame_cache_bytes: usize,
    /// The window loop's frame ticks (display lead and frame phase lock); `None` = the clock decides alone (headless, tests).
    pub display: Option<Arc<super::display_pacing::DisplayTiming>>,
    /// Decode threads (<= 4).
    pub workers: usize,
}

/// The gyro engine and how it is asked: `wait` blocks a frame until the clip's analysis is done (export), otherwise a clip
/// that is not analyzed yet shows unwarped and the engine's observer redraws when it is (playback).
#[derive(Clone)]
pub struct GyroHook {
    pub maps: Arc<dyn sq_render::program::GyroMaps>,
    pub wait: bool,
}

impl EngineDeps {
    pub fn new(opener: Arc<dyn MediaOpener>, clock: Arc<dyn PlaybackClock>) -> EngineDeps {
        EngineDeps {
            gpu: None,
            opener,
            clock,
            color: None,
            gyro: None,
            rasters: None,
            planner: None,
            on_position: None,
            on_shown: None,
            frame_cache_bytes: 1 << 30,
            display: None,
            workers: 4,
        }
    }
}

/// The frame on screen: `generation` counts shown frames, `frame` is the composite (RGBA8 display code values; `None` =
/// nothing to draw). The texture is the compositor's output canvas: it holds the newest composite, so a reader that falls
/// behind sees a newer picture than its generation says, never a torn one (wgpu orders queue work).
pub struct Shown {
    pub generation: u64,
    pub position: Time,
    pub frame: Option<Arc<GpuFrame>>,
    /// The same composite as linear half floats (premultiplied Rec.709 light, sequence size): what Export Frame writes.
    /// The compositor's one working canvas, so it holds the newest composite like `frame`.
    pub linear: Option<sq_gpu::frames::GpuTexture>,
    /// Every picture was drawn at its own size (false: a stand-in while the exact one decodes).
    pub exact: bool,
}

/// Numbers the UI reads without a round trip.
#[derive(Clone, Debug)]
pub struct Status {
    pub position: Time,
    pub rate: Option<PlaybackRate>,
    /// Playback statistics since the last `play`: frame positions shown and frame positions skipped.
    pub shown_frames: u64,
    pub skipped_frames: u64,
    /// Of the shown frame positions, those whose last picture still had a layer drawn from a stand-in when the next one
    /// came, and the most frames the stalest layer was behind (since the last `play`).
    pub late_frames: u64,
    pub max_lag: i64,
    /// The first late frame positions (frame indexes, up to eight).
    pub first_late: Vec<i64>,
    pub played_span: Option<(i64, i64)>,
    pub last_error: Option<String>,
    /// The compositor could not be created: no picture can be drawn until the app restarts (shown as an error line).
    pub compositor_failure: Option<String>,
    /// Changes with the frame cache (the ruler's cache strip polls `cached_spans` only when it moved).
    pub cache_generation: u64,
    pub cache_bytes: usize,
    pub mean_compose_ms: f64,
    pub shown_lag: i64,
}

pub(crate) struct Shared {
    pub(crate) shown: Mutex<Option<Arc<Shown>>>,
    pub(crate) status: Mutex<Status>,
    /// Messages of the handle (commands, queries, stop) the render thread has not taken yet: a long wait on the GPU looks
    /// here, so a Stop or a Seek is not held up behind it (the channel itself cannot be peeked).
    pending: AtomicUsize,
}

impl Default for Shared {
    fn default() -> Shared {
        Shared {
            shown: Mutex::new(None),
            status: Mutex::new(Status {
                position: Time::ZERO,
                rate: None,
                shown_frames: 0,
                skipped_frames: 0,
                late_frames: 0,
                max_lag: 0,
                first_late: Vec::new(),
                played_span: None,
                last_error: None,
                compositor_failure: None,
                cache_generation: 0,
                cache_bytes: 0,
                mean_compose_ms: 0.0,
                shown_lag: 0,
            }),
            pending: AtomicUsize::new(0),
        }
    }
}

impl Shared {
    pub(crate) fn publish(&self, shown: Shown) {
        *self.shown.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(shown));
    }

    /// Sends `m` to the render thread; false when the thread is gone. Every sender of a command, query or stop goes through
    /// here so [`Shared::command_waiting`] is right.
    pub(crate) fn post(&self, tx: &Sender<Msg>, m: Msg) -> bool {
        let counted = m.sent_by_handle();
        if counted {
            self.pending.fetch_add(1, Ordering::AcqRel);
        }
        let sent = tx.send(m).is_ok();
        if counted && !sent {
            self.taken_one();
        }
        sent
    }

    /// The render thread took `m` off its queue.
    pub(crate) fn taken(&self, m: &Msg) {
        if m.sent_by_handle() {
            self.taken_one();
        }
    }

    fn taken_one(&self) {
        let _ = self.pending.try_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_sub(1));
    }

    /// A command, query or stop is queued for the render thread.
    pub(crate) fn command_waiting(&self) -> bool {
        self.pending.load(Ordering::Acquire) > 0
    }
}

pub(crate) enum Msg {
    Command(Command),
    Decoded {
        key: Key,
        picture: Picture,
        scale: DecodeScale,
        preview: bool,
    },
    Finished {
        keys: Vec<Key>,
        error: Option<String>,
    },
    Opened {
        media: Id,
        path: String,
        lane: bool,
        result: Result<Box<super::media_source::MediaSource>, String>,
    },
    /// The proxy open of a media finished: `None` = it has no proxy.
    ProxyOpened {
        media: Id,
        path: String,
        result: Option<Result<Box<super::media_source::MediaSource>, String>>,
    },
    Query(Box<dyn FnOnce(&mut ProgramEngine) + Send>),
    Stop,
}

impl Msg {
    /// A message of the handle (the user's commands), not one from a decode worker.
    fn sent_by_handle(&self) -> bool {
        matches!(self, Msg::Command(_) | Msg::Query(_) | Msg::Stop)
    }
}

/// The engine's verbs (the Swift `ProgramEngine` protocol and the setters around it).
pub enum Command {
    SetTimeline { timeline: Box<Timeline>, sequences: HashMap<Id, Timeline> },
    SetMedia(Vec<MediaRef>),
    MediaChanged(HashSet<Id>),
    SetProxyUse(super::proxy_picture::ProxyUse),
    ProxiesChanged(HashSet<Id>),
    Play(PlaybackRate),
    Pause,
    Seek(Time),
    Step(i32),
    BeginScrub,
    Scrub(Time),
    EndScrub,
    SetQuality(DecodeScale),
    SetPrefetchHalved(bool),
    SetPlayRange(Option<TimeRange>),
    SetLoops(bool),
    SetShowsCaptions(bool),
    SetTransparencyGrid(bool),
    SetColorBypass(Option<ColorBypass>),
    SetLookPreview(Option<Box<LookPreview>>),
    SetFrameCacheBytes(usize),
}

/// The UI thread's handle on the render thread.
pub struct ProgramHandle {
    tx: Sender<Msg>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl ProgramEngine {
    /// Starts the render thread.
    pub fn spawn(deps: EngineDeps) -> ProgramHandle {
        let (tx, rx): (Sender<Msg>, Receiver<Msg>) = mpsc::channel();
        let shared = Arc::new(Shared::default());
        let (engine_tx, engine_shared) = (tx.clone(), Arc::clone(&shared));
        let thread = std::thread::Builder::new()
            .name("sq-render".into())
            .spawn(move || ProgramEngine::new(deps, engine_tx, engine_shared).run(&rx))
            .ok();
        ProgramHandle { tx, shared, thread }
    }
}

/// `SQ_PLAY_PROBE=1`: the engine issues a seek or scrub jump (stage `request` of the pending jump).
fn probe_request(t: Time) {
    if crate::probe::enabled() {
        let p = crate::probe::PlayProbe::shared();
        p.note(crate::probe::Stage::Request, Some(t), crate::probe::now());
    }
}

impl ProgramHandle {
    fn command(&self, c: Command) {
        self.shared.post(&self.tx, Msg::Command(c));
    }

    pub fn set_timeline(&self, timeline: Timeline, sequences: HashMap<Id, Timeline>) {
        self.command(Command::SetTimeline { timeline: Box::new(timeline), sequences });
    }
    pub fn set_media(&self, refs: Vec<MediaRef>) {
        self.command(Command::SetMedia(refs));
    }
    pub fn media_changed(&self, ids: HashSet<Id>) {
        self.command(Command::MediaChanged(ids));
    }
    /// Which monitor states read proxies (scrubbing, playing); a paused frame always reads the original.
    pub fn set_proxy_use(&self, proxy_use: super::proxy_picture::ProxyUse) {
        self.command(Command::SetProxyUse(proxy_use));
    }
    /// The proxies of these media changed or went away: pictures and decoders of them are dropped, then reopened.
    pub fn proxies_changed(&self, ids: HashSet<Id>) {
        self.command(Command::ProxiesChanged(ids));
    }
    pub fn play(&self, rate: PlaybackRate) {
        self.command(Command::Play(rate));
    }
    pub fn pause(&self) {
        self.command(Command::Pause);
    }
    pub fn seek(&self, t: Time) {
        probe_request(t);
        self.command(Command::Seek(t));
    }
    pub fn step(&self, frames: i32) {
        self.command(Command::Step(frames));
    }
    pub fn begin_scrub(&self) {
        self.command(Command::BeginScrub);
    }
    pub fn scrub(&self, t: Time) {
        probe_request(t);
        self.command(Command::Scrub(t));
    }
    pub fn end_scrub(&self) {
        self.command(Command::EndScrub);
    }
    pub fn set_quality(&self, q: DecodeScale) {
        self.command(Command::SetQuality(q));
    }
    /// The play range the host stops or wraps at (None: the whole sequence); the picture never leads out of it.
    pub fn set_play_range(&self, range: Option<TimeRange>) {
        self.command(Command::SetPlayRange(range));
    }
    /// Loop: playback wraps inside the play range (or the whole sequence) by itself, in both directions.
    pub fn set_loops(&self, on: bool) {
        self.command(Command::SetLoops(on));
    }
    /// `PowerPolicy::halves_prefetch`.
    pub fn set_prefetch_halved(&self, on: bool) {
        self.command(Command::SetPrefetchHalved(on));
    }
    pub fn set_shows_captions(&self, on: bool) {
        self.command(Command::SetShowsCaptions(on));
    }
    pub fn set_transparency_grid(&self, on: bool) {
        self.command(Command::SetTransparencyGrid(on));
    }
    pub fn set_color_bypass(&self, b: Option<ColorBypass>) {
        self.command(Command::SetColorBypass(b));
    }
    /// Draws the text of the monitor as `preview` says until it is set to `None` (display only).
    pub fn set_look_preview(&self, preview: Option<LookPreview>) {
        self.command(Command::SetLookPreview(preview.map(Box::new)));
    }
    pub fn set_frame_cache_bytes(&self, bytes: usize) {
        self.command(Command::SetFrameCacheBytes(bytes));
    }

    /// The newest shown frame (the UI draws it and presents).
    pub fn latest_shown(&self) -> Option<Arc<Shown>> {
        self.shared.shown.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn status(&self) -> Status {
        self.shared.status.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Runs `f` on the render thread and waits for its answer (readbacks, the cache strip, tests); `None` when the thread
    /// is gone.
    pub fn query<R: Send + 'static>(&self, f: impl FnOnce(&mut ProgramEngine) -> R + Send + 'static) -> Option<R> {
        let (otx, orx) = mpsc::channel();
        let query = Msg::Query(Box::new(move |e| {
            let _ = otx.send(f(e));
        }));
        self.shared.post(&self.tx, query).then_some(())?;
        orx.recv().ok()
    }

    /// Waits until the render thread handled every message sent before this call.
    pub fn sync(&self) {
        let _ = self.query(|_| ());
    }

    /// Timeline spans whose pictures are all decoded (the ruler's cache strip).
    pub fn cached_spans(&self) -> Vec<TimeRange> {
        self.query(|e| e.cached_spans()).unwrap_or_default()
    }
}

impl Drop for ProgramHandle {
    fn drop(&mut self) {
        self.shared.post(&self.tx, Msg::Stop);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::testkit::Rig;

    #[test]
    fn a_queued_command_counts_until_the_render_thread_takes_it() {
        let shared = Shared::default();
        let (tx, rx) = mpsc::channel();
        assert!(!shared.command_waiting());
        // A decode worker's message is not a command: it must not end a wait on the GPU.
        assert!(shared.post(&tx, Msg::Finished { keys: Vec::new(), error: None }));
        assert!(!shared.command_waiting());
        assert!(shared.post(&tx, Msg::Command(Command::Pause)));
        assert!(shared.command_waiting());
        for _ in 0..2 {
            shared.taken(&rx.try_recv().unwrap());
        }
        assert!(!shared.command_waiting());
        // A thread that is gone leaves no count behind, and a count never goes below zero.
        drop(rx);
        assert!(!shared.post(&tx, Msg::Stop));
        shared.taken(&Msg::Stop);
        assert!(!shared.command_waiting());
    }

    #[test]
    fn the_render_thread_counts_every_command_off_when_it_takes_it() {
        let rig = Rig::new(|_| {});
        for _ in 0..50 {
            rig.handle.pause();
        }
        rig.handle.sync();
        assert!(!rig.handle.shared.command_waiting(), "a command left a count that would end every later wait at once");
    }
}
