//! The Magic Mask flow between the panels and the tracking job: the Program monitor collects clicks (and a dragged box)
//! until Enter confirms them, Effect Controls asks for tracking steps, and the [`MagicRunner`] on the UI thread turns both
//! into a Magic mask on the selected clip and a background [`MagicTrackJob`].
// The Swift app takes point prompts only; a dragged box becomes one add click at its center there too (kept as the reference
// behavior: the exported EdgeTAM decoder has point inputs only, "Magic Mask box prompts").

use super::ffmpeg_frames::{FfmpegMaskFrames, FfmpegTrackFrames};
use super::magic_job::{
    Correction, EdgeTamTracker, EdgedTracker, MagicTrackJob, TrackFrames, TrackMessage, Tracker, WakeFn,
    add_magic_mask_with, model_folder, split_points,
};
use super::mask_track::{MaskFrameSource, MaskTrackJob, MaskTrackMessage, MaskTrackPlan};
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_analysis::subject_mask_quality::SubjectEdgesChoice;
use sq_analysis::subject_matte_refiner::SubjectMatteEdger;
use sq_core_masks::magic_mask::MagicSelectionExt;
use sq_core_masks::mask_inputs::MaskInputsExt;
use sq_core_masks::mask_motion::MaskTrackMode;
use sq_core_masks::mask_path_editing::MaskTrackingExt;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::{MagicPoint, MaskSource};
use sq_core_time::{Id, IdSource, Time, Vec2};
use sq_editor_session::EditorSession;
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

/// What the panels ask the runner for.
#[derive(Clone, Debug, PartialEq)]
pub enum FlowRequest {
    /// Enter: the clicks `(frame fraction, subtract)` join the clip's Magic mask (on the pick's frame they add or remove
    /// objects, on another frame they correct the tracked matte from there on) or, with no Magic mask yet, pick one.
    Confirm(Vec<(Vec2, bool)>),
    /// Shift-Enter: the clicks pick a new Magic mask next to the existing ones.
    ConfirmNew(Vec<(Vec2, bool)>),
    /// Track a Magic mask one frame back or forward, `None` = stop.
    TrackMagic { mask: Id, step: Option<bool> },
    /// The Stabilizer row's Start: analyze this clip's Standard Stabilizer (again if it already is analyzed).
    StabilizeStart(Id),
    /// The row's Stop.
    StabilizeStop,
    /// Track a drawn mask over the clip, following what `mode` says.
    TrackMask { mask: Id, forward: bool, mode: MaskTrackMode },
}

#[derive(Default)]
struct FlowState {
    armed: bool,
    /// Shift was held on a click: the prompt starts a new mask.
    new_mask: bool,
    points: Vec<(Vec2, bool)>,
    requests: Vec<FlowRequest>,
}

/// A handle shared by the monitor host and the inspector host (clones see the same state).
#[derive(Clone, Default)]
pub struct MagicFlow(Rc<RefCell<FlowState>>);

impl MagicFlow {
    /// The Magic tool is chosen: clicks and Enter count.
    pub fn arm(&self, on: bool) {
        let mut s = self.0.borrow_mut();
        s.armed = on;
        if !on {
            s.points.clear();
        }
    }

    /// True while the Magic tool is chosen.
    pub fn is_armed(&self) -> bool {
        self.0.borrow().armed
    }

    /// A click on the picture (frame fraction): adds a prompt point.
    pub fn click(&self, at: Vec2, subtract: bool) {
        self.click_with(at, subtract, false);
    }

    /// [`MagicFlow::click`]; `new_mask` (Shift) makes the prompt a new mask instead of a change of the existing one.
    pub fn click_with(&self, at: Vec2, subtract: bool, new_mask: bool) {
        let mut s = self.0.borrow_mut();
        if s.armed {
            s.new_mask |= new_mask;
            s.points.push((at, subtract));
        }
    }

    /// A box dragged from `a` to `b` (frame fractions): one add point at its center.
    pub fn drag_box(&self, a: Vec2, b: Vec2) {
        self.click(Vec2::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0), false);
    }

    /// The prompt so far.
    pub fn points(&self) -> Vec<(Vec2, bool)> {
        self.0.borrow().points.clone()
    }

    /// Enter: the prompt becomes a request. Nothing happens without a point.
    pub fn confirm(&self) {
        let mut s = self.0.borrow_mut();
        if s.armed && !s.points.is_empty() {
            let points = std::mem::take(&mut s.points);
            let request = if std::mem::take(&mut s.new_mask) {
                FlowRequest::ConfirmNew(points)
            } else {
                FlowRequest::Confirm(points)
            };
            s.requests.push(request);
        }
    }

    /// Escape: forgets the prompt.
    pub fn cancel(&self) {
        let mut s = self.0.borrow_mut();
        s.points.clear();
        s.new_mask = false;
    }

    /// Effect Controls' track buttons.
    pub fn request(&self, request: FlowRequest) {
        self.0.borrow_mut().requests.push(request);
    }

    /// The requests since the last call, in order.
    pub fn take_requests(&self) -> Vec<FlowRequest> {
        std::mem::take(&mut self.0.borrow_mut().requests)
    }
}

