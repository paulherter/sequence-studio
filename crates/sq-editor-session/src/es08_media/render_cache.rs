// Swift: RenderCacheController.swift
//! Preview render cache, wiring: keeps the disk index, picks the next heavy segment to render when the editor is idle,
//! and gives the session the spans playback reads instead of the clips. The session feeds it the un-substituted sequence
//! on every push ([`RenderCacheController::spans`]); the host calls [`RenderCacheController::tick`] once a second and
//! runs the [`RenderJob`] it returns on a worker. Nothing here touches the project file. Swift's hooks are polled:
//! [`RenderCacheController::take_spans_changed`] (`onSpansChanged`) and [`RenderCacheController::take_seed_frames`]
//! (`seedFrames`).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use sq_core_model::{RenderCacheMedia, RenderCacheSpan, Timeline};
use sq_core_project::cache_disk_policy::CacheDiskPolicy;
use sq_core_project::render_cache_index::{RenderCacheIndex, RenderCacheScheduler, SchedulerState};
use sq_core_project::render_cache_plan::{RenderCacheContext, RenderCachePlan, RenderCacheSegment};
use sq_core_project::render_cache_store::RenderCacheStore;
use sq_core_time::{Id, Time, Timestamp};
use sq_media::video_decoding::DecodedFrame;

use crate::{ProjectMediaResolver, SessionRenderCaching};

/// What the cache has done so far.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RenderCacheStats {
    // Swift: RenderCacheController.swift:16
    pub rendered: i64,
    // Swift: RenderCacheController.swift:17
    pub failed: i64,
    /// Segments playback reads from the cache right now.
    // Swift: RenderCacheController.swift:19
    pub spans_in_use: i64,
    // Swift: RenderCacheController.swift:20
    pub bytes: i64,
}

/// What the host tells the controller (closures, so the session and tests share one path).
pub struct RenderCacheInputs {
    pub playhead: Box<dyn Fn() -> Time>,
    // Swift: RenderCacheController.swift:26
    pub is_playing: Box<dyn Fn() -> bool>,
    /// Cumulative dropped frames of the playback engine.
    // Swift: RenderCacheController.swift:28
    pub dropped_frames: Box<dyn Fn() -> i64>,
    /// Another heavy job (export, auto proxy) runs: the cache waits.
    // Swift: RenderCacheController.swift:30
    pub is_busy: Box<dyn Fn() -> bool>,
    // Swift: RenderCacheController.swift:31
    pub now: Box<dyn Fn() -> Timestamp>,
    /// The color working space the sequence renders in (part of every segment key).
    pub working_space: Box<dyn Fn(&Timeline) -> String>,
    /// The display view: playback reads spans only in the SDR view, so a change pushes again.
    pub display_view: Box<dyn Fn() -> String>,
}

impl RenderCacheInputs {
    /// Inputs that never play, are never busy and use the given clock.
    // Swift: RenderCacheController.swift:32
    pub fn new(
        playhead: Box<dyn Fn() -> Time>,
        is_playing: Box<dyn Fn() -> bool>,
        dropped_frames: Box<dyn Fn() -> i64>,
        now: Box<dyn Fn() -> Timestamp>,
    ) -> RenderCacheInputs {
        RenderCacheInputs {
            playhead,
            is_playing,
            dropped_frames,
            is_busy: Box::new(|| false),
            now,
            working_space: Box::new(|_| String::new()),
            display_view: Box::new(String::new),
        }
    }
}

/// The frames a renderer encodes, kept in RAM nearest the playhead (Swift `RenderCachePendingFrames`): the parked frame
/// and the start of a play show from them the moment the segment goes live.
// shortcut: lives here until the render crate ports `RenderCachePendingFrames` (RenderCacheSegmentWriter.swift:109).
pub struct RenderPendingFrames {
    /// The fake media id the frames belong to.
    pub media: Id,
    /// Where in the segment the playhead is.
    pub anchor: Time,
    frames: Mutex<Vec<DecodedFrame>>,
}

