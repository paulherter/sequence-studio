// Swift: MagicMaskSession.swift
//! Magic mode on the Program monitor: segments the shown source frame (in the background), then hover is a label lookup
//! (the object under the pointer) and a click's pick is stored at once so the picture shows it before any Track. Never
//! runs during playback: the host prepares only for a parked playhead. Every new frame (seek, scrub, step) is segmented
//! again; a newer frame cancels the stale request.
//!
//! Nothing a request leaves behind can switch the session off (2026-10-09, "works once, then never again"):
//! - a frame that really shows nothing is remembered, so the host does not run it on every redraw; a click runs it again;
//! - a request that failed is not remembered as "nothing here": the next hover (after `retry_delay`) or click runs it again;
//! - a request that does not come back within `timeout` is given up ([`MagicMaskSession::expire`]), so the next one can
//!   start; its late result is ignored. Only a click runs that frame again, and the click moves the frame work on to a
//!   fresh thread (`on_restart`);
//! - soft mattes for the hover highlight and for a pick are made off the UI thread, latest first.
//!
//! The Swift class awaits tasks and continuations. Here it is the state machine; the segmentation, the soft mattes and the
//! pick run as small request objects on the host's workers (`MagicRequest::run`, `SoftMatteRequest::run`,
//! `PickRequest::run`) and their results come back through `finish`, `finish_soft` and `finish_pick`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use sq_core_masks::magic_follow::{InstanceFrame, MagicFollower};
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_model::{FieldOrder, MagicPoint, PixelAspect};
use sq_core_time::{Id, Time, Vec2};
use sq_runtime::{Clock, SystemClock};

use super::frame_sampler::RgbaImage;

/// Segments the frame at source seconds of a file: the objects and that frame's pts.
// Swift: MagicMaskSession.swift:25
pub type MagicSegment = Arc<dyn Fn(&Path, f64) -> Result<Option<(InstanceFrame, f64)>, String> + Send + Sync>;

/// The same with the shape of the file's stored pixels and the field order its frames are deinterlaced with.
// Swift: MagicMaskSession.swift:52
pub type MagicShapedSegment = Arc<
    dyn Fn(&Path, f64, PixelAspect, Option<FieldOrder>) -> Result<Option<(InstanceFrame, f64)>, String> + Send + Sync,
>;

/// Makes the matte of a pick: the prepared frame, its pts, the points, the matte to correct (on another frame) and the
/// span the frame is shown for. `None` = the points leave nothing.
pub type MagicPickMatte =
    Arc<dyn Fn(&InstanceFrame, f64, &[MagicPoint], Option<&SubjectMatte>, f64) -> Option<SubjectMatte> + Send + Sync>;

/// Where a pick's matte is stored (the app's matte store).
pub trait MatteStoring {
    /// Stores `matte` for the frame at `pts` under `key`.
    fn put(&self, matte: SubjectMatte, key: &str, pts: f64);
    /// Writes the key's mattes to disk later (queued behind other saves).
    fn save_later(&self, key: &str);
}

/// Field order of a file's frames (`None` = progressive).
pub type DeinterlaceOf = dyn Fn(&Path) -> Option<FieldOrder>;

/// Why the last request for a frame gave no objects although the frame may have some.
#[derive(Clone, Debug, PartialEq)]
pub enum MagicProblem {
    /// The read or the segmentation failed (the error's text).
    Failed(String),
    /// No answer within the deadline (seconds).
    TimedOut(f64),
}

/// How a pick ended.
#[derive(Clone, Debug, PartialEq)]
pub enum PickResult {
    /// The matte is stored.
    Stored,
    /// The points leave nothing (blank matte): nothing was stored.
    Nothing,
    /// Nothing to work on: no frame is prepared, the points belong to another frame, or the frame changed meanwhile.
    Refused,
    /// The matte was not made within the deadline (seconds): nothing was stored.
    GaveUp(f64),
    /// Vision found no foreground object at the first click (or no frame is prepared): nothing was stored here, the
    /// point stays and the tracking leg's point-prompt segmenter makes the first matte (a click always yields a mask).
    Deferred,
}

enum Outcome {
    Ready(InstanceFrame, f64),
    Empty,
    Failed(String),
    TimedOut,
}

struct Shown {
    media: Id,
    source_time: Time,
    frame: Arc<InstanceFrame>,
    pts: f64,
}

struct Pending {
    media: Id,
    source_time: Time,
    id: i64,
    started: Duration,
}

