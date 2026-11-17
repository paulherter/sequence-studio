// Swift: ExportQueue.swift
//
// The Swift actor becomes a clonable handle over one mutex-guarded state machine. `run_all` blocks the export thread
// (one per queue, serial lane); `enqueue`, `cancel` and the status reads may be called from any other thread, as they
// could be called on the actor while it awaited. Encoder, sidecar writer and cover writer sit behind traits.
//
// Ownership: `Inner.state` is the single mutable state (jobs, reserved names, the running job's cancel token, the
// subscribers). It is shared by the export thread, the free-space watcher thread and the UI thread; every access is a
// short critical section and no callback (encoder, progress sink, sidecar or cover writer) runs while the lock is held.

use super::error::{CancelToken, ExportError};
use super::loudness::LoudnessReport;
use super::preflight::ExportPreflight;
use super::progress::ProgressThrottle;
pub use super::queue_state::ExportJobState;
use super::queue_state::{JobEvent, StopReason, Worker};
use super::settings::{CaptionMode, CoverImageFormat, ExportSettings, RangeSelection};
use super::traits::{AudioSource, ExportEncoding, ExportFrame, FrameSource};
use sq_core_edit::cover_frame::CoverFrame;
use sq_core_model::{PixelAspect, SequenceFormat, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One subtitle cue on the sequence timeline. `lines` are kept exactly as segmented.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SrtCue {
    /// The text lines.
    pub lines: Vec<String>,
    /// Start and length on the sequence timeline.
    pub range: TimeRange,
}

impl SrtCue {
    /// A cue.
    pub fn new(lines: Vec<String>, range: TimeRange) -> SrtCue {
        SrtCue { lines, range }
    }
}

/// What a job needs to export, created lazily when the job starts.
pub struct ExportSources {
    /// Rendered frames.
    pub video: Box<dyn FrameSource>,
    /// The mixed audio.
    pub audio: Option<Box<dyn AudioSource>>,
    /// Cues on the sequence timeline; written as sidecar when `settings.captions` asks for one.
    pub captions: Vec<SrtCue>,
}

impl ExportSources {
    /// Sources without captions.
    pub fn new(video: Box<dyn FrameSource>, audio: Option<Box<dyn AudioSource>>) -> ExportSources {
        ExportSources { video, audio, captions: Vec::new() }
    }
}

/// Creates the sources of a job when it starts.
pub type MakeSources = Arc<dyn Fn() -> Result<ExportSources, ExportError> + Send + Sync>;

/// Creates the sources of a job from that job's own settings (variant jobs differ in size).
pub type MakeSourcesFor = Arc<dyn Fn(&ExportSettings) -> Result<ExportSources, ExportError> + Send + Sync>;

/// One sequence to export. Sources are created lazily when the job starts.
#[derive(Clone)]
pub struct ExportJob {
    /// Identity (the caller draws it from its `IdSource`).
    pub id: Id,
    /// Shown name; also the file name stem.
    pub name: String,
    /// Settings.
    pub settings: ExportSettings,
    /// Folder of the output file.
    pub output_directory: PathBuf,
    /// Builds the sources.
    pub make_sources: MakeSources,
    /// The user chose Replace for an existing file of this name: the queue keeps the exact name instead of adding " 2".
    pub replace_existing: bool,
}

impl ExportJob {
    /// A job.
    pub fn new(
        id: Id,
        name: &str,
        settings: ExportSettings,
        output_directory: PathBuf,
        make_sources: MakeSources,
    ) -> ExportJob {
        ExportJob { id, name: name.to_string(), settings, output_directory, make_sources, replace_existing: false }
    }

    /// "Export all formats": one job for the sequence's own format and one per variant, in variant order. A variant job
    /// is named "<name> <variant name>" (the queue turns that into the file name), carries the variant id in
    /// `settings.variant` and is sized like the variant at the same scale the base export uses (`settings` relative to
    /// `timeline.format`, rounded to even pixels). `make_sources` is called with each job's own settings.
    pub fn variant_jobs(
        name: &str,
        settings: &ExportSettings,
        output_directory: &Path,
        timeline: &Timeline,
        ids: &mut dyn sq_core_time::IdSource,
        make_sources: MakeSourcesFor,
    ) -> Vec<ExportJob> {
        let mut base = settings.clone();
        base.variant = None;
        let job_for = |id: Id, name: &str, s: ExportSettings| {
            let ms = Arc::clone(&make_sources);
            let own = s.clone();
            ExportJob::new(id, name, s, output_directory.to_path_buf(), Arc::new(move || ms(&own)))
        };
        let mut out = vec![job_for(ids.next_id(), name, base.clone())];
        let seq = &timeline.format;
        // The export carries the sequence's Pixel Shape: sizes are stored sizes. Exported with another shape (a square
        // preset on a non-square sequence) the picture is the display canvas, so sizes follow display widths.
        let same_shape = settings.video.pixel_aspect() == seq.pixel_aspect();
        let bw = (if same_shape { seq.width } else { seq.display_width() }).max(1);
        for v in &timeline.variants {
            let mut s = base.clone();
            s.variant = Some(v.id);
            let mut vf = SequenceFormat::new(seq.frame_duration);
            vf.width = v.width;
            vf.height = v.height;
            vf.audio_sample_rate = seq.audio_sample_rate;
            vf.set_pixel_aspect(seq.pixel_aspect());
            s.video.set_pixel_aspect(if same_shape { vf.pixel_aspect() } else { settings.video.pixel_aspect() });
            let vw = if same_shape { vf.width } else { vf.display_width() };
            s.video.width = even_scaled(vw, settings.video.width, bw);
            s.video.height = even_scaled(vf.height, settings.video.width, bw);
            out.push(job_for(ids.next_id(), &format!("{name} {}", v.name), s));
        }
        out
    }
}

/// `value * num / den` rounded to the nearest even integer, at least 2 (integer math, no float).
pub fn even_scaled(value: i64, num: i64, den: i64) -> i64 {
    let twice = (2 * value * num + den) / (2 * den); // round(value * num / den)
    ((twice + 1) / 2 * 2).max(2)
}

/// A file written next to the video: not asked for or not yet, written, or failed (the video is kept then).
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum SideOutput {
    #[default]
    Pending,
    Written(PathBuf),
    Failed(String),
}

impl SideOutput {
    /// The file once written.
    pub fn url(&self) -> Option<&Path> {
        match self {
            SideOutput::Written(url) => Some(url),
            _ => None,
        }
    }

    /// Why it could not be written.
    pub fn error(&self) -> Option<&str> {
        match self {
            SideOutput::Failed(why) => Some(why),
            _ => None,
        }
    }
}

/// Everything a status display needs about one job.
#[derive(Clone, Debug, PartialEq)]
pub struct ExportJobStatus {
    /// The job.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// State.
    pub state: ExportJobState,
    /// 0...1.
    pub progress: f64,
    /// The file (or folder) the job writes.
    pub output_url: PathBuf,
    /// The caption sidecar next to the video.
    pub sidecar: SideOutput,
    /// The cover image next to the video.
    pub cover: SideOutput,
    /// Set when the export normalized loudness: measured and resulting levels.
    pub loudness: Option<LoudnessReport>,
}

/// Writes the caption sidecar (SRT, VTT, ITT) of a finished video. Implemented in `formats`.
pub trait SidecarWriting: Send + Sync {
    /// Writes `cues` in the format of `mode`, clipped to `range`.
    fn write(&self, mode: CaptionMode, cues: &[SrtCue], range: &RangeSelection, to: &Path) -> Result<(), String>;
}

/// Saves the cover frame as a still. Implemented by the platform encoder crate.
pub trait CoverWriting: Send + Sync {
    /// Writes `frame` as `format`, tagged with `pixel_aspect`.
    fn write(
        &self,
        frame: &ExportFrame,
        format: CoverImageFormat,
        pixel_aspect: PixelAspect,
        to: &Path,
    ) -> Result<(), ExportError>;
}

struct NoSidecars;

impl SidecarWriting for NoSidecars {
    fn write(&self, _: CaptionMode, _: &[SrtCue], _: &RangeSelection, _: &Path) -> Result<(), String> {
        Err("Caption sidecars are not available in this build".to_string())
    }
}

struct NoCovers;

impl CoverWriting for NoCovers {
    fn write(&self, _: &ExportFrame, _: CoverImageFormat, _: PixelAspect, _: &Path) -> Result<(), ExportError> {
        Err(ExportError::WriterFailed("Cover images are not available on this platform yet".to_string()))
    }
}

/// Free bytes on a folder's volume (`None` = unknown); injected so tests need no full disk.
pub type FreeSpaceProbe = Arc<dyn Fn(&Path) -> Option<i64> + Send + Sync>;

struct Entry {
    job: ExportJob,
    status: ExportJobStatus,
}

#[derive(Default)]
struct State {
    entries: Vec<Entry>,
    /// Lowercased paths (case-insensitive file systems): video and sidecar names.
    reserved: HashSet<String>,
    /// The worker lifecycle (idle / between jobs / one job running with its cancel token and stop reason).
    worker: Worker,
    /// Publishes at most 10 progress updates per second per job (the writer reports per frame).
    throttles: HashMap<Id, ProgressThrottle>,
    subscribers: Vec<Sender<ExportJobStatus>>,
}

struct Inner {
    state: Mutex<State>,
    encoder: Arc<dyn ExportEncoding>,
    free_space_probe: FreeSpaceProbe,
    minimum_free_bytes: i64,
    check_interval: Duration,
    sidecars: Arc<dyn SidecarWriting>,
    covers: Arc<dyn CoverWriting>,
    epoch: Instant,
}

/// The export queue: jobs run one after another on the thread that calls `run_all`.
#[derive(Clone)]
pub struct ExportQueue {
    inner: Arc<Inner>,
}

/// What a finished job hands back besides the video.
struct JobOutput {
    captions: Vec<SrtCue>,
    loudness: Option<LoudnessReport>,
    cover: Option<Result<PathBuf, ExportError>>,
}

impl ExportQueue {
    /// A queue writing through `encoder`; free space is unknown, so no low-space stop.
    pub fn new(encoder: Arc<dyn ExportEncoding>) -> ExportQueue {
        ExportQueue::with_options(
            encoder,
            Arc::new(ExportPreflight::free_bytes),
            ExportPreflight::RUNNING_FLOOR_BYTES,
            Duration::from_secs(2),
        )
    }

    /// A queue with its own free-space probe, floor and check interval.
    pub fn with_options(
        encoder: Arc<dyn ExportEncoding>,
        free_space_probe: FreeSpaceProbe,
        minimum_free_bytes: i64,
        check_interval: Duration,
    ) -> ExportQueue {
        ExportQueue {
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                encoder,
                free_space_probe,
                minimum_free_bytes,
                check_interval,
                sidecars: Arc::new(NoSidecars),
                covers: Arc::new(NoCovers),
                epoch: Instant::now(),
            }),
        }
    }

    /// The same queue with a sidecar writer and a cover writer. Call before the first job is enqueued.
    pub fn with_writers(self, sidecars: Arc<dyn SidecarWriting>, covers: Arc<dyn CoverWriting>) -> ExportQueue {
        let i = &self.inner;
        let state = std::mem::take(&mut *lock(&i.state));
        ExportQueue {
            inner: Arc::new(Inner {
                state: Mutex::new(state),
                encoder: Arc::clone(&i.encoder),
                free_space_probe: Arc::clone(&i.free_space_probe),
                minimum_free_bytes: i.minimum_free_bytes,
                check_interval: i.check_interval,
                sidecars,
                covers,
                epoch: i.epoch,
            }),
        }
    }

    // MARK: Observation

    /// Every status change from now on (a job's `enqueue`, progress, end). The receiver ends when the queue is dropped.
    pub fn updates(&self) -> Receiver<ExportJobStatus> {
        let (tx, rx) = mpsc::channel();
        lock(&self.inner.state).subscribers.push(tx);
        rx
    }

    /// The status of one job.
    pub fn status(&self, id: Id) -> Option<ExportJobStatus> {
        lock(&self.inner.state).entries.iter().find(|e| e.job.id == id).map(|e| e.status.clone())
    }

    /// The status of every job, in queue order.
    pub fn all_statuses(&self) -> Vec<ExportJobStatus> {
        lock(&self.inner.state).entries.iter().map(|e| e.status.clone()).collect()
    }

    // MARK: Control

    /// Adds a job and reserves its file names.
    pub fn enqueue(&self, mut job: ExportJob) -> Id {
        let mut st = lock(&self.inner.state);
        // Ids are the key of every status update, and a fresh dialog model draws the same ids again: never two entries
        // with one id, or the worker finds the finished one, cannot start it and spins on the waiting one.
        while st.entries.iter().any(|e| e.job.id == job.id) {
            job.id = Id::from_u128(job.id.as_u128().wrapping_add(1));
        }
        let ext = job.settings.file_extension();
        let sidecar_ext = job.settings.captions.sidecar_extension();
        let mut chosen: Option<PathBuf> = None;
        if job.replace_existing {
            let exact = job.output_directory.join(file_name(&sanitize(&job.name), ext));
            let mut all = vec![exact.clone()];
            if let Some(e) = sidecar_ext {
                all.push(exact.with_extension(e));
            }
            if all.iter().all(|p| !st.reserved.contains(&key(p))) {
                chosen = Some(exact);
            }
        }
        let url =
            chosen.unwrap_or_else(|| unique_url(&st.reserved, &job.output_directory, &job.name, ext, sidecar_ext));
        st.reserved.insert(key(&url));
        if let Some(e) = sidecar_ext {
            st.reserved.insert(key(&url.with_extension(e)));
        }
        let status = ExportJobStatus {
            id: job.id,
            name: job.name.clone(),
            state: ExportJobState::Waiting,
            progress: 0.0,
            output_url: url,
            sidecar: SideOutput::Pending,
            cover: SideOutput::Pending,
            loudness: None,
        };
        let id = job.id;
        publish(&mut st, &status);
        st.entries.push(Entry { job, status });
        id
    }

    /// Cancels a waiting job at once, or asks the running one to stop (it shows as `Cancelling` meanwhile).
    pub fn cancel(&self, id: Id) {
        let mut st = lock(&self.inner.state);
        let Some(i) = st.entries.iter().position(|e| e.job.id == id) else { return };
        // Finished jobs reject the event: nothing to do.
        let Ok(next) = st.entries[i].status.state.transition(JobEvent::RequestCancel) else { return };
        let was_waiting = st.entries[i].status.state == ExportJobState::Waiting;
        st.entries[i].status.state = next;
        if was_waiting {
            let url = st.entries[i].status.output_url.clone();
            let ext = st.entries[i].job.settings.captions.sidecar_extension();
            unreserve(&mut st.reserved, &url, ext);
        } else {
            // No-op while the token is not stored yet: `run` cancels it as soon as it is.
            st.worker.stop(id, StopReason::User);
        }
        let s = st.entries[i].status.clone();
        publish(&mut st, &s);
    }

    /// Runs all waiting jobs one after another (also jobs added meanwhile). Returns when none are waiting.
    // The idle-sleep assertion is held by the app shell (`sq_platform::ExportIndicators`, sleep lock), not by the queue.
    pub fn run_all(&self) {
        if !lock(&self.inner.state).worker.begin() {
            return;
        }
        loop {
            let next = {
                let mut st = lock(&self.inner.state);
                let next = st.entries.iter().position(|e| e.status.state == ExportJobState::Waiting);
                if next.is_none() {
                    // Same critical section as the search: a job enqueued after this finds an idle worker.
                    st.worker.end();
                }
                next
            };
            let Some(i) = next else { break };
            self.run(i);
        }
    }

    // MARK: Internals

    fn run(&self, index: usize) {
        let (job, url) = {
            let st = lock(&self.inner.state);
            (st.entries[index].job.clone(), st.entries[index].status.output_url.clone())
        };
        let id = job.id;
        let cancel = CancelToken::new();
        {
            // Start and token store in one critical section: a cancel before it drops the job (Cancelled), a cancel
            // after it finds the token.
            let mut st = lock(&self.inner.state);
            let Some(i) = st.entries.iter().position(|e| e.job.id == id) else { return };
            let Ok(next) = st.entries[i].status.state.transition(JobEvent::Start) else { return };
            st.entries[i].status.state = next;
            st.worker.start(id, cancel.clone());
            let s = st.entries[i].status.clone();
            publish(&mut st, &s);
        }
        // An audio-only file carries no burned-in captions and no cover image.
        let settings = job.settings.for_delivery();
        let folder = url.parent().map(Path::to_path_buf).unwrap_or_default();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let result = std::thread::scope(|scope| {
            // Free-space watch: a volume that fills up mid-export stops the job with a clear message (and removes the
            // partial file) instead of letting the encoder fail on a write.
            let (this, folder) = (self, &folder);
            scope.spawn(move || {
                while let Err(mpsc::RecvTimeoutError::Timeout) = stop_rx.recv_timeout(this.inner.check_interval) {
                    if (this.inner.free_space_probe)(folder).is_some_and(|free| free < this.inner.minimum_free_bytes) {
                        this.stop_for_low_space(id);
                        return;
                    }
                }
            });
            // A panic on the export thread fails the job (and frees the worker) instead of unwinding out of `run_all`.
            let r = sq_core_time::caught_panic::catching(|| self.export_one(&job, &settings, &url, &cancel))
                .unwrap_or_else(|payload| {
                    let text = sq_core_time::caught_panic::message(payload.as_ref());
                    Err(ExportError::Other(format!("The export stopped unexpectedly. {text}")))
                });
            drop(stop_tx);
            r
        });
        let stop = lock(&self.inner.state).worker.finish(id).flatten();
        match result {
            Ok(done) => self.finish_ok(&job, &url, done),
            Err(e) => self.finish_err(&job, &url, &e, stop),
        }
        lock(&self.inner.state).throttles.remove(&id);
    }

    fn export_one(
        &self,
        job: &ExportJob,
        settings: &ExportSettings,
        url: &Path,
        cancel: &CancelToken,
    ) -> Result<JobOutput, ExportError> {
        let id = job.id;
        let mut src = (job.make_sources)()?;
        cancel.check()?;
        let report = self.inner.encoder.export(
            src.video.as_mut(),
            src.audio.as_mut().map(|a| a.as_mut() as &mut dyn AudioSource),
            settings,
            url,
            cancel,
            &mut |p| self.set_progress(id, p),
        )?;
        // The video is finished; a cover problem never deletes it.
        let cover = settings.cover_image.map(|format| self.write_cover(src.video.as_mut(), settings, format, url));
        Ok(JobOutput { captions: src.captions, loudness: report, cover })
    }

    fn finish_ok(&self, job: &ExportJob, url: &Path, done: JobOutput) {
        let id = job.id;
        if let Some(report) = done.loudness {
            self.update(id, |s| s.loudness = Some(report));
        }
        match done.cover {
            Some(Ok(cover)) => self.update(id, |s| s.cover = SideOutput::Written(cover)),
            Some(Err(e)) => self.update(id, |s| s.cover = SideOutput::Failed(e.to_string())),
            None => {}
        }
        // The video is finished; a sidecar problem never deletes it.
        if let Some(ext) = job.settings.captions.sidecar_extension() {
            let srt = url.with_extension(ext);
            match self.inner.sidecars.write(job.settings.captions, &done.captions, &job.settings.range, &srt) {
                Ok(()) => self.update(id, |s| s.sidecar = SideOutput::Written(srt)),
                Err(e) => self.update(id, |s| s.sidecar = SideOutput::Failed(e)),
            }
        }
        // A finished file is on disk, where `unique_url` sees it; keeping it reserved would make Replace pick " 2".
        unreserve(&mut lock(&self.inner.state).reserved, url, job.settings.captions.sidecar_extension());
        let url = url.to_path_buf();
        self.update(id, |s| {
            s.progress = 1.0;
            Self::apply(s, JobEvent::Finish(url));
        });
    }

    fn finish_err(&self, job: &ExportJob, url: &Path, e: &ExportError, stop: Option<StopReason>) {
        let id = job.id;
        if url.is_dir() {
            let _ = std::fs::remove_dir_all(url);
        } else {
            let _ = std::fs::remove_file(url);
        }
        unreserve(&mut lock(&self.inner.state).reserved, url, job.settings.captions.sidecar_extension());
        let folder = url.parent().map(Path::to_path_buf).unwrap_or_default();
        let free = (self.inner.free_space_probe)(&folder);
        let cancelled_by_user = stop == Some(StopReason::User);
        let event = if stop == Some(StopReason::LowSpace) {
            let free = (self.inner.free_space_probe)(&folder);
            JobEvent::Fail(ExportPreflight::ran_out_of_space_message(free))
        } else if matches!(e, ExportError::Cancelled) || cancelled_by_user || self.is_cancelling(id) {
            JobEvent::Stopped
        } else {
            JobEvent::Fail(ExportPreflight::failure_message(e, free))
        };
        self.update(id, |s| Self::apply(s, event));
    }

    fn is_cancelling(&self, id: Id) -> bool {
        lock(&self.inner.state).entries.iter().any(|e| e.job.id == id && e.status.state == ExportJobState::Cancelling)
    }

    /// Applies an event to a status; an invalid one is dropped (the state stays).
    fn apply(s: &mut ExportJobStatus, event: JobEvent) {
        if let Ok(next) = s.state.transition(event) {
            s.state = next;
        }
    }

    fn stop_for_low_space(&self, id: Id) {
        lock(&self.inner.state).worker.stop(id, StopReason::LowSpace);
    }

    /// Saves the cover frame ("Cover" marker time, else the first frame) as "<video name> Cover.<ext>" next to the video.
    fn write_cover(
        &self,
        video: &mut dyn FrameSource,
        settings: &ExportSettings,
        format: CoverImageFormat,
        video_url: &Path,
    ) -> Result<PathBuf, ExportError> {
        let start = match settings.range {
            RangeSelection::InOut(r) => r.start,
            RangeSelection::EntireSequence => Time::ZERO,
        };
        let index =
            CoverFrame::frame_index(settings.cover_time, start, video.frame_duration(), video.frame_count() as i64);
        let frame = video.frame(usize::try_from(index).unwrap_or(0))?;
        let dir = video_url.parent().map(Path::to_path_buf).unwrap_or_default();
        let stem = video_url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let mut n = 1;
        let url = loop {
            let name = CoverFrame::file_name(
                &if n == 1 { stem.clone() } else { format!("{stem} {n}") },
                format.file_extension(),
            );
            let candidate = dir.join(name);
            n += 1;
            if !candidate.exists() {
                break candidate;
            }
        };
        self.inner.covers.write(&frame, format, settings.video.pixel_aspect(), &url)?;
        Ok(url)
    }

    fn set_progress(&self, id: Id, p: f64) {
        let mut st = lock(&self.inner.state);
        // Late progress callbacks must not move a finished job or go backwards.
        let Some(i) = st.entries.iter().position(|e| e.job.id == id) else { return };
        if !st.entries[i].status.state.is_exporting() || p <= st.entries[i].status.progress {
            return;
        }
        let now = self.inner.epoch.elapsed().as_secs_f64();
        let th = st.throttles.entry(id).or_insert_with(|| ProgressThrottle::new(0.1));
        if !th.accept(p, now) {
            return;
        }
        st.entries[i].status.progress = p;
        let s = st.entries[i].status.clone();
        publish(&mut st, &s);
    }

    fn update(&self, id: Id, f: impl FnOnce(&mut ExportJobStatus)) {
        let mut st = lock(&self.inner.state);
        let Some(i) = st.entries.iter().position(|e| e.job.id == id) else { return };
        f(&mut st.entries[i].status);
        let s = st.entries[i].status.clone();
        publish(&mut st, &s);
    }
}