impl RenderPendingFrames {
    pub fn new(media: Id, anchor: Time) -> RenderPendingFrames {
        RenderPendingFrames { media, anchor, frames: Mutex::new(Vec::new()) }
    }

    /// Keeps a frame the renderer just encoded.
    pub fn push(&self, frame: DecodedFrame) {
        self.frames.lock().unwrap_or_else(PoisonError::into_inner).push(frame);
    }

    /// Takes everything kept.
    pub fn take(&self) -> Vec<DecodedFrame> {
        std::mem::take(&mut *self.frames.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

/// Renders one segment to the file; the last argument collects the frames it encodes. Cooperative cancel: the renderer
/// stops when the flag is set and removes its partial file.
// Swift: RenderCacheController.swift:41
pub type Renderer = Arc<
    dyn Fn(
            &RenderCacheSegment,
            &Timeline,
            &BTreeMap<Id, Timeline>,
            &Path,
            &RenderPendingFrames,
            &AtomicBool,
        ) -> Result<(), String>
        + Send
        + Sync,
>;

/// One segment render for a worker: call [`RenderJob::run`], then give the result to
/// [`RenderCacheController::finish`].
pub struct RenderJob {
    pub segment: RenderCacheSegment,
    pub started: Timestamp,
    pub pending: Arc<RenderPendingFrames>,
    timeline: Timeline,
    sequences: BTreeMap<Id, Timeline>,
    url: PathBuf,
    render: Renderer,
    cancel: Arc<AtomicBool>,
}

impl RenderJob {
    /// Renders the segment (blocking).
    pub fn run(&self) -> Result<(), String> {
        (self.render)(&self.segment, &self.timeline, &self.sequences, &self.url, &self.pending, &self.cancel)
    }
}

struct Source {
    timeline: Timeline,
    sequences: BTreeMap<Id, Timeline>,
}

/// Preview render cache wiring (Swift `RenderCacheController`).
pub struct RenderCacheController {
    // Swift: RenderCacheController.swift:25
    inputs: RenderCacheInputs,
    stats: RenderCacheStats,
    /// Powered by `PowerPolicy.pauses_background_jobs`.
    // Swift: RenderCacheController.swift:55
    held: bool,
    last_display_view: Option<String>,
    store: RenderCacheStore,
    index: RenderCacheIndex,
    media: Arc<ProjectMediaResolver>,
    render: Option<Renderer>,
    renderer_id: String,
    idle_delay: f64,
    enabled: bool,
    source: Option<Source>,
    segments: Vec<RenderCacheSegment>,
    segments_stale: bool,
    last_edit: Timestamp,
    drop_times: Vec<Time>,
    last_dropped: i64,
    job: Option<(String, Arc<AtomicBool>)>,
    spans_changed: bool,
    seed: Vec<DecodedFrame>,
}

impl RenderCacheController {
    /// Changes whenever the renderer's output changes; bumped by hand with a shader or effect change. The app build
    /// number is part of the key too, so a new build never reads an old picture.
    pub const RENDERER_REVISION: &'static str = "r1";

    /// A disabled controller over `directory` (call [`RenderCacheController::configure`] to turn it on). `build` is the
    /// app build number; `render` is the segment renderer (without one nothing is ever rendered, spans still play).
    // Swift: RenderCacheController.swift:75
    pub fn new(
        directory: PathBuf,
        byte_cap: i64,
        media: Arc<ProjectMediaResolver>,
        inputs: RenderCacheInputs,
        build: &str,
        idle_delay: f64,
        render: Option<Renderer>,
    ) -> RenderCacheController {
        let last_edit = (inputs.now)();
        RenderCacheController {
            inputs,
            stats: RenderCacheStats::default(),
            held: false,
            last_display_view: None,
            store: RenderCacheStore::new(directory, byte_cap, CacheDiskPolicy::unchecked()),
            index: RenderCacheIndex::new(),
            media,
            render,
            renderer_id: format!("{}-{build}", Self::RENDERER_REVISION),
            idle_delay,
            enabled: false,
            source: None,
            segments: Vec::new(),
            segments_stale: true,
            last_edit,
            drop_times: Vec::new(),
            last_dropped: 0,
            job: None,
            spans_changed: false,
            seed: Vec::new(),
        }
    }

    /// What the cache has done so far.
    pub fn stats(&self) -> RenderCacheStats {
        self.stats
    }

    /// Whether jobs wait for the power policy.
    pub fn held(&self) -> bool {
        self.held
    }

    /// Powered by `PowerPolicy.pauses_background_jobs`.
    pub fn set_held(&mut self, held: bool) {
        self.held = held;
    }

    /// Spans changed after a render finished (or the cache was configured): push the sequence again. Once.
    // Swift: RenderCacheController.swift:50
    pub fn take_spans_changed(&mut self) -> bool {
        std::mem::take(&mut self.spans_changed)
    }

    /// The pending-writes frames of a segment that just went live, for the engine's `seed_frames`.
    // Swift: RenderCacheController.swift:53
    pub fn take_seed_frames(&mut self) -> Vec<DecodedFrame> {
        std::mem::take(&mut self.seed)
    }

    /// On/off and the size cap (Settings). Turning it off keeps the files (they are valid again when it is turned on)
    /// but playback stops reading them; a smaller cap evicts at the next commit.
    // Swift: RenderCacheController.swift:93
    pub fn configure(&mut self, enabled: bool, directory: PathBuf, byte_cap: i64) {
        let moved = directory != self.store.directory;
        if moved {
            self.cancel_job();
            self.unregister_all();
        }
        self.store = RenderCacheStore::new(directory, byte_cap, CacheDiskPolicy::unchecked());
        if enabled != self.enabled || moved {
            self.enabled = enabled;
            if enabled {
                self.index = self.store.load();
                self.register_all();
            } else {
                self.cancel_job();
                self.unregister_all();
                self.index = RenderCacheIndex::new();
            }
            self.segments_stale = true;
            self.publish_stats(0);
            self.spans_changed = true;
        }
    }

    /// Whether the cache is on (the host runs the one-second tick while it is).
    // Swift: RenderCacheController.swift:111
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// The spans playback should read for this sequence (empty when the cache is off, empty or nothing matches). Also
    /// the session's note that the sequence was pushed: a changed sequence counts as an edit (the renderer waits).
    // Swift: RenderCacheController.swift:118
    pub fn spans(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) -> Vec<RenderCacheSpan> {
        if !self.enabled {
            self.source = None;
            return Vec::new();
        }
        let same = self.source.as_ref().is_some_and(|s| s.timeline == *timeline && s.sequences == *sequences);
        if !same {
            self.source = Some(Source { timeline: timeline.clone(), sequences: sequences.clone() });
            self.last_edit = (self.inputs.now)();
            self.segments_stale = true;
        }
        if self.index.entries().is_empty() {
            return Vec::new();
        }
        let plan = self.plan();
        let spans = self.cached_spans(plan);
        let count = i64::try_from(spans.len()).unwrap_or(i64::MAX);
        if count != self.stats.spans_in_use {
            self.publish_stats(count);
        }
        spans
    }

    /// The spans an export of this sequence may read (the same keys and files playback reads); no side effects: the
    /// export's sequence is not an edit and does not replace the pushed one.
    // Swift: RenderCacheController.swift:138
    pub fn export_spans(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) -> Vec<RenderCacheSpan> {
        if !self.enabled || self.index.entries().is_empty() {
            return Vec::new();
        }
        let same = self.source.as_ref().is_some_and(|s| s.timeline == *timeline && s.sequences == *sequences);
        let segs = if same { self.plan() } else { self.segments_of(timeline, sequences) };
        self.cached_spans(segs)
    }

    fn cached_spans(&self, segments: Vec<RenderCacheSegment>) -> Vec<RenderCacheSpan> {
        segments
            .iter()
            .filter(|s| s.is_heavy && self.index.contains(&s.key))
            .map(|s| RenderCacheSpan { range: s.range, media: RenderCacheMedia::id_for_key(&s.key) })
            .collect()
    }

    /// A media file changed on disk: the stamps in the keys changed, so spans are recomputed.
    // Swift: RenderCacheController.swift:147
    pub fn media_changed(&mut self) {
        self.segments_stale = true;
        if self.enabled {
            self.spans_changed = true;
        }
    }

    fn plan(&mut self) -> Vec<RenderCacheSegment> {
        let Some(source) = &self.source else { return Vec::new() };
        if !self.segments_stale {
            return self.segments.clone();
        }
        let segments = self.segments_of(&source.timeline, &source.sequences);
        self.segments = segments.clone();
        self.segments_stale = false;
        segments
    }

    fn segments_of(&self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) -> Vec<RenderCacheSegment> {
        let media = Arc::clone(&self.media);
        let mut context = RenderCacheContext::new(&self.renderer_id, &(self.inputs.working_space)(timeline));
        context.media_stamp = Box::new(move |id| media_stamp(&media, id));
        RenderCachePlan::segments(timeline, Some(&|id| sequences.get(&id)), &context)
    }

    /// One scheduler step (the host calls it once a second while the cache is on). Returns the render to run on a
    /// worker, if one should start.
    // Swift: RenderCacheController.swift:203
    pub fn tick(&mut self) -> Option<RenderJob> {
        if !self.enabled || self.source.is_none() {
            return None;
        }
        // shortcut: the display view is polled once a second, so a switch to or from SDR reads the cache (or the clips)
        // within a second; becomes a direct notification when the monitor's view change reaches the session.
        let view = (self.inputs.display_view)();
        if self.last_display_view.as_ref().is_some_and(|last| *last != view) && !self.index.entries().is_empty() {
            self.spans_changed = true;
        }
        self.last_display_view = Some(view);
        let dropped = (self.inputs.dropped_frames)();
        if (self.inputs.is_playing)() && dropped > self.last_dropped {
            self.drop_times.push((self.inputs.playhead)());
            if self.drop_times.len() > 50 {
                self.drop_times.drain(..self.drop_times.len() - 50);
            }
        }
        self.last_dropped = dropped;
        let current = self.plan();
        if let Some((key, _)) = &self.job
            && !current.iter().any(|s| s.key == *key)
        {
            self.cancel_job();
        }
        if self.job.is_some() {
            return None;
        }
        let state = SchedulerState {
            index: &self.index,
            playhead: (self.inputs.playhead)(),
            dropped_frames: &self.drop_times,
            playing: (self.inputs.is_playing)(),
            throttled: self.held || (self.inputs.is_busy)(),
            last_edit: self.last_edit,
            now: (self.inputs.now)(),
            idle_delay: self.idle_delay,
        };
        let next = RenderCacheScheduler::next_job(&current, &state)?.clone();
        self.start(next)
    }

    fn start(&mut self, segment: RenderCacheSegment) -> Option<RenderJob> {
        let render = self.render.clone()?;
        let source = self.source.as_ref()?;
        // ProRes 422 LT at 1080p30 is about 12 MB/s; the estimate only has to keep the disk floor.
        let seconds =
            (segment.range.duration.value() as f64 / segment.range.duration.timescale().max(1) as f64).max(1.0);
        if !self.store.may_write((seconds * 20_000_000.0) as i64) {
            return None;
        }
        let url = self.store.file_url(&segment.key);
        let _ = std::fs::create_dir_all(&self.store.directory);
        let local = (self.inputs.playhead)() - segment.range.start;
        let anchor = if local < Time::ZERO { Time::ZERO } else { local.min(segment.range.duration) };
        let pending = Arc::new(RenderPendingFrames::new(RenderCacheMedia::id_for_key(&segment.key), anchor));
        let cancel = Arc::new(AtomicBool::new(false));
        self.job = Some((segment.key.clone(), Arc::clone(&cancel)));
        Some(RenderJob {
            started: (self.inputs.now)(),
            pending,
            timeline: source.timeline.clone(),
            sequences: source.sequences.clone(),
            url,
            render,
            cancel,
            segment,
        })
    }

    /// The result of a [`RenderJob`] the host ran.
    pub fn finish(&mut self, job: &RenderJob, error: Option<String>) {
        let frames = job.pending.take();
        let segment = &job.segment;
        if self.job.as_ref().map(|(k, _)| k) != Some(&segment.key) {
            // Canceled: the writer already removed a partial file.
            let _ = std::fs::remove_file(self.store.file_url(&segment.key));
            return;
        }
        self.job = None;
        let live: BTreeSet<String> = self.plan().into_iter().map(|s| s.key).collect();
        if error.is_some() || !live.contains(&segment.key) {
            if error.is_some() {
                self.stats.failed += 1;
            }
            let _ = std::fs::remove_file(self.store.file_url(&segment.key));
            self.publish_stats(self.stats.spans_in_use);
            return;
        }
        let before: BTreeSet<String> = self.index.entries().keys().cloned().collect();
        let now = (self.inputs.now)();
        if self.store.commit(&segment.key, segment.range.duration, &mut self.index, &live, now).is_err() {
            self.stats.failed += 1;
            let _ = std::fs::remove_file(self.store.file_url(&segment.key));
            return;
        }
        for gone in before.iter().filter(|k| !self.index.contains(k)) {
            self.media.remove_render_cache_file(RenderCacheMedia::id_for_key(gone));
        }
        self.media.set_render_cache_file(RenderCacheMedia::id_for_key(&segment.key), self.store.file_url(&segment.key));
        self.stats.rendered += 1;
        self.publish_stats(self.stats.spans_in_use);
        // Before the push: the first tick on the span finds them.
        self.seed.extend(frames);
        self.spans_changed = true;
    }

    fn publish_stats(&mut self, spans: i64) {
        self.stats.spans_in_use = spans;
        self.stats.bytes = self.index.total_bytes();
    }

    fn register_all(&self) {
        for key in self.index.entries().keys() {
            self.media.set_render_cache_file(RenderCacheMedia::id_for_key(key), self.store.file_url(key));
        }
    }

    fn unregister_all(&self) {
        for key in self.index.entries().keys() {
            self.media.remove_render_cache_file(RenderCacheMedia::id_for_key(key));
        }
    }

    fn cancel_job(&mut self) {
        if let Some((_, cancel)) = self.job.take() {
            cancel.store(true, Ordering::SeqCst);
        }
    }
}

/// What of a media file the picture depends on besides the clip itself: size and modification date of the file, and its
/// color interpretation (the media item's probe info: input color space, transfer, LUT, HDR handling).
// shortcut: the info part is its `Debug` text (Swift: sorted-key JSON); keys only need to change when the info changes.
pub fn media_stamp(media: &ProjectMediaResolver, id: Id) -> String {
    let mut stamp = String::new();
    if let Some(path) = media.path(id)
        && let Ok(meta) = std::fs::metadata(&path)
    {
        let mtime = meta
            .modified()
            .ok()
            .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0.0, |d| d.as_secs_f64());
        stamp = format!("{}-{mtime}", meta.len());
    }
    if let Some(info) = media.info(id) {
        stamp.push('|');
        stamp.push_str(&format!("{info:?}"));
    }
    stamp
}

impl SessionRenderCaching for RenderCacheController {
    fn spans(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) -> Vec<RenderCacheSpan> {
        RenderCacheController::spans(self, timeline, sequences)
    }
    fn media_changed(&mut self) {
        RenderCacheController::media_changed(self);
    }
    fn set_held(&mut self, held: bool) {
        RenderCacheController::set_held(self, held);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_frames_are_taken_once() {
        let p = RenderPendingFrames::new(Id::from_u128(1), Time::ZERO);
        assert!(p.take().is_empty());
    }
}