struct ProblemRecord {
    media: Id,
    source_time: Time,
    what: MagicProblem,
    at: Duration,
}

/// What a session needs from its host.
pub struct MagicMaskDeps {
    /// Seconds one request may take (Swift `WorkLimits.subjectFrameDeadline`).
    pub timeout: f64,
    /// Seconds before a frame whose request failed is run again without a click (one that timed out: only by a click).
    pub retry_delay: f64,
    pub segment: MagicShapedSegment,
    pub pick_matte: MagicPickMatte,
    /// Called when a click runs a frame again whose request timed out: the frame work moves to a fresh thread.
    pub on_restart: Arc<dyn Fn() + Send + Sync>,
    pub clock: Arc<dyn Clock>,
}

impl MagicMaskDeps {
    /// Default deadline (seconds) of one request.
    pub const DEFAULT_TIMEOUT: f64 = 8.0;

    /// Deps for a segmenter that ignores the pixel shape (Swift `segment:` initializer argument).
    pub fn with_segment(segment: MagicSegment, pick_matte: MagicPickMatte) -> MagicMaskDeps {
        MagicMaskDeps {
            timeout: Self::DEFAULT_TIMEOUT,
            retry_delay: 1.0,
            segment: Arc::new(move |url, s, _, _| segment(url, s)),
            pick_matte,
            on_restart: Arc::new(|| {}),
            clock: Arc::new(SystemClock::new()),
        }
    }
}

/// A segmentation to run on a worker.
pub struct MagicRequest {
    id: i64,
    seconds: f64,
    url: PathBuf,
    aspect: PixelAspect,
    fields: Option<FieldOrder>,
    run: MagicShapedSegment,
}

/// The answer of a [`MagicRequest`].
pub struct MagicResult {
    id: i64,
    outcome: Outcome,
}

impl MagicRequest {
    /// Segments the frame (blocking).
    pub fn run(self) -> MagicResult {
        let outcome = match (self.run)(&self.url, self.seconds, self.aspect, self.fields) {
            Ok(Some((frame, pts))) => Outcome::Ready(frame, pts),
            Ok(None) => Outcome::Empty,
            Err(why) => Outcome::Failed(why),
        };
        MagicResult { id: self.id, outcome }
    }
}

/// What one `prepare` call decided (one turn of Swift's `prepare` loop).
pub enum PrepareStep {
    /// The frame's objects are known.
    Ready,
    /// This call is done without a frame (empty, failed, timed out, replaced by another frame, waiting for a click).
    NotReady,
    /// A request for this frame runs: wait until `version` changes, then ask again.
    Wait,
    /// Run the request on a worker and hand its result to `finish`, then ask again.
    Start(MagicRequest),
}

/// The flags of one `prepare` call across its turns.
#[derive(Clone, Copy, Debug, Default)]
pub struct PrepareCall {
    started: bool,
    joined: bool,
}

/// A soft matte to make on a worker (latest wins: a stale request is skipped before it runs).
pub struct SoftMatteRequest {
    label: u8,
    token: u64,
    generation: u64,
    frame: Arc<InstanceFrame>,
    wanted: Arc<AtomicU64>,
}

/// The answer of a [`SoftMatteRequest`].
pub struct SoftMatteResult {
    label: u8,
    generation: u64,
    matte: Option<SubjectMatte>,
}

impl SoftMatteRequest {
    /// The label this request makes the matte of.
    pub fn label(&self) -> u8 {
        self.label
    }

    /// Makes the matte unless a newer request replaced this one.
    pub fn run(self) -> SoftMatteResult {
        let matte = (self.wanted.load(Ordering::SeqCst) == self.token)
            .then(|| (self.frame.soft)(&BTreeSet::from([self.label])));
        SoftMatteResult { label: self.label, generation: self.generation, matte }
    }
}

/// What a pick does next.
pub enum PickStep {
    /// Decided without any work.
    Done(PickResult),
    /// Run the request on a worker (with the deadline), then call `finish_pick` with its outcome (`None` = deadline).
    Run(PickRequest),
}

/// A pick to run on a worker.
pub struct PickRequest {
    key: String,
    pts: f64,
    generation: u64,
    frame: Arc<InstanceFrame>,
    points: Vec<MagicPoint>,
    from: Option<SubjectMatte>,
    span: f64,
    first_pick: bool,
    pick_matte: MagicPickMatte,
}