/// Sends the status to every subscriber and drops the ones whose receiver is gone. `mpsc::Sender::send` never blocks.
fn publish(st: &mut State, s: &ExportJobStatus) {
    st.subscribers.retain(|sub| sub.send(s.clone()).is_ok());
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// "stem.ext"; an empty extension (an image sequence folder) is just the stem.
pub fn file_name(stem: &str, ext: &str) -> String {
    if ext.is_empty() { stem.to_string() } else { format!("{stem}.{ext}") }
}

/// Makes a file name safe: path and wildcard characters and control characters become "-", the ends are trimmed, an
/// empty or dot-leading result gets an "Export" prefix.
pub fn sanitize(name: &str) -> String {
    let bad = "/\\:*?\"<>|";
    let s: String = name.chars().map(|c| if bad.contains(c) || c.is_control() { '-' } else { c }).collect();
    let s = s.trim_matches(|c: char| c.is_whitespace()).to_string();
    if s.is_empty() || s.starts_with('.') { format!("Export{s}") } else { s }
}

/// Lowercased, lexically standardized path (`.` and `..` resolved).
fn key(p: &Path) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut root = String::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop();
            }
            Component::Normal(s) => parts.push(s.to_string_lossy().into_owned()),
            other => root.push_str(&other.as_os_str().to_string_lossy()),
        }
    }
    let sep = if root.ends_with('/') || root.ends_with('\\') { "" } else { "/" };
    format!("{root}{sep}{}", parts.join("/")).to_lowercase()
}

fn unreserve(reserved: &mut HashSet<String>, url: &Path, sidecar_ext: Option<&str>) {
    reserved.remove(&key(url));
    if let Some(e) = sidecar_ext {
        reserved.remove(&key(&url.with_extension(e)));
    }
}

fn unique_url(reserved: &HashSet<String>, dir: &Path, name: &str, ext: &str, also_ext: Option<&str>) -> PathBuf {
    let base = sanitize(name);
    let mut n = 1;
    loop {
        let stem = if n == 1 { base.clone() } else { format!("{base} {n}") };
        let url = dir.join(file_name(&stem, ext));
        let mut candidates = vec![url.clone()];
        if let Some(e) = also_ext {
            candidates.push(dir.join(format!("{stem}.{e}")));
        }
        // The file system may be case-insensitive; `reserved` is lowercased for queued jobs.
        if candidates.iter().all(|c| !reserved.contains(&key(c)) && !c.exists()) {
            return url;
        }
        n += 1;
    }
}
