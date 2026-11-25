// Swift: MacShell/AnonymizeFlow.swift (`AnonymizeFlow`, `AnonymizeRun`), SharedUIController+Anonymize.swift
//! The Anonymize flow on the shell's analysis services: Clip > Video Options > Anonymize finds the people of the selected clip
//! on a worker, the shell shows the sheet, the chosen people are followed on a second worker and the result is written as
//! one undo step. Running the command again while it works cancels it; nothing is written then. A run stores its mattes under
//! staged keys and they are taken over only once the masks are written, so a canceled, failed or refused run never touches
//! a cover that is already on the clip. Several selected clips: the picked people are for the clip under the playhead, the
//! others get everyone found in them (`anonymizeQueued`).

use super::anonymizer::{self, AnonymizeError, AnonymizeSources, Outcome};
use super::ffmpeg_frames::{FfmpegFrameReader, track_indices};
use super::magic_job::{EdgeTamTracker, TrackFrames, Tracker, WakeFn, model_folder};
use sq_analysis::analysis_turn::CancelToken;
use sq_analysis::anonymize_search::AnonymizeSighting;
use sq_analysis::edge_tamonnx::{EdgeTAMOnnxModel, SubjectFrame};
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_analysis::person_detector::{OnnxPeopleDetector, PersonDetecting, default_folder};
use sq_core_masks::anonymize::{AnonymizeBox, AnonymizeFace};
use sq_core_model::{FieldOrder, MagicSelection, PixelAspect};
use sq_core_time::{Id, Time};
use sq_draw_shell::AnonymizeEvent;
use sq_editor_session::{AnonymizeChoice, AnonymizeRequest, EditorSession};
use sq_uikit::localization::SQL10n;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock};

/// Where a launcher's wake-up goes once the app has set it.
pub type WakeSlot = Arc<Mutex<Option<WakeFn>>>;

/// The sources of one request (the file's frames and the models).
pub type MakeSources = Box<dyn Fn(&AnonymizeRequest) -> Result<Arc<dyn AnonymizeSources>, String>>;

enum Message {
    Found(Result<Option<Vec<AnonymizeSighting>>, AnonymizeError>),
    Progress(f64),
    /// The run waits for playback or an export (`true`, after 300 ms) or goes on.
    Hold(bool),
    Followed(Result<Outcome, AnonymizeError>),
}

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Idle,
    Finding,
    Asking,
    Following,
}

/// The rest of a multi-clip run.
struct Queue {
    choice: AnonymizeChoice,
    rest: Vec<Id>,
    restore: BTreeSet<Id>,
    done: usize,
}

/// What the run in progress needs.
struct Run {
    request: AnonymizeRequest,
    sources: Arc<dyn AnonymizeSources>,
    cancel: CancelToken,
    found: Vec<AnonymizeSighting>,
    others: Vec<Id>,
    keep: BTreeSet<Id>,
    queue: Option<Queue>,
    picks: Vec<MagicSelection>,
    choice: Option<AnonymizeChoice>,
    subject_width: f64,
    what: String,
}

/// The Anonymize flow.
pub struct AnonymizeRunner {
    store: Arc<FrameMatteStore>,
    make: MakeSources,
    phase: Phase,
    run: Option<Run>,
    events: Vec<AnonymizeEvent>,
    tx: Sender<Message>,
    inbox: Receiver<Message>,
    wake: WakeSlot,
    /// 0...1 of the last progress message, for the pause line.
    progress: f64,
}

fn stage_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    format!("{nanos:x}{:x}", COUNTER.fetch_add(1, Ordering::SeqCst))
}

fn people_text(n: usize) -> String {
    if n == 1 { "1 person".to_string() } else { format!("{n} people") }
}

impl AnonymizeRunner {
    /// A flow writing mattes into `store` (the one the renderer reads), with sources made per request.
    pub fn new(store: Arc<FrameMatteStore>, make: MakeSources) -> AnonymizeRunner {
        let (tx, inbox) = channel();
        AnonymizeRunner {
            store,
            make,
            phase: Phase::Idle,
            run: None,
            events: Vec::new(),
            tx,
            inbox,
            wake: WakeSlot::default(),
            progress: 0.0,
        }
    }