/// The answer of a [`PickRequest`].
pub struct PickOutcome {
    key: String,
    pts: f64,
    generation: u64,
    matte: Option<SubjectMatte>,
    deferrable: bool,
}

impl PickRequest {
    /// Makes the matte (blocking).
    pub fn run(self) -> PickOutcome {
        let matte = (self.pick_matte)(&self.frame, self.pts, &self.points, self.from.as_ref(), self.span);
        PickOutcome { key: self.key, pts: self.pts, generation: self.generation, matte, deferrable: self.first_pick }
    }
}

/// Magic mode on the Program monitor (see the module docs).
// Swift: MagicMaskSession.swift:23
pub struct MagicMaskSession {
    segment: MagicShapedSegment,
    pick_matte: MagicPickMatte,
    /// Shape of a file's stored pixels, set by the host: hover and a pick see the frame as it is shown, like Track does,
    /// so the pick's matte and the tracked ones have one shape. A point is a fraction of the upright shown picture
    /// (origin top left), whatever the file's rotation or pixel shape.
    // Swift: MagicMaskSession.swift:59
    pub pixel_aspect: Box<dyn Fn(&Path) -> PixelAspect>,
    /// Field order a file's frames are deinterlaced with (`None` for progressive media and an item with Deinterlace
    /// off), set by the host: hover and a pick see the frames the monitor shows.
    // Swift: MagicMaskSession.swift:62
    pub deinterlace: Box<DeinterlaceOf>,
    timeout: f64,
    retry_delay: f64,
    clock: Arc<dyn Clock>,
    on_restart: Arc<dyn Fn() + Send + Sync>,
    shown: Option<Shown>,
    pending: Option<Pending>,
    /// The frame that was segmented and shows no object.
    empty: Option<(Id, Time)>,
    problem: Option<ProblemRecord>,
    next_id: i64,
    hover_cache: BTreeMap<u8, SubjectMatte>,
    soft_wanted: Arc<AtomicU64>,
    /// Moves on with every new frame and reset: a soft matte of an older frame is not kept.
    frame_generation: u64,
    version: u64,
}

impl MagicMaskSession {
    // Swift: MagicMaskSession.swift:88
    pub fn new(deps: MagicMaskDeps) -> MagicMaskSession {
        MagicMaskSession {
            segment: deps.segment,
            pick_matte: deps.pick_matte,
            pixel_aspect: Box::new(|_| PixelAspect::square()),
            deinterlace: Box::new(|_| None),
            timeout: deps.timeout,
            retry_delay: deps.retry_delay,
            clock: deps.clock,
            on_restart: deps.on_restart,
            shown: None,
            pending: None,
            empty: None,
            problem: None,
            next_id: 0,
            hover_cache: BTreeMap::new(),
            soft_wanted: Arc::new(AtomicU64::new(0)),
            frame_generation: 0,
            version: 0,
        }
    }

    /// Moves on with every change a waiting caller could care about (a request ended, a reset).
    pub fn version(&self) -> u64 {
        self.version
    }

    /// True when the objects of this frame are known (hover and picks work).
    // Swift: MagicMaskSession.swift:107
    pub fn is_ready(&self, media: Id, source_time: Time) -> bool {
        self.shown.as_ref().is_some_and(|s| s.media == media && s.source_time == source_time)
    }

    /// True when this frame was segmented and shows no object: `prepare` does not run it again without `retry`. A
    /// request that failed or timed out is not this (`problem`).
    // Swift: MagicMaskSession.swift:113
    pub fn has_failed(&self, media: Id, source_time: Time) -> bool {
        self.empty.is_some_and(|e| e == (media, source_time))
    }

    /// Why the last request for this frame gave nothing although it may show objects (read error, timeout).
    // Swift: MagicMaskSession.swift:118
    pub fn problem(&self, media: Id, source_time: Time) -> Option<&MagicProblem> {
        self.problem.as_ref().filter(|p| p.media == media && p.source_time == source_time).map(|p| &p.what)
    }

    /// True while this frame's request runs.
    // Swift: MagicMaskSession.swift:123
    pub fn is_pending(&self, media: Id, source_time: Time) -> bool {
        self.pending.as_ref().is_some_and(|p| p.media == media && p.source_time == source_time)
    }

