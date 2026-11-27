//! Magic Mask tracking as a background job: a model follows the picked object frame by frame, every matte goes into the
//! [`FrameMatteStore`], progress and the end come back as messages the UI thread polls (Swift `MacMagicMasks+Track`).
//! The model and the frame reader sit behind two small traits, so the loop is tested without a model file.

use super::pacing::yield_to_playback;
use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::edge_tamonnx::{EdgeTAMOnnxLocation, EdgeTAMOnnxModel, EdgeTAMOnnxSession, SubjectFrame};
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_analysis::subject_matte_refiner::SubjectMatteEdger;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_masks::subject_track_rules::SubjectTrackRules;
use sq_core_model::{Clip, ClipMask, MagicPoint};
use sq_core_time::{Id, Time, Vec2};
use sq_editor_session::EditorSession;
use sq_playback::engine::activity::PlayActivity;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};

/// The frames of one run, in tracking order (the pick frame first).
pub trait TrackFrames: Send {
    /// How many frames the run covers.
    fn count(&self) -> usize;
    /// Source seconds and picture of frame `i`; `None` = unreadable (the run stops there).
    fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)>;
}

/// The model side of a run.
pub trait Tracker: Send {
    /// Conditions on the clicks `(frame fraction, subtract)` of the first frame and returns its matte.
    fn start(&mut self, frame: &SubjectFrame, points: &[(Vec2, bool)]) -> Result<SubjectMatte, String>;
    /// The matte of the next frame; `None` = the object is gone.
    fn next(&mut self, frame: &SubjectFrame) -> Result<Option<SubjectMatte>, String>;
}

/// How a run ended.
#[derive(Clone, Debug, PartialEq)]
pub struct TrackOutcome {
    /// Mattes stored, the pick frame included.
    pub frames: usize,
    /// Canceled by the user.
    pub stopped: bool,
    /// The model or the reader failed.
    pub error: Option<String>,
}

impl TrackOutcome {
    /// The status line the user reads.
    pub fn status(&self) -> String {
        if let Some(why) = &self.error {
            format!("Mask tracking failed: {why}")
        } else if self.stopped {
            if self.frames > 0 {
                format!("Mask tracking stopped; kept {} frames.", self.frames)
            } else {
                "Mask tracking stopped.".to_string()
            }
        } else if self.frames > 1 {
            format!("Tracked the mask over {} frames.", self.frames)
        } else {
            "The mask could not be tracked from here.".to_string()
        }
    }
}

/// A correction made on a later frame: the clicks `(frame fraction, subtract)` of that frame, in source seconds.
#[derive(Clone, Debug, PartialEq)]
pub struct Correction {
    /// Source seconds of the frame the clicks were made on.
    pub at: f64,
    /// The clicks of that frame.
    pub points: Vec<(Vec2, bool)>,
}

/// Splits the points of a pick into the clicks of the pick's own frame and the corrections of later frames
/// (Swift `SubjectTrackLeg`: every frame applies the points made on it).
pub fn split_points(points: &[MagicPoint]) -> (Vec<(Vec2, bool)>, Vec<Correction>) {
    let secs = |t: Time| t.value() as f64 / t.timescale().max(1) as f64;
    let Some(anchor) = points.first().map(|p| p.source_time) else { return (Vec::new(), Vec::new()) };
    let mut first = Vec::new();
    let mut later: Vec<Correction> = Vec::new();
    for p in points {
        if p.source_time == anchor {
            first.push((p.position, p.subtract));
        } else if let Some(c) = later.iter_mut().find(|c| (c.at - secs(p.source_time)).abs() < 1e-9) {
            c.points.push((p.position, p.subtract));
        } else {
            later.push(Correction { at: secs(p.source_time), points: vec![(p.position, p.subtract)] });
        }
    }
    (first, later)
}