    /// The slot the app's wake-up goes into (set by the services).
    pub fn wake_slot(&self) -> WakeSlot {
        Arc::clone(&self.wake)
    }

    /// A search or a run is going.
    pub fn is_running(&self) -> bool {
        matches!(self.phase, Phase::Finding | Phase::Following)
    }

    /// What the shell shows since the last call.
    pub fn take_events(&mut self) -> Vec<AnonymizeEvent> {
        std::mem::take(&mut self.events)
    }

    fn flash(&mut self, text: &str) {
        self.events.push(AnonymizeEvent::Flash(text.to_string()));
    }

    fn job(&mut self, line: Option<String>) {
        self.events.push(AnonymizeEvent::Job(line));
    }

    /// The command: starts a run, or cancels the running one.
    pub fn request(&mut self, session: &mut EditorSession) {
        if self.is_running() {
            if let Some(run) = &self.run {
                run.cancel.cancel();
            }
            return;
        }
        let Some(request) = session.anonymize_request() else {
            self.flash("Select a video clip from a file to anonymize.");
            return;
        };
        session.stop_playback();
        let others: Vec<Id> = session.reframe_targets().iter().map(|c| c.id).filter(|id| *id != request.clip).collect();
        let keep = session.selection().clone();
        self.start_find(request, others, keep, None);
    }

    fn start_find(&mut self, request: AnonymizeRequest, others: Vec<Id>, keep: BTreeSet<Id>, queue: Option<Queue>) {
        let sources = match (self.make)(&request) {
            Ok(s) => s,
            Err(why) => {
                self.phase = Phase::Idle;
                self.events.push(AnonymizeEvent::Warn(
                    "Anonymize could not read this frame".to_string(),
                    format!("The file of “{}” could not be read here ({why}).", request.clip_name),
                ));
                return;
            }
        };
        self.job(Some(format!("Anonymize: looking for people in “{}”…", request.clip_name)));
        let cancel = CancelToken::new();
        let (first, last, anchor) = (request.first, request.last, request.anchor);
        let (src, token, tx, wake) = (Arc::clone(&sources), cancel.clone(), self.tx.clone(), Arc::clone(&self.wake));
        std::thread::spawn(move || {
            sq_os::thread::set_current_thread_role(sq_os::thread::Role::Background);
            let (hold_tx, hold_wake) = (tx.clone(), Arc::clone(&wake));
            let mut hold = move |held: bool| {
                let _ = hold_tx.send(Message::Hold(held));
                wake_app(&hold_wake);
            };
            let found = anonymizer::find_everyone(&*src, first, last, anchor, &token, &mut |_| {}, &mut hold);
            let _ = tx.send(Message::Found(found));
            wake_app(&wake);
        });
        self.phase = Phase::Finding;
        self.run = Some(Run {
            request,
            sources,
            cancel,
            found: Vec::new(),
            others,
            keep,
            queue,
            picks: Vec::new(),
            choice: None,
            subject_width: 0.0,
            what: String::new(),
        });
    }

    /// The sheet's answer (`None` = canceled).
    pub fn answer(&mut self, choice: Option<AnonymizeChoice>) {
        if self.phase != Phase::Asking {
            return;
        }
        let (Some(choice), Some(mut run)) = (choice, self.run.take()) else {
            self.phase = Phase::Idle;
            self.run = None;
            return;
        };
        let chosen: Vec<AnonymizeSighting> = choice.people.iter().filter_map(|i| run.found.get(*i).copied()).collect();
        if !run.others.is_empty() {
            // Several clips: the picked people are for this clip; the others get everyone found in them.
            let rest = std::mem::take(&mut run.others);
            run.queue = Some(Queue { choice: choice.clone(), rest, restore: run.keep.clone(), done: 1 });
        }
        self.start_follow(run, chosen, choice);
    }