    /// True when `prepare` (without `retry`) would start a request for this frame now: not ready, not on its way, not
    /// known to be empty, not failed within the last `retry_delay` seconds and not timed out.
    // Swift: MagicMaskSession.swift:129
    pub fn wants_prepare(&self, media: Id, source_time: Time) -> bool {
        if self.is_ready(media, source_time) || self.is_pending(media, source_time) {
            return false;
        }
        if self.has_failed(media, source_time) {
            return false;
        }
        !self.waits_for_a_click(media, source_time)
    }

    /// A frame whose request timed out (until a click), or failed within the last `retry_delay` seconds.
    fn waits_for_a_click(&self, media: Id, source_time: Time) -> bool {
        let Some(p) = self.problem.as_ref().filter(|p| p.media == media && p.source_time == source_time) else {
            return false;
        };
        if matches!(p.what, MagicProblem::TimedOut(_)) {
            return true;
        }
        self.clock.now().saturating_sub(p.at) < Duration::from_secs_f64(self.retry_delay)
    }

    /// One turn of Swift's `prepare` loop: segments the frame at `source_time` unless it is already known, known to be
    /// empty or on its way (then waits for that request, also when this caller's own request for the frame was
    /// replaced meanwhile: F, G, F again). A newer frame cancels the older request. `retry` (a click) runs a frame
    /// again that gave nothing or failed before: nothing one request did switches a frame off for the rest of the app
    /// run. Call again after `Wait` (when `version` moved) and after `Start` (once `finish` ran) until `Ready` or
    /// `NotReady`; `call` carries the flags between turns.
    // Swift: MagicMaskSession.swift:146
    pub fn prepare(
        &mut self,
        call: &mut PrepareCall,
        media: Id,
        url: &Path,
        source_time: Time,
        retry: bool,
    ) -> PrepareStep {
        if self.is_ready(media, source_time) {
            return PrepareStep::Ready;
        }
        if self.is_pending(media, source_time) {
            call.joined = true;
            return PrepareStep::Wait;
        }
        // A caller that joined a request which failed or timed out reports that failure; it does not start the retry
        // itself (with a short `retry_delay` the waiters would race: the one that retried first would leave the others
        // waiting for the retry, and nobody would tell the failure).
        if call.joined && !call.started && !retry && self.problem(media, source_time).is_some() {
            return PrepareStep::NotReady;
        }
        // This call's own request ended without a frame (empty, failed, timed out, replaced by another frame).
        if call.started {
            return PrepareStep::NotReady;
        }
        if self.has_failed(media, source_time) {
            if !retry {
                return PrepareStep::NotReady;
            }
            self.empty = None;
        }
        if !retry && self.waits_for_a_click(media, source_time) {
            return PrepareStep::NotReady;
        }
        if retry && matches!(self.problem(media, source_time), Some(MagicProblem::TimedOut(_))) {
            (self.on_restart)();
        }
        call.started = true;
        PrepareStep::Start(self.start(media, url, source_time))
    }

    fn start(&mut self, media: Id, url: &Path, source_time: Time) -> MagicRequest {
        if self.pending.is_some() {
            self.pending = None; // replaced by a newer frame: its late result is ignored
            self.version += 1;
        }
        self.next_id += 1;
        let id = self.next_id;
        let seconds = source_time.value() as f64 / source_time.timescale().max(1) as f64;
        self.pending = Some(Pending { media, source_time, id, started: self.clock.now() });
        MagicRequest {
            id,
            seconds,
            url: url.to_path_buf(),
            aspect: (self.pixel_aspect)(url),
            fields: (self.deinterlace)(url),
            run: Arc::clone(&self.segment),
        }
    }

    /// Gives up a request that is older than `timeout` (the host calls this on a timer and before it asks again). Returns
    /// whether it did.
    pub fn expire(&mut self) -> bool {
        let Some(p) = &self.pending else { return false };
        if self.clock.now().saturating_sub(p.started) < Duration::from_secs_f64(self.timeout) {
            return false;
        }
        let id = p.id;
        self.finish(MagicResult { id, outcome: Outcome::TimedOut });
        true
    }