/// Runs the loop on the calling thread. `progress` gets 0...1 after each stored frame.
pub fn run_track(
    frames: &mut dyn TrackFrames,
    tracker: &mut dyn Tracker,
    store: &FrameMatteStore,
    key: &str,
    points: &[(Vec2, bool)],
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> TrackOutcome {
    run_track_with(frames, tracker, store, key, points, &[], cancel, progress)
}

/// [`run_track`] with corrections: on a frame that has one the model is conditioned again on its clicks, so the object
/// the user fixed there is what the following frames follow.
#[allow(clippy::too_many_arguments)]
pub fn run_track_with(
    frames: &mut dyn TrackFrames,
    tracker: &mut dyn Tracker,
    store: &FrameMatteStore,
    key: &str,
    points: &[(Vec2, bool)],
    corrections: &[Correction],
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> TrackOutcome {
    run_track_paced(
        frames,
        tracker,
        store,
        key,
        points,
        corrections,
        cancel,
        progress,
        &PlayActivity::shared(),
        &mut |_| {},
    )
}

/// [`run_track_with`] against a given playback counter. The frames on the monitor come first: while an engine plays or scrubs
/// the run stands still between frames (a cancel still ends it at once) and goes on when the picture rests. Measured
/// 2026-11-25 on the real project: a CPU run beside playback cost 1-5 points of shown frames and ui frames over 25 ms went
/// from 1 to 40-56, with 8 or 16 threads alike, so a thread cap alone does not protect playback. A run while not playing
/// is as fast as before.
#[allow(clippy::too_many_arguments)]
pub fn run_track_paced(
    frames: &mut dyn TrackFrames,
    tracker: &mut dyn Tracker,
    store: &FrameMatteStore,
    key: &str,
    points: &[(Vec2, bool)],
    corrections: &[Correction],
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
    playback: &PlayActivity,
    hold: &mut dyn FnMut(bool),
) -> TrackOutcome {
    let total = frames.count();
    let mut out = TrackOutcome { frames: 0, stopped: false, error: None };
    let mut previous: Option<f64> = None;
    for i in 0..total {
        yield_to_playback(playback, cancel, hold);
        if cancel.is_cancelled() {
            out.stopped = true;
            break;
        }
        let Some((pts, frame)) = frames.frame(i) else {
            out.error = Some("a frame could not be read".to_string());
            break;
        };
        // A correction belongs to the frame nearest to it (within half the frame gap).
        let half = previous.map_or(1.0 / 60.0, |p| (pts - p).abs() / 2.0).max(1e-6);
        let correction = corrections.iter().find(|c| (c.at - pts).abs() < half);
        previous = Some(pts);
        let matte = match (i, correction) {
            (0, _) => tracker.start(&frame, points).map(Some),
            (_, Some(c)) => tracker.start(&frame, &c.points).map(Some),
            _ => tracker.next(&frame),
        };
        match matte {
            Ok(Some(m)) => {
                store.put(key, pts, m);
                out.frames += 1;
                progress((i + 1) as f64 / total as f64);
            }
            Ok(None) => break,
            Err(why) => {
                out.error = Some(why);
                break;
            }
        }
    }
    out
}

/// Runs on a job's thread after each message, so the window draws a frame and polls.
pub type WakeFn = Arc<dyn Fn() + Send + Sync>;

/// What the UI thread hears from a running job.
#[derive(Clone, Debug, PartialEq)]
pub enum TrackMessage {
    /// 0...1.
    Progress(f64),
    /// The run stands still because playback or an export runs (sent after a wait of 300 ms).
    Paused,
    /// Playback rests; the run goes on.
    Resumed,
    /// The last message.
    Done(TrackOutcome),
}

/// A run on its own thread.
pub struct MagicTrackJob {
    inbox: Receiver<TrackMessage>,
    cancel: CancelToken,
    finished: bool,
}

impl MagicTrackJob {
    /// Starts a run. `make_tracker` runs on the job's thread (loading a model takes seconds).
    pub fn spawn(
        frames: Box<dyn TrackFrames>,
        make_tracker: Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send>,
        store: Arc<FrameMatteStore>,
        key: String,
        points: Vec<(Vec2, bool)>,
        wake: WakeFn,
    ) -> MagicTrackJob {
        Self::spawn_with(frames, make_tracker, store, key, points, Vec::new(), wake)
    }

    /// [`MagicTrackJob::spawn`] with the corrections of later frames.
    pub fn spawn_with(
        mut frames: Box<dyn TrackFrames>,
        make_tracker: Box<dyn FnOnce() -> Result<Box<dyn Tracker>, String> + Send>,
        store: Arc<FrameMatteStore>,
        key: String,
        points: Vec<(Vec2, bool)>,
        corrections: Vec<Correction>,
        wake: WakeFn,
    ) -> MagicTrackJob {
        let (tx, inbox) = channel();
        let cancel = CancelToken::new();
        let token = cancel.clone();
        std::thread::spawn(move || {
            // Nobody waits on a track run: it yields to playback and the UI (the runtime's pool inherits this).
            sq_os::thread::set_current_thread_role(sq_os::thread::Role::Background);
            let outcome = match make_tracker() {
                Ok(mut tracker) => {
                    let (tx, wake) = (tx.clone(), Arc::clone(&wake));
                    let hold_tx = tx.clone();
                    let hold_wake = Arc::clone(&wake);
                    let mut hold = move |held: bool| {
                        let _ = hold_tx.send(if held { TrackMessage::Paused } else { TrackMessage::Resumed });
                        hold_wake();
                    };
                    run_track_paced(
                        &mut *frames,
                        &mut *tracker,
                        &store,
                        &key,
                        &points,
                        &corrections,
                        &token,
                        &mut |p| {
                            // The receiver is gone when the app quits; nothing is left to tell.
                            let _ = tx.send(TrackMessage::Progress(p));
                            wake();
                        },
                        &PlayActivity::shared(),
                        &mut hold,
                    )
                }
                Err(why) => TrackOutcome { frames: 0, stopped: false, error: Some(why) },
            };
            let _ = tx.send(TrackMessage::Done(outcome));
            wake();
        });
        MagicTrackJob { inbox, cancel, finished: false }
    }

    /// Asks the run to stop; frames so far are kept.
    pub fn stop(&self) {
        self.cancel.cancel();
    }

    /// True once `Done` was read.
    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// Everything that arrived since the last call.
    pub fn poll(&mut self) -> Vec<TrackMessage> {
        let all: Vec<TrackMessage> = self.inbox.try_iter().collect();
        self.finished |= all.iter().any(|m| matches!(m, TrackMessage::Done(_)));
        all
    }
}

/// The folder with the five EdgeTAM parts: the usual places, then `<support>/SubjectMask`. The error is the status line
/// shown when none is complete.
pub fn model_folder(support: &Path, environment: &HashMap<String, String>) -> Result<PathBuf, String> {
    if let Some(found) = EdgeTAMOnnxLocation::find(environment) {
        return Ok(found);
    }
    let own = support.join("SubjectMask");
    if EdgeTAMOnnxLocation::complete(&own) {
        return Ok(own);
    }
    Err(format!("Magic Mask needs the EdgeTAM model files in {}.", own.display()))
}

/// The EdgeTAM model behind [`Tracker`].
pub struct EdgeTamTracker(EdgeTAMOnnxSession);

impl EdgeTamTracker {
    /// Loads the model from `folder` (a few seconds: call it on the job's thread).
    pub fn load(folder: &Path) -> Result<EdgeTamTracker, String> {
        // A long job: cap the runtime's pool so decode, render and the UI keep cores.
        let threads = i32::try_from(sq_os::thread::background_threads()).unwrap_or(0);
        let model = EdgeTAMOnnxModel::new_with_threads(folder, true, None, threads).map_err(|e| e.to_string())?;
        Ok(EdgeTamTracker(Arc::new(model).make_session()))
    }

    /// A new session over a model that is loaded already (Anonymize follows several people and directions with one load).
    pub fn from_model(model: &Arc<EdgeTAMOnnxModel>) -> EdgeTamTracker {
        EdgeTamTracker(model.make_session())
    }

    fn matte(frame: &SubjectFrame, logits: &[f32]) -> SubjectMatte {
        SubjectTrackRules::matte(logits, SubjectTrackRules::LOGIT_SIZE, frame.width, frame.height)
    }
}

impl Tracker for EdgeTamTracker {
    fn start(&mut self, frame: &SubjectFrame, points: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
        let answer = self.0.pick(frame, points).map_err(|e| e.to_string())?;
        Ok(Self::matte(frame, &answer.logits))
    }

    fn next(&mut self, frame: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
        let answer = self.0.track(frame).map_err(|e| e.to_string())?;
        if answer.score <= 0.0 {
            return Ok(None);
        }
        self.0.commit().map_err(|e| e.to_string())?;
        Ok(Some(Self::matte(frame, &answer.logits)))
    }
}

/// A tracker whose mattes get their edge from the frame they were made on (Swift `SubjectMatteEdger` in the leg): the
/// Subject Mask Edges choice, Quality or Speed, decides the step.
pub struct EdgedTracker<T: Tracker> {
    inner: T,
    edger: SubjectMatteEdger,
}

impl<T: Tracker> EdgedTracker<T> {
    /// `inner` with the edge step of `edger`.
    pub fn new(inner: T, edger: SubjectMatteEdger) -> EdgedTracker<T> {
        EdgedTracker { inner, edger }
    }
}

impl<T: Tracker> Tracker for EdgedTracker<T> {
    fn start(&mut self, frame: &SubjectFrame, points: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
        self.inner.start(frame, points).map(|m| self.edger.edged(m, frame))
    }

    fn next(&mut self, frame: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
        Ok(self.inner.next(frame)?.map(|m| self.edger.edged(m, frame)))
    }
}

/// Puts a Magic mask with the first click on the clip, one undo step ("Add Magic Mask"). Returns its id.
pub fn add_magic_mask(session: &mut EditorSession, clip: &Clip, id: Id, point: Vec2, source_time: Time) -> Id {
    add_magic_mask_with(session, clip, id, vec![MagicPoint { position: point, subtract: false, source_time }])
}

/// Puts a Magic mask with all `points` of a confirmed prompt on the clip, one undo step.
pub fn add_magic_mask_with(session: &mut EditorSession, clip: &Clip, id: Id, points: Vec<MagicPoint>) -> Id {
    let mut c = clip.clone();
    let mask = ClipMask::make_magic(id, &c.next_mask_name(), points);
    let mut masks = c.masks().to_vec();
    masks.push(mask);
    c.set_masks(masks);
    session.replace_displayed_clip(c, "Add Magic Mask", false);
    id
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Frames(usize);
    impl TrackFrames for Frames {
        fn count(&self) -> usize {
            self.0
        }
        fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)> {
            (i < 100).then(|| (i as f64 / 24.0, SubjectFrame::new(1, 1, vec![0; 4])))
        }
    }

    /// Follows the object for `lasts` frames after the pick, then loses it.
    struct Follow {
        lasts: usize,
        seen: usize,
    }
    impl Tracker for Follow {
        fn start(&mut self, _: &SubjectFrame, points: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
            if points.is_empty() {
                return Err("no point".to_string());
            }
            Ok(SubjectMatte::new(1, 1, vec![1.0]))
        }
        fn next(&mut self, _: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
            self.seen += 1;
            Ok((self.seen <= self.lasts).then(|| SubjectMatte::new(1, 1, vec![1.0])))
        }
    }

    fn click() -> Vec<(Vec2, bool)> {
        vec![(Vec2::new(0.5, 0.5), false)]
    }

    #[test]
    fn an_edged_tracker_gives_every_matte_the_frames_edge() {
        struct Hard;
        impl Tracker for Hard {
            fn start(&mut self, _: &SubjectFrame, _: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
                Ok(SubjectMatte::new(64, 64, (0..64 * 64).map(|i| if i % 64 < 30 { 1.0 } else { 0.0 }).collect()))
            }
            fn next(&mut self, f: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
                self.start(f, &[]).map(Some)
            }
        }
        let mut rgba = vec![255_u8; 64 * 64 * 4];
        for (i, px) in rgba.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let v = (230 - 200 * ((i % 64).clamp(33, 41) - 33) / 8) as u8;
            px[..3].copy_from_slice(&[v, v.saturating_sub(20), v / 2 + 10]);
        }
        let frame = SubjectFrame::new(64, 64, rgba);
        let mut edged = EdgedTracker::new(
            Hard,
            SubjectMatteEdger::new(sq_analysis::subject_mask_quality::SubjectMaskQuality::Quality),
        );
        let hard = Hard.start(&frame, &[]).unwrap_or_else(|e| panic!("{e}"));
        let first = edged.start(&frame, &[]).unwrap_or_else(|e| panic!("{e}"));
        let next = edged.next(&frame).unwrap_or_else(|e| panic!("{e}")).unwrap_or_else(|| panic!("matte"));
        assert_ne!(first, hard, "the edge was refined");
        assert_eq!(first, next);
    }

    #[test]
    fn stores_every_followed_frame_and_stops_when_the_object_leaves() {
        let store = FrameMatteStore::new(None);
        let mut seen = Vec::new();
        let out = run_track(
            &mut Frames(10),
            &mut Follow { lasts: 3, seen: 0 },
            &store,
            "k",
            &click(),
            &CancelToken::new(),
            &mut |p| seen.push(p),
        );
        assert_eq!(out, TrackOutcome { frames: 4, stopped: false, error: None });
        assert_eq!(store.times("k").len(), 4);
        assert_eq!(seen.len(), 4);
        assert!((seen[3] - 0.4).abs() < 1e-9);
        assert_eq!(out.status(), "Tracked the mask over 4 frames.");
    }

    #[test]
    fn a_run_stands_still_while_playback_is_busy_and_goes_on_after() {
        use sq_playback::engine::activity::PlayMark;
        let playback = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&playback));
        mark.set(true);
        let (seen_tx, seen) = channel::<f64>();
        let (hold_tx, holds) = channel::<bool>();
        let p = Arc::clone(&playback);
        let done = std::thread::spawn(move || {
            let store = FrameMatteStore::new(None);
            let tell = |x: f64| {
                let _ = seen_tx.send(x);
            };
            let mut tell = tell;
            run_track_paced(
                &mut Frames(5),
                &mut Follow { lasts: 99, seen: 0 },
                &store,
                "k",
                &click(),
                &[],
                &CancelToken::new(),
                &mut tell,
                &p,
                &mut |held| {
                    let _ = hold_tx.send(held);
                },
            )
        });
        assert!(seen.recv_timeout(std::time::Duration::from_millis(500)).is_err(), "no frame is tracked while playing");
        assert_eq!(holds.try_recv(), Ok(true), "a wait over 300 ms is announced");
        mark.set(false);
        let out = done.join().unwrap_or_else(|_| panic!("join"));
        assert_eq!(out.frames, 5, "the run finishes once playback rests");
        assert_eq!(holds.try_recv(), Ok(false), "and the end of the wait too");
    }

    #[test]
    fn a_cancel_ends_a_run_that_waits_for_playback() {
        use sq_playback::engine::activity::PlayMark;
        let playback = Arc::new(PlayActivity::default());
        let mut mark = PlayMark::new(Arc::clone(&playback));
        mark.set(true);
        let cancel = CancelToken::new();
        let c = cancel.clone();
        let p = Arc::clone(&playback);
        let done = std::thread::spawn(move || {
            let store = FrameMatteStore::new(None);
            run_track_paced(
                &mut Frames(5),
                &mut Follow { lasts: 99, seen: 0 },
                &store,
                "k",
                &click(),
                &[],
                &c,
                &mut |_| {},
                &p,
                &mut |_| {},
            )
        });
        cancel.cancel();
        let out = done.join().unwrap_or_else(|_| panic!("join"));
        assert!(out.stopped && out.frames == 0);
    }

    #[test]
    fn a_canceled_run_keeps_what_it_has() {
        let store = FrameMatteStore::new(None);
        let cancel = CancelToken::new();
        let out = {
            let c = cancel.clone();
            run_track(&mut Frames(10), &mut Follow { lasts: 99, seen: 0 }, &store, "k", &click(), &cancel, &mut |p| {
                if p >= 0.3 {
                    c.cancel();
                }
            })
        };
        assert!(out.stopped && out.frames == 3, "{out:?}");
        assert_eq!(out.status(), "Mask tracking stopped; kept 3 frames.");
    }

    #[test]
    fn a_model_error_ends_the_run_with_its_text() {
        let store = FrameMatteStore::new(None);
        let out = run_track(
            &mut Frames(5),
            &mut Follow { lasts: 9, seen: 0 },
            &store,
            "k",
            &[],
            &CancelToken::new(),
            &mut |_| {},
        );
        assert_eq!(out.error.as_deref(), Some("no point"));
        assert_eq!(out.status(), "Mask tracking failed: no point");
    }

    #[test]
    fn the_job_reports_progress_then_done() {
        let store = Arc::new(FrameMatteStore::new(None));
        let mut job = MagicTrackJob::spawn(
            Box::new(Frames(3)),
            Box::new(|| Ok(Box::new(Follow { lasts: 9, seen: 0 }) as Box<dyn Tracker>)),
            Arc::clone(&store),
            "job".to_string(),
            click(),
            Arc::new(|| {}),
        );
        let mut all = Vec::new();
        for _ in 0..500 {
            all.extend(job.poll());
            if job.is_finished() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(matches!(all.last(), Some(TrackMessage::Done(o)) if o.frames == 3), "{all:?}");
        assert_eq!(store.times("job").len(), 3);
    }

    #[test]
    fn a_missing_model_says_where_it_looks() {
        let dir = std::env::temp_dir().join("sq-no-model-here");
        let why = model_folder(&dir, &HashMap::new()).expect_err("no model");
        assert!(
            why.starts_with("Magic Mask needs the EdgeTAM model files in ") && why.contains("SubjectMask"),
            "{why}"
        );
    }

    #[test]
    fn a_correction_conditions_the_model_again_on_its_frame() {
        struct Log(Vec<String>);
        impl Tracker for Log {
            fn start(&mut self, _: &SubjectFrame, p: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
                self.0.push(format!("start{}", p.len()));
                Ok(SubjectMatte::new(1, 1, vec![1.0]))
            }
            fn next(&mut self, _: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
                self.0.push("next".to_string());
                Ok(Some(SubjectMatte::new(1, 1, vec![1.0])))
            }
        }
        let store = FrameMatteStore::new(None);
        let mut log = Log(Vec::new());
        let fix =
            Correction { at: 2.0 / 24.0, points: vec![(Vec2::new(0.1, 0.1), true), (Vec2::new(0.5, 0.5), false)] };
        let out =
            run_track_with(&mut Frames(5), &mut log, &store, "k", &click(), &[fix], &CancelToken::new(), &mut |_| {});
        assert_eq!(out.frames, 5);
        assert_eq!(log.0, ["start1", "next", "start2", "next", "next"]);
    }

    #[test]
    fn points_split_into_the_pick_and_the_corrections_of_other_frames() {
        let pt = |x: f64, s: bool, t: Time| MagicPoint { position: Vec2::new(x, 0.5), subtract: s, source_time: t };
        let (first, later) = split_points(&[
            pt(0.1, false, Time::ZERO),
            pt(0.2, true, Time::ZERO),
            pt(0.3, false, Time::new(1, 30)),
            pt(0.4, true, Time::new(1, 30)),
            pt(0.5, false, Time::new(2, 30)),
        ]);
        assert_eq!(first.len(), 2);
        assert_eq!(later.len(), 2);
        assert_eq!(later[0].points.len(), 2);
        assert!((later[0].at - 1.0 / 30.0).abs() < 1e-9);
    }

    /// Two touching disks (red moving right, blue still) as 256 x 256 frames, `n` of them at 24 fps.
    struct Disks(usize);
    impl Disks {
        const SIZE: usize = 256;
        fn center(i: usize) -> (f64, f64) {
            (80.0 + 2.0 * i as f64, 128.0)
        }
        fn truth(i: usize) -> Vec<bool> {
            let (cx, cy) = Self::center(i);
            (0..Self::SIZE * Self::SIZE)
                .map(|k| {
                    let (x, y) = ((k % Self::SIZE) as f64 + 0.5, (k / Self::SIZE) as f64 + 0.5);
                    (x - cx).powi(2) + (y - cy).powi(2) <= 50.0 * 50.0
                })
                .collect()
        }
    }
    impl TrackFrames for Disks {
        fn count(&self) -> usize {
            self.0
        }
        fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)> {
            let (cx, cy) = Self::center(i);
            let mut rgba = vec![0u8; Self::SIZE * Self::SIZE * 4];
            for k in 0..Self::SIZE * Self::SIZE {
                let (x, y) = ((k % Self::SIZE) as f64 + 0.5, (k / Self::SIZE) as f64 + 0.5);
                let px: [u8; 4] = if (x - cx).powi(2) + (y - cy).powi(2) <= 2500.0 {
                    [220, 40, 40, 255]
                } else if (x - 180.0).powi(2) + (y - 128.0).powi(2) <= 2500.0 {
                    [40, 60, 220, 255]
                } else {
                    [90 + (x as u8 / 8), 150, 90 + (y as u8 / 8), 255]
                };
                rgba[k * 4..k * 4 + 4].copy_from_slice(&px);
            }
            Some((i as f64 / 24.0, SubjectFrame::new(Self::SIZE, Self::SIZE, rgba)))
        }
    }

    /// Keeps every matte the wrapped tracker answers.
    struct Recording<'a>(&'a mut EdgeTamTracker, Vec<SubjectMatte>);
    impl Tracker for Recording<'_> {
        fn start(&mut self, f: &SubjectFrame, p: &[(Vec2, bool)]) -> Result<SubjectMatte, String> {
            let m = self.0.start(f, p)?;
            self.1.push(m.clone());
            Ok(m)
        }
        fn next(&mut self, f: &SubjectFrame) -> Result<Option<SubjectMatte>, String> {
            let m = self.0.next(f)?;
            self.1.extend(m.clone());
            Ok(m)
        }
    }

    fn iou(matte: &SubjectMatte, truth: &[bool]) -> f64 {
        let guess: Vec<bool> = matte.values.iter().map(|v| *v > 0.5).collect();
        sq_analysis::mask_metrics::MaskMetrics::jaccard(&guess, truth)
    }

    /// Real EdgeTAM (point prompts, `SQ_SUBJECT_MASK_MODELS`): a positive point picks a disk, a negative point on the
    /// other disk keeps it out, and a correction on a later frame re-conditions the track. Skipped without the models or without an ONNX Runtime library on
    /// the loader path.
    #[test]
    fn real_model_point_corrections_keep_the_iou_against_the_disk() {
        let env: HashMap<String, String> = std::env::vars().collect();
        let Ok(folder) = model_folder(&std::env::temp_dir(), &env) else {
            sq_os::errln!("skipped: no EdgeTAM models");
            return;
        };
        let mut tracker = match EdgeTamTracker::load(&folder) {
            Ok(t) => t,
            // The models are there but this machine has no ONNX Runtime library on its loader path (put the folder of
            // `libonnxruntime.so` on LD_LIBRARY_PATH to run it): skipped like the missing models, not a failure.
            Err(e) if e.contains("cannot load the ONNX Runtime library") => {
                sq_os::errln!("skipped: {e}");
                return;
            }
            Err(e) => panic!("model: {e}"),
        };
        let store = FrameMatteStore::new(None);
        let (a, b) = (Vec2::new(80.0 / 256.0, 0.5), Vec2::new(190.0 / 256.0, 0.5));
        let fix = Correction { at: 6.0 / 24.0, points: vec![(Vec2::new(86.0 / 256.0, 0.5), false), (b, true)] };
        let mut rec = Recording(&mut tracker, Vec::new());
        let out = run_track_with(
            &mut Disks(10),
            &mut rec,
            &store,
            "iou",
            &[(a, false), (b, true)],
            &[fix],
            &CancelToken::new(),
            &mut |_| {},
        );
        assert_eq!(out.frames, 10, "{out:?}");
        let ious: Vec<f64> = rec.1.iter().enumerate().map(|(i, m)| iou(m, &Disks::truth(i))).collect();
        sq_os::errln!("IoU per frame {ious:?}");
        assert!(ious.iter().all(|v| *v > 0.7), "{ious:?}");
    }
}