    fn start_follow(&mut self, mut run: Run, sightings: Vec<AnonymizeSighting>, choice: AnonymizeChoice) {
        let picks: Vec<MagicSelection> =
            sightings.iter().map(|s| anonymizer::selection(&s.person, s.pts, choice.target)).collect();
        // The widest covered subject in px of the clip's frame sets the block size / blur amount.
        let widest = sightings
            .iter()
            .map(|s| {
                let p = &s.person;
                if choice.target == sq_core_model::AnonymizeTarget::Face {
                    p.face.map_or(p.box_.width * 0.4, |f| f.box_.width)
                } else {
                    p.box_.width
                }
            })
            .fold(0.0_f64, f64::max);
        run.subject_width = if sightings.is_empty() { 0.2 } else { widest } * run.request.picture_width as f64;
        run.what = format!("Anonymize: following {} in “{}”…", people_text(sightings.len()), run.request.clip_name);
        self.job(Some(run.what.clone()));
        let (src, store, token, tx, wake) = (
            Arc::clone(&run.sources),
            Arc::clone(&self.store),
            run.cancel.clone(),
            self.tx.clone(),
            Arc::clone(&self.wake),
        );
        let (media, first, last, gap, stage) =
            (run.request.media, run.request.first, run.request.last, run.request.frame_gap, stage_id());
        let jobs = picks.clone();
        let progress_tx = tx.clone();
        let progress_wake = Arc::clone(&wake);
        std::thread::spawn(move || {
            sq_os::thread::set_current_thread_role(sq_os::thread::Role::Background);
            let (hold_tx, hold_wake) = (tx.clone(), Arc::clone(&wake));
            let mut hold = move |held: bool| {
                let _ = hold_tx.send(Message::Hold(held));
                wake_app(&hold_wake);
            };
            let done = anonymizer::run(
                &*src,
                &jobs,
                media,
                first,
                last,
                gap,
                &store,
                &stage,
                &token,
                &mut |p| {
                    let _ = progress_tx.send(Message::Progress(p));
                    wake_app(&progress_wake);
                },
                &mut hold,
            );
            let _ = tx.send(Message::Followed(done));
            wake_app(&wake);
        });
        self.progress = 0.0;
        run.picks = picks;
        run.choice = Some(choice);
        self.run = Some(run);
        self.phase = Phase::Following;
    }

    /// Reads the workers' messages and carries them out (runs on every pump of the app).
    pub fn pump(&mut self, session: &mut EditorSession) {
        while let Ok(message) = self.inbox.try_recv() {
            match message {
                Message::Found(r) => self.found(session, r),
                Message::Hold(held) => {
                    if let Some(run) = &self.run {
                        let line = if held {
                            super::pacing::paused_line(&run.what, self.progress * 100.0)
                        } else {
                            format!("{} {} %", run.what, (self.progress * 100.0).round() as i64)
                        };
                        self.job(Some(line));
                    }
                }
                Message::Progress(p) => {
                    self.progress = p;
                    if let Some(run) = &self.run {
                        let line = format!("{} {} %", run.what, (p * 100.0).round() as i64);
                        self.job(Some(line));
                    }
                }
                Message::Followed(r) => self.followed(session, r),
            }
        }
    }

    fn found(&mut self, session: &mut EditorSession, found: Result<Option<Vec<AnonymizeSighting>>, AnonymizeError>) {
        let Some(mut run) = self.run.take() else { return };
        self.job(None);
        let name = run.request.clip_name.clone();
        self.phase = Phase::Idle;
        let queued = run.queue.is_some();
        match found {
            Err(AnonymizeError::Canceled) => {
                if let Some(q) = &run.queue {
                    session.select(q.restore.clone(), BTreeSet::new());
                }
                self.flash("Anonymize canceled.");
            }
            Err(AnonymizeError::Failed(_)) | Ok(None) => {
                if queued {
                    self.next_clip(session, run.queue.take());
                } else {
                    self.events.push(AnonymizeEvent::Warn(
                        "Anonymize could not read this frame".to_string(),
                        format!("The file of “{name}” could not be read here."),
                    ));
                }
            }
            Ok(Some(people)) if people.is_empty() => {
                if queued {
                    self.next_clip(session, run.queue.take());
                } else {
                    self.events.push(AnonymizeEvent::Info(
                        "No person found in this clip".to_string(),
                        "No person showed up on the frames Anonymize looked at. Move the playhead to a frame that shows the person clearly, then run it again. You can also pick them by hand with the Mask tool (Magic) and limit a Mosaic to that mask.".to_string(),
                    ));
                }
            }
            Ok(Some(people)) => {
                if let Some(q) = run.queue.take() {
                    let choice = q.choice.clone();
                    run.queue = Some(q);
                    self.start_follow(run, people, choice);
                } else {
                    self.events.push(AnonymizeEvent::Ask {
                        clip_name: name,
                        people: people.iter().map(|s| s.person).collect(),
                    });
                    run.found = people;
                    self.run = Some(run);
                    self.phase = Phase::Asking;
                }
            }
        }
    }