    /// Applies the result of a request once. A result of a request that was replaced, reset or given up is ignored.
    pub fn finish(&mut self, result: MagicResult) {
        let Some(p) = self.pending.take_if(|p| p.id == result.id) else { return };
        self.hover_cache.clear();
        self.frame_generation += 1;
        self.soft_wanted.fetch_add(1, Ordering::SeqCst);
        self.version += 1;
        match result.outcome {
            Outcome::Ready(frame, pts) => {
                self.shown = Some(Shown { media: p.media, source_time: p.source_time, frame: Arc::new(frame), pts });
                self.empty = None;
                self.problem = None;
            }
            Outcome::Empty => {
                self.shown = None;
                self.problem = None;
                self.empty = Some((p.media, p.source_time));
            }
            Outcome::Failed(why) => {
                self.shown = None;
                self.empty = None;
                self.problem = Some(ProblemRecord {
                    media: p.media,
                    source_time: p.source_time,
                    what: MagicProblem::Failed(why),
                    at: self.clock.now(),
                });
            }
            Outcome::TimedOut => {
                self.shown = None;
                self.empty = None;
                self.problem = Some(ProblemRecord {
                    media: p.media,
                    source_time: p.source_time,
                    what: MagicProblem::TimedOut(self.timeout),
                    at: self.clock.now(),
                });
            }
        }
    }

    /// Forgets the shown frame (other clip, playback started) and stops a running request.
    // Swift: MagicMaskSession.swift:250
    pub fn reset(&mut self) {
        self.pending = None;
        self.shown = None;
        self.empty = None;
        self.problem = None;
        self.hover_cache.clear();
        self.frame_generation += 1;
        self.soft_wanted.fetch_add(1, Ordering::SeqCst);
        self.version += 1;
    }

    /// The object under frame fraction `p` of the prepared frame: its label and matte; `None` over the background.
    /// Never runs the segmenter: the matte is the soft matte when it was made before (the flag is true), else the hard
    /// labels; [`Self::soft_matte`] asks for the soft one.
    // Swift: MagicMaskSession.swift:260
    pub fn hover(&self, p: Vec2) -> Option<(u8, SubjectMatte, bool)> {
        let f = &self.shown.as_ref()?.frame;
        let l = f.labels.label_at(p);
        if l == 0 {
            return None;
        }
        if let Some(m) = self.hover_cache.get(&l) {
            return Some((l, m.clone(), true));
        }
        Some((l, f.labels.matte_of(&BTreeSet::from([l])), false))
    }

    /// The soft matte of object `label` of the prepared frame: the cached one, or a request to run off the UI thread
    /// (with the deadline `timeout` seconds). Asking for a label makes older requests skip (latest wins).
    // Swift: MagicMaskSession.swift:270
    pub fn soft_matte(&mut self, label: u8) -> Result<SubjectMatte, Option<SoftMatteRequest>> {
        let Some(s) = &self.shown else { return Err(None) };
        if label == 0 {
            return Err(None);
        }
        if let Some(m) = self.hover_cache.get(&label) {
            return Ok(m.clone());
        }
        let token = self.soft_wanted.fetch_add(1, Ordering::SeqCst) + 1;
        Err(Some(SoftMatteRequest {
            label,
            token,
            generation: self.frame_generation,
            frame: Arc::clone(&s.frame),
            wanted: Arc::clone(&self.soft_wanted),
        }))
    }

    /// Keeps a finished soft matte (not when the frame changed or the request was skipped) and returns it.
    pub fn finish_soft(&mut self, result: SoftMatteResult) -> Option<SubjectMatte> {
        let m = result.matte?;
        if result.generation != self.frame_generation {
            return None; // a new frame or a reset meanwhile
        }
        self.hover_cache.insert(result.label, m.clone());
        Some(m)
    }

    /// The prepared frame's pts (seconds): where its matte is stored.
    // Swift: MagicMaskSession.swift:287
    pub fn shown_pts(&self) -> Option<f64> {
        self.shown.as_ref().map(|s| s.pts)
    }