/// Where a run gets its frames and its model; tests put fakes here.
pub trait RunSources {
    /// The frames from `from` to `to` (source seconds as time) of `path`.
    fn frames(&self, path: &Path, from: Time, to: Time) -> Result<Box<dyn TrackFrames>, String>;
    /// Loads the model; runs on the job's thread.
    fn tracker(&self) -> Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send>;
    /// Opens the pictures of `path` for tracking a drawn mask; runs on the job's thread.
    fn mask_frames(&self, _path: &Path) -> Box<dyn FnOnce() -> Result<Box<dyn MaskFrameSource>, String> + Send> {
        Box::new(|| Err("Tracking a drawn mask needs a video file.".to_string()))
    }
}

/// FFmpeg frames and the EdgeTAM model from the support folder.
pub struct SystemSources {
    /// The app's support folder (`SubjectMask` inside it holds the model).
    pub support: PathBuf,
    /// Subject Mask Edges: read when a run begins (Swift `decide`), so a run keeps one edge and size.
    pub edges: SubjectEdgesChoice,
}

impl RunSources for SystemSources {
    fn frames(&self, path: &Path, from: Time, to: Time) -> Result<Box<dyn TrackFrames>, String> {
        Ok(Box::new(FfmpegTrackFrames::open_with(path, from, to, self.edges.get())?))
    }

    fn tracker(&self) -> Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send> {
        let support = self.support.clone();
        // Read when the run begins, with the frames' size (Swift `decide`).
        let edger = SubjectMatteEdger::new(self.edges.get());
        Box::new(move || {
            let environment: HashMap<String, String> = std::env::vars().collect();
            let folder = model_folder(&support, &environment)?;
            Ok(Box::new(EdgedTracker::new(EdgeTamTracker::load(&folder)?, edger)) as Box<dyn Tracker>)
        })
    }

    fn mask_frames(&self, path: &Path) -> Box<dyn FnOnce() -> Result<Box<dyn MaskFrameSource>, String> + Send> {
        let path = path.to_path_buf();
        Box::new(move || Ok(Box::new(FfmpegMaskFrames::open(&path)?) as Box<dyn MaskFrameSource>))
    }
}

/// Runs the flow's requests on the UI thread and follows the job.
pub struct MagicRunner {
    store: Arc<FrameMatteStore>,
    sources: Box<dyn RunSources>,
    ids: Box<dyn IdSource>,
    job: Option<MagicTrackJob>,
    mask_job: Option<MaskTrackJob>,
    wake: WakeFn,
    progress: Option<f64>,
}

impl MagicRunner {
    /// A runner writing mattes into `store`.
    pub fn new(store: Arc<FrameMatteStore>, sources: Box<dyn RunSources>, ids: Box<dyn IdSource>) -> MagicRunner {
        MagicRunner { store, sources, ids, job: None, mask_job: None, wake: Arc::new(|| {}), progress: None }
    }

    /// Runs `wake` on the job's thread after each message, so the window polls the runner.
    pub fn set_wake(&mut self, wake: WakeFn) {
        self.wake = wake;
    }

    /// 0...1 while a run is going.
    pub fn progress(&self) -> Option<f64> {
        self.is_running().then(|| self.progress.unwrap_or(0.0))
    }

    /// True while a run is going.
    pub fn is_running(&self) -> bool {
        self.job.as_ref().is_some_and(|j| !j.is_finished()) || self.mask_job.as_ref().is_some_and(|j| !j.is_finished())
    }

    /// Carries out `requests`; returns status lines for the status bar.
    pub fn handle(&mut self, session: &mut EditorSession, requests: Vec<FlowRequest>) -> Vec<String> {
        let mut out = Vec::new();
        for request in requests {
            match request {
                FlowRequest::Confirm(points) => out.extend(self.confirm(session, &points, false)),
                FlowRequest::ConfirmNew(points) => out.extend(self.confirm(session, &points, true)),
                // Carried out by `AnalysisLinks` before the requests reach the runner.
                FlowRequest::StabilizeStart(_) | FlowRequest::StabilizeStop => {}
                FlowRequest::TrackMagic { step: None, .. } => {
                    if let Some(job) = &self.job {
                        job.stop();
                    }
                    if let Some(job) = &self.mask_job {
                        job.stop();
                    }
                }
                FlowRequest::TrackMagic { mask, step: Some(forward) } => out.extend(self.step(session, mask, forward)),
                FlowRequest::TrackMask { mask, forward, mode } => {
                    out.extend(self.track_drawn(session, mask, forward, mode));
                }
            }
        }
        out
    }