    fn followed(&mut self, session: &mut EditorSession, result: Result<Outcome, AnonymizeError>) {
        let Some(mut run) = self.run.take() else { return };
        self.job(None);
        self.phase = Phase::Idle;
        let restore = run.queue.as_ref().map(|q| q.restore.clone());
        let out = match result {
            Err(AnonymizeError::Canceled) => {
                if let Some(r) = restore {
                    session.select(r, BTreeSet::new());
                }
                self.flash("Anonymize canceled. Nothing was changed.");
                return;
            }
            Err(AnonymizeError::Failed(why)) => {
                self.flash(&format!("Anonymize failed: {why}"));
                return;
            }
            Ok(out) => out,
        };
        if out.frames == 0 {
            anonymizer::discard(&out.staged, &self.store);
            self.flash("Anonymize found nothing to follow. Nothing was changed.");
            return;
        }
        let Some(choice) = run.choice.take() else { return };
        let applied = session.apply_anonymize(&run.picks, choice.target, choice.cover, run.subject_width, &run.request);
        if !applied.applied() {
            anonymizer::discard(&out.staged, &self.store);
            if applied == sq_editor_session::AnonymizeApplyResult::ClipRetimed {
                self.events
                    .push(AnonymizeEvent::Warn("Anonymize was not applied".to_string(), applied.message().to_string()));
            } else {
                self.flash(applied.message());
            }
            return;
        }
        // The masks are in the clip: now their mattes replace the staged ones.
        anonymizer::commit(&out.staged, &self.store);
        let lines = session.anonymize_check_lines(&out.checks, &run.request);
        if let Some(mut q) = run.queue.take() {
            q.done += 1;
            self.next_clip(session, Some(q));
        } else if lines.is_empty() {
            self.flash("Anonymize applied. Check the whole clip before you export.");
        } else {
            self.events.push(AnonymizeEvent::Checks(lines));
        }
    }

    /// The rest of a multi-clip run: each clip is selected in turn (the request is built from the selection), searched and
    /// covered with the same target and cover, everyone found. The selection is restored at the end.
    fn next_clip(&mut self, session: &mut EditorSession, queue: Option<Queue>) {
        let Some(mut q) = queue else { return };
        loop {
            if q.rest.is_empty() {
                session.select(q.restore.clone(), BTreeSet::new());
                self.flash(&SQL10n::plural(
                    q.done as i64,
                    "Anonymize applied to %@ clip. Check each clip before you export.",
                    "Anonymize applied to %@ clips. Check each clip before you export.",
                ));
                return;
            }
            let id = q.rest.remove(0);
            session.select(BTreeSet::from([id]), BTreeSet::new());
            if let Some(request) = session.anonymize_request() {
                let keep = q.restore.clone();
                self.start_find(request, Vec::new(), keep, Some(q));
                return;
            }
        }
    }
}

fn wake_app(wake: &WakeSlot) {
    let wake = wake.lock().ok().and_then(|w| w.clone());
    if let Some(wake) = wake {
        wake();
    }
}

/// Long side of the pictures the people are found and followed on (px; the tracker's model size).
const MAX_SIDE: usize = 1024;

/// FFmpeg frames turned upright and the ONNX models: the Windows and Linux counterpart of the Mac's Vision path (the Mac keeps
/// Vision for the people finder in Swift; this app's Mac build uses these portable models too).
pub struct SystemAnonymizeSources {
    path: PathBuf,
    support: PathBuf,
    reader: Mutex<FfmpegFrameReader>,
    rotation: i64,
    /// The media item's pixel aspect and Deinterlace order: every frame of a run is read shaped by them.
    aspect: PixelAspect,
    deinterlace: Option<FieldOrder>,
    people: OnceLock<Result<OnnxPeopleDetector, String>>,
    model: OnceLock<Result<Arc<EdgeTAMOnnxModel>, String>>,
}