    /// Stores the matte of `points` on the prepared frame under `key` (the mask's cache key). On the pick's own frame the
    /// points pick; on another frame `start` (the tracked matte there before the correction) is corrected by the points
    /// made on it. The matte is made off the UI thread within `timeout`, and stored when it arrives
    /// ([`Self::finish_pick`]).
    // Swift: MagicMaskSession.swift:313
    pub fn pick(&mut self, points: &[MagicPoint], key: &str, start: Option<SubjectMatte>) -> PickStep {
        let anchor = points.first().map(|p| p.source_time);
        let Some(s) = self.shown.as_ref() else {
            // A first pick without a Vision frame is not gated by it: the point prompt segments it while tracking.
            let first = start.is_none() && points.iter().any(|p| !p.subtract);
            return PickStep::Done(if first { PickResult::Deferred } else { PickResult::Refused });
        };
        let Some(anchor) = anchor.filter(|a| *a == s.source_time || start.is_some()) else {
            return PickStep::Done(PickResult::Refused); // the points belong to another frame
        };
        // Points are stored at the playhead's source time; the decoded frame lies at or up to one file frame before it.
        let here = s.source_time.value() as f64 / s.source_time.timescale().max(1) as f64;
        let from = if anchor == s.source_time { None } else { start.clone() };
        let span = (here - s.pts).max(0.0) + 2.0 * MagicFollower::POINT_TOLERANCE;
        let first_pick = from.is_none() && start.is_none() && points.iter().any(|p| !p.subtract);
        PickStep::Run(PickRequest {
            key: key.to_string(),
            pts: s.pts,
            generation: self.frame_generation,
            frame: Arc::clone(&s.frame),
            points: points.to_vec(),
            from,
            span,
            first_pick,
            pick_matte: Arc::clone(&self.pick_matte),
        })
    }

    /// Ends a pick: `outcome` is the request's answer, `None` when the deadline passed first. A click also moves a stuck
    /// request on (`on_restart`).
    pub fn finish_pick(&mut self, outcome: Option<PickOutcome>, store: &dyn MatteStoring) -> PickResult {
        let Some(o) = outcome else {
            (self.on_restart)();
            return PickResult::GaveUp(self.timeout);
        };
        if o.generation != self.frame_generation {
            return PickResult::Refused; // the frame changed meanwhile
        }
        match o.matte {
            Some(m) => {
                store.put(m, &o.key, o.pts);
                // Queued behind the other saves: the pick answers on the UI thread, the write is the whole matte list.
                store.save_later(&o.key);
                PickResult::Stored
            }
            // Vision labels are not the last word on a first click: the point prompt decides while tracking.
            None if o.deferrable => PickResult::Deferred,
            None => PickResult::Nothing,
        }
    }
}

/// Draws a matte as a tinted see-through image (Magic hover / pick highlight on the monitor).
// Swift: MagicMaskSession.swift:353
pub enum MagicHighlight {}

impl MagicHighlight {
    /// The default tint: sRGB 0.98, 0.80, 0.20.
    pub const DEFAULT_COLOR: [f32; 3] = [0.98, 0.80, 0.20];
    /// The default opacity.
    pub const DEFAULT_ALPHA: f32 = 0.45;