    /// Reads the job's messages; returns status lines. The finished run's mattes are already in the store.
    pub fn poll(&mut self) -> Vec<String> {
        let Some(job) = &mut self.job else { return Vec::new() };
        let mut out = Vec::new();
        for m in job.poll() {
            match m {
                TrackMessage::Progress(p) => {
                    self.progress = Some(p);
                    out.push(format!("Tracking mask: {:.0}%", p * 100.0));
                }
                TrackMessage::Done(outcome) => out.push(outcome.status()),
            }
        }
        if job.is_finished() {
            self.job = None;
            self.progress = None;
        }
        out
    }

    /// Reads the drawn-mask job; a finished (or stopped) run writes its path keys into the clip, one undo step.
    pub fn poll_masks(&mut self, session: &mut EditorSession) -> Vec<String> {
        let Some(job) = &mut self.mask_job else { return Vec::new() };
        let (messages, finished) = (job.poll(), job.is_finished());
        let mut out = Vec::new();
        for m in messages {
            match m {
                MaskTrackMessage::Progress(p) => {
                    self.progress = Some(p);
                    out.push(format!("Tracking mask: {:.0}%", p * 100.0));
                }
                MaskTrackMessage::Done(result) => {
                    out.push(self.write_track(session, result));
                }
            }
        }
        if finished {
            self.mask_job = None;
            self.progress = None;
        }
        out
    }

    fn write_track(&mut self, session: &mut EditorSession, r: super::mask_track::MaskTrackResult) -> String {
        if let Some(why) = &r.error {
            return format!("Mask tracking failed: {why}");
        }
        let Some(timeline) = session.display_timeline() else { return String::new() };
        let Some(mut clip) = find_clip(&timeline, r.clip) else { return String::new() };
        if clip.mask(r.mask).is_none() {
            return String::new();
        }
        let n = clip.apply_mask_track_segments(r.mask, &r.times, &r.segments, &r.motions, &mut *self.ids);
        if n > 0 {
            session.replace_displayed_clip(clip, "Track Mask", false);
        }
        if r.stopped {
            if n > 0 {
                format!("Mask tracking stopped; kept {n} frames.")
            } else {
                "Mask tracking stopped.".to_string()
            }
        } else if n > 1 {
            format!("Tracked the mask over {n} frames.")
        } else {
            "The mask could not be tracked from here.".to_string()
        }
    }

    fn track_drawn(
        &mut self,
        session: &mut EditorSession,
        mask: Id,
        forward: bool,
        mode: MaskTrackMode,
    ) -> Option<String> {
        if self.is_running() {
            return Some("Mask tracking is already running.".to_string());
        }
        let (clip, frame_duration) = selected_clip(session)?;
        let is_path = clip.masks().iter().find(|m| m.id == mask).is_some_and(|m| m.source() == MaskSource::Path);
        if !is_path {
            return Some("Select a drawn mask to track it.".to_string());
        }
        let Some(media) = session.project().media(clip.media) else {
            return Some("Mask tracking needs a video clip from a file.".to_string());
        };
        let local = session.playhead() - clip.start;
        if local < Time::ZERO || local >= clip.duration() {
            return Some("Put the playhead on the clip to track from there.".to_string());
        }
        let times = clip.mask_track_times(local.snapped(frame_duration), forward, frame_duration);
        if times.is_empty() {
            return Some("The mask could not be tracked from here.".to_string());
        }
        let open = self.sources.mask_frames(Path::new(&media.path));
        let plan = MaskTrackPlan { clip, mask, times, mode };
        self.mask_job = Some(MaskTrackJob::spawn(plan, open, Arc::clone(&self.wake)));
        Some(format!("Tracking mask {}...", if forward { "forward" } else { "backward" }))
    }

    fn confirm(&mut self, session: &mut EditorSession, clicks: &[(Vec2, bool)], new_mask: bool) -> Option<String> {
        let (clip, frame_duration) = selected_clip(session)?;
        let at = clip.source_time(session.playhead(), frame_duration);
        let existing = clip.masks().iter().rev().find(|m| m.source() == MaskSource::Magic).map(|m| m.id);
        if let (Some(id), false) = (existing, new_mask) {
            return self.add_points(session, &clip, id, at, clicks);
        }
        let points: Vec<MagicPoint> = clicks
            .iter()
            .map(|(position, subtract)| MagicPoint { position: *position, subtract: *subtract, source_time: at })
            .collect();
        let id = self.ids.next_id();
        add_magic_mask_with(session, &clip, id, points);
        // The key follows the points, so it is read back from the mask just stored.
        let key = clip_key(session, &clip, id)?;
        let to = clip.source.end();
        self.start(session, &clip, key, at, to, clicks.to_vec(), Vec::new())
    }