impl SystemAnonymizeSources {
    /// The sources of the file at `path`; `support` holds the EdgeTAM model (`SubjectMask`).
    pub fn open(
        path: &Path,
        support: &Path,
        aspect: PixelAspect,
        deinterlace: Option<FieldOrder>,
    ) -> Result<SystemAnonymizeSources, String> {
        let reader = FfmpegFrameReader::open(path)?.shaped(aspect, deinterlace);
        let rotation = reader.rotation();
        Ok(SystemAnonymizeSources {
            path: path.to_path_buf(),
            support: support.to_path_buf(),
            reader: Mutex::new(reader),
            rotation,
            aspect,
            deinterlace,
            people: OnceLock::new(),
            model: OnceLock::new(),
        })
    }

    fn people(&self) -> Result<&OnnxPeopleDetector, String> {
        self.people
            .get_or_init(|| OnnxPeopleDetector::open(&default_folder(|k| std::env::var(k).ok())))
            .as_ref()
            .map_err(Clone::clone)
    }
}

/// The frames of one run, turned upright.
struct UprightFrames {
    reader: FfmpegFrameReader,
    rotation: i64,
    indices: Vec<usize>,
}

impl TrackFrames for UprightFrames {
    fn count(&self) -> usize {
        self.indices.len()
    }

    fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)> {
        let pic = self.reader.picture(*self.indices.get(i)?, MAX_SIDE)?;
        let seconds = pic.pts.value() as f64 / pic.pts.timescale() as f64;
        Some((seconds, SubjectFrame::new(pic.width, pic.height, pic.rgba).upright(self.rotation)))
    }
}

fn instant(seconds: f64) -> Time {
    Time::new((seconds * 90_000.0).round() as i64, 90_000)
}

impl AnonymizeSources for SystemAnonymizeSources {
    fn shown(&self, seconds: f64) -> Result<Option<(f64, SubjectFrame)>, String> {
        let reader = self.reader.lock().map_err(|_| "the frame reader failed".to_string())?;
        let Some(index) = reader.index_at(instant(seconds)) else { return Ok(None) };
        Ok(reader.picture(index, MAX_SIDE).map(|p| {
            let at = p.pts.value() as f64 / p.pts.timescale() as f64;
            (at, SubjectFrame::new(p.width, p.height, p.rgba).upright(self.rotation))
        }))
    }

    fn frames(&self, from: f64, to: f64) -> Result<Box<dyn TrackFrames>, String> {
        let reader = FfmpegFrameReader::open(&self.path)?.shaped(self.aspect, self.deinterlace);
        let start = reader.index_at(instant(from)).ok_or("The pick frame is outside the file.")?;
        let stop = reader.index_at(instant(to)).unwrap_or(if to < from { 0 } else { usize::MAX });
        let indices = track_indices(start, stop, reader.count());
        let rotation = reader.rotation();
        Ok(Box::new(UprightFrames { reader, rotation, indices }))
    }

    fn tracker(&self) -> Result<Box<dyn Tracker>, String> {
        let model = self
            .model
            .get_or_init(|| {
                let environment: HashMap<String, String> = std::env::vars().collect();
                let folder = model_folder(&self.support, &environment)?;
                EdgeTAMOnnxModel::new_with_threads(&folder, true, None, i32::try_from(sq_os::thread::background_threads()).unwrap_or(0)).map(Arc::new).map_err(|e| e.to_string())
            })
            .as_ref()
            .map_err(Clone::clone)?;
        Ok(Box::new(EdgeTamTracker::from_model(model)))
    }

    fn detect(&self, frame: &SubjectFrame, bodies: bool) -> Result<(Vec<AnonymizeBox>, Vec<AnonymizeFace>), String> {
        self.people()?.detect(frame, bodies)
    }
}

/// The system's sources for a request, over the app's support folder.
pub fn system_sources(support: PathBuf) -> MakeSources {
    Box::new(move |request| {
        Ok(Arc::new(SystemAnonymizeSources::open(
            Path::new(&request.path),
            &support,
            request.pixel_aspect,
            request.deinterlace,
        )?) as Arc<dyn AnonymizeSources>)
    })
}

#[cfg(test)]
mod tests;