    /// Accent-colored image, alpha = matte * `alpha` (premultiplied RGBA, row 0 at the top); channels truncate like the
    /// vector conversion of the Swift version.
    // Swift: MagicMaskSession.swift:359
    pub fn image(m: &SubjectMatte, color: [f32; 3], alpha: f32) -> Option<RgbaImage> {
        let (width, height) = (m.width(), m.height());
        let mut rgba = Vec::with_capacity(width * height * 4);
        for v in &m.values {
            let a = v.clamp(0.0, 1.0) * alpha * 255.0;
            rgba.extend_from_slice(&[(color[0] * a) as u8, (color[1] * a) as u8, (color[2] * a) as u8, a as u8]);
        }
        Some(RgbaImage { width, height, rgba })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::magic_mask::InstanceLabels;
    use sq_runtime::FakeClock;
    use std::sync::Mutex;

    fn media() -> Id {
        Id::from_u128(1)
    }

    fn t(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// A 2 x 1 frame: left object 1, right object 2.
    fn frame() -> InstanceFrame {
        InstanceFrame::new(InstanceLabels::new(2, 1, vec![1, 2]), None)
    }

    fn deps(clock: Arc<FakeClock>, answer: Arc<Mutex<Result<Option<f64>, String>>>) -> MagicMaskDeps {
        MagicMaskDeps {
            timeout: 8.0,
            retry_delay: 1.0,
            segment: Arc::new(move |_, _, _, _| {
                answer.lock().expect("lock").clone().map(|o| o.map(|pts| (frame(), pts)))
            }),
            pick_matte: Arc::new(|f, _, pts, _, _| {
                let l = f.labels.label_at(pts[0].position);
                (l != 0).then(|| f.labels.matte_of(&BTreeSet::from([l])))
            }),
            on_restart: Arc::new(|| {}),
            clock,
        }
    }

    fn point(x: f64) -> MagicPoint {
        MagicPoint { position: Vec2::new(x, 0.5), subtract: false, source_time: t(3) }
    }

    /// Runs one `prepare` to its end the way a host would.
    fn prepare(s: &mut MagicMaskSession, retry: bool) -> bool {
        let mut call = PrepareCall::default();
        loop {
            match s.prepare(&mut call, media(), Path::new("/a.mov"), t(3), retry) {
                PrepareStep::Ready => return true,
                PrepareStep::NotReady | PrepareStep::Wait => return false,
                PrepareStep::Start(r) => s.finish(r.run()),
            }
        }
    }

    struct Store(Mutex<Vec<(String, f64)>>);
    impl MatteStoring for Store {
        fn put(&self, _: SubjectMatte, key: &str, pts: f64) {
            self.0.lock().expect("lock").push((key.to_string(), pts));
        }
        fn save_later(&self, _: &str) {}
    }

    #[test]
    fn a_frame_becomes_ready_and_hover_finds_the_object() {
        let clock = Arc::new(FakeClock::new());
        let mut s = MagicMaskSession::new(deps(clock, Arc::new(Mutex::new(Ok(Some(2.9))))));
        assert!(s.wants_prepare(media(), t(3)));
        assert!(prepare(&mut s, false));
        assert!(s.is_ready(media(), t(3)) && !s.wants_prepare(media(), t(3)));
        assert_eq!(s.shown_pts(), Some(2.9));
        let (label, matte, soft) = s.hover(Vec2::new(0.9, 0.5)).expect("object");
        assert_eq!((label, soft), (2, false));
        assert_eq!(matte.values, vec![0.0, 1.0]);
        assert!(s.hover(Vec2::new(2.0, 0.5)).is_none());
        s.reset();
        assert!(!s.is_ready(media(), t(3)) && s.hover(Vec2::new(0.1, 0.5)).is_none());
    }

    #[test]
    fn an_empty_frame_is_remembered_until_a_click_asks_again() {
        let clock = Arc::new(FakeClock::new());
        let answer = Arc::new(Mutex::new(Ok(None)));
        let mut s = MagicMaskSession::new(deps(clock, Arc::clone(&answer)));
        assert!(!prepare(&mut s, false));
        assert!(s.has_failed(media(), t(3)) && !s.wants_prepare(media(), t(3)));
        assert!(!prepare(&mut s, false)); // not run again without a click
        *answer.lock().expect("lock") = Ok(Some(3.0));
        assert!(prepare(&mut s, true)); // a click runs it again
        assert!(!s.has_failed(media(), t(3)));
    }

    #[test]
    fn a_failed_request_retries_after_the_delay_and_a_timeout_only_by_click() {
        let clock = Arc::new(FakeClock::new());
        let answer = Arc::new(Mutex::new(Err("decoder said no".to_string())));
        let mut s = MagicMaskSession::new(deps(Arc::clone(&clock), Arc::clone(&answer)));
        assert!(!prepare(&mut s, false));
        assert_eq!(s.problem(media(), t(3)), Some(&MagicProblem::Failed("decoder said no".into())));
        assert!(!s.wants_prepare(media(), t(3))); // within the retry delay
        clock.advance(Duration::from_millis(1100));
        assert!(s.wants_prepare(media(), t(3)));
        *answer.lock().expect("lock") = Ok(Some(3.0));
        assert!(prepare(&mut s, false));
        assert_eq!(s.problem(media(), t(3)), None);

        // A request that hangs: given up after the timeout, then only a click starts it again.
        s.reset();
        let mut call = PrepareCall::default();
        let PrepareStep::Start(hung) = s.prepare(&mut call, media(), Path::new("/a.mov"), t(3), false) else {
            panic!("starts");
        };
        assert!(s.is_pending(media(), t(3)) && !s.expire());
        clock.advance(Duration::from_secs(9));
        assert!(s.expire() && !s.is_pending(media(), t(3)));
        assert_eq!(s.problem(media(), t(3)), Some(&MagicProblem::TimedOut(8.0)));
        s.finish(hung.run()); // the late result is ignored
        assert!(!s.is_ready(media(), t(3)));
        clock.advance(Duration::from_secs(60));
        assert!(!s.wants_prepare(media(), t(3)));
        assert!(prepare(&mut s, true));
    }

    #[test]
    fn a_newer_frame_replaces_the_older_request() {
        let clock = Arc::new(FakeClock::new());
        let mut s = MagicMaskSession::new(deps(clock, Arc::new(Mutex::new(Ok(Some(1.0))))));
        let mut a = PrepareCall::default();
        let PrepareStep::Start(old) = s.prepare(&mut a, media(), Path::new("/a.mov"), t(1), false) else {
            panic!("starts")
        };
        let mut b = PrepareCall::default();
        let PrepareStep::Start(new) = s.prepare(&mut b, media(), Path::new("/a.mov"), t(2), false) else {
            panic!("starts")
        };
        assert!(!s.is_pending(media(), t(1)) && s.is_pending(media(), t(2)));
        s.finish(old.run());
        assert!(!s.is_ready(media(), t(1)));
        s.finish(new.run());
        assert!(s.is_ready(media(), t(2)));
    }

    #[test]
    fn a_pick_is_stored_refused_or_deferred() {
        let clock = Arc::new(FakeClock::new());
        let mut s = MagicMaskSession::new(deps(clock, Arc::new(Mutex::new(Ok(Some(3.0))))));
        let store = Store(Mutex::new(Vec::new()));
        // No prepared frame: a first add point is deferred to the tracker, a remove point is refused.
        assert!(matches!(s.pick(&[point(0.1)], "k", None), PickStep::Done(PickResult::Deferred)));
        let remove = MagicPoint { subtract: true, ..point(0.1) };
        assert!(matches!(s.pick(&[remove], "k", None), PickStep::Done(PickResult::Refused)));
        assert!(prepare(&mut s, false));
        // Another frame without a start matte: refused.
        let other = MagicPoint { source_time: t(9), ..point(0.1) };
        assert!(matches!(s.pick(&[other], "k", None), PickStep::Done(PickResult::Refused)));
        // Own frame: stored under the key at the frame's pts.
        let PickStep::Run(req) = s.pick(&[point(0.1)], "k", None) else { panic!("runs") };
        assert_eq!(s.finish_pick(Some(req.run()), &store), PickResult::Stored);
        assert_eq!(store.0.lock().expect("lock").as_slice(), &[("k".to_string(), 3.0)]);
        // Over the background: nothing found; the first click is deferred, a correction is not.
        let off = MagicPoint { position: Vec2::new(5.0, 5.0), ..point(0.1) };
        let PickStep::Run(req) = s.pick(&[off], "k", None) else { panic!("runs") };
        assert_eq!(s.finish_pick(Some(req.run()), &store), PickResult::Deferred);
        let PickStep::Run(req) = s.pick(&[off], "k", Some(SubjectMatte::new(2, 1, vec![0.0, 0.0]))) else {
            panic!("runs")
        };
        assert_eq!(s.finish_pick(Some(req.run()), &store), PickResult::Nothing);
        // A deadline, and a frame that changed meanwhile.
        let PickStep::Run(req) = s.pick(&[point(0.1)], "k", None) else { panic!("runs") };
        assert_eq!(s.finish_pick(None, &store), PickResult::GaveUp(8.0));
        let late = req.run();
        s.reset();
        assert_eq!(s.finish_pick(Some(late), &store), PickResult::Refused);
    }

    #[test]
    fn soft_mattes_are_made_once_and_the_latest_label_wins() {
        let clock = Arc::new(FakeClock::new());
        let mut s = MagicMaskSession::new(deps(clock, Arc::new(Mutex::new(Ok(Some(3.0))))));
        assert!(matches!(s.soft_matte(1), Err(None))); // nothing prepared
        assert!(prepare(&mut s, false));
        assert!(matches!(s.soft_matte(0), Err(None)));
        let Err(Some(first)) = s.soft_matte(1) else { panic!("request") };
        let Err(Some(second)) = s.soft_matte(2) else { panic!("request") };
        assert_eq!((first.label(), second.label()), (1, 2));
        assert!(s.finish_soft(first.run()).is_none()); // skipped: a newer label was asked for
        let m = s.finish_soft(second.run()).expect("made");
        assert_eq!(m.values, vec![0.0, 1.0]);
        assert!(s.soft_matte(2).is_ok());
        assert_eq!(s.hover(Vec2::new(0.9, 0.5)).map(|h| h.2), Some(true));
    }

    #[test]
    fn highlight_premultiplies_the_tint_by_matte_and_alpha() {
        let m = SubjectMatte::new(2, 1, vec![1.0, 0.0]);
        let img = MagicHighlight::image(&m, [1.0, 0.5, 0.0], 0.5).expect("image");
        assert_eq!((img.width, img.height), (2, 1));
        assert_eq!(img.rgba, vec![127, 63, 0, 127, 0, 0, 0, 0]);
    }
}