    /// Adds clicks to Magic mask `id` (one undo step) and tracks it again from the pick's frame: the points of every
    /// frame condition the model there, so a correction on a later frame re-propagates from that frame on.
    fn add_points(
        &mut self,
        session: &mut EditorSession,
        clip: &sq_core_model::Clip,
        id: Id,
        at: Time,
        clicks: &[(Vec2, bool)],
    ) -> Option<String> {
        let mut edited = clip.clone();
        let anchor = edited.mask(id)?.magic.as_ref().and_then(|m| m.anchor_time());
        let mut changed = false;
        for (position, subtract) in clicks {
            changed |= edited.magic_click(Some(id), *position, *subtract, at, &mut *self.ids).is_some();
        }
        if !changed {
            return Some(format!(
                "Click an object first; Remove (or {}-click) takes areas out of a pick.",
                sq_os::Platform::current().option_key_name()
            ));
        }
        let name = if clicks.iter().all(|c| c.1) {
            "Remove from Magic Mask"
        } else if anchor.is_none() || anchor == Some(at) {
            "Magic Mask Pick"
        } else {
            "Add to Magic Mask"
        };
        session.replace_displayed_clip(edited, name, false);
        // The newest click wins: an older run of the same mask is dropped.
        if let Some(job) = self.job.take() {
            job.stop();
        }
        let shown = find_clip(&session.display_timeline()?, clip.id)?;
        let magic = shown.mask(id)?.magic.clone()?;
        let (first, later) = split_points(&magic.points);
        let from = magic.anchor_time()?;
        let key = magic.cache_key(shown.media);
        self.start(session, &shown, key, from, shown.source.end(), first, later)
    }

    fn step(&mut self, session: &mut EditorSession, mask: Id, forward: bool) -> Option<String> {
        let (clip, frame_duration) = selected_clip(session)?;
        let magic = clip.masks().iter().find(|m| m.id == mask)?.magic.clone()?;
        let anchor = magic.anchor_time()?;
        let key = magic.cache_key(clip.media);
        let (clicks, later) = split_points(&magic.points);
        let here = clip.source_time(session.playhead(), frame_duration);
        let to = if forward { here + frame_duration } else { (here - frame_duration).max(Time::ZERO) };
        self.start(session, &clip, key, anchor, to, clicks, later)
    }

    #[allow(clippy::too_many_arguments)] // shortcut: one call site per request kind; a plan struct once a third arrives
    fn start(
        &mut self,
        session: &EditorSession,
        clip: &sq_core_model::Clip,
        key: String,
        from: Time,
        to: Time,
        clicks: Vec<(Vec2, bool)>,
        corrections: Vec<Correction>,
    ) -> Option<String> {
        if self.is_running() {
            return Some("Mask tracking is already running.".to_string());
        }
        let Some(media) = session.project().media(clip.media) else {
            return Some("The clip's media is not in the project.".to_string());
        };
        let frames = match self.sources.frames(Path::new(&media.path), from, to) {
            Ok(f) => f,
            Err(why) => return Some(format!("Mask tracking failed: {why}")),
        };
        self.job = Some(MagicTrackJob::spawn_with(
            frames,
            self.sources.tracker(),
            Arc::clone(&self.store),
            key,
            clicks,
            corrections,
            Arc::clone(&self.wake),
        ));
        Some("Tracking mask...".to_string())
    }
}

/// The first selected clip with the timeline's frame duration.
fn selected_clip(session: &EditorSession) -> Option<(sq_core_model::Clip, Time)> {
    let timeline = session.display_timeline()?;
    let id = session.selection().iter().next().copied()?;
    Some((find_clip(&timeline, id)?, timeline.frame_duration()))
}

fn find_clip(timeline: &sq_core_model::Timeline, id: Id) -> Option<sq_core_model::Clip> {
    timeline.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == id).cloned()
}

fn clip_key(session: &EditorSession, clip: &sq_core_model::Clip, mask: Id) -> Option<String> {
    let shown = find_clip(&session.display_timeline()?, clip.id)?;
    let magic = shown.masks().iter().find(|m| m.id == mask)?.magic.clone()?;
    Some(magic.cache_key(clip.media))
}

#[cfg(test)]
mod tests;
