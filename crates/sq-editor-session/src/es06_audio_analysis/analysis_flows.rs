// Swift: AnalysisFlows.swift
//! The session side of the analysis commands (Find Scene Changes, Auto Reframe, Stabilize): target checks, one job at a
//! time with Cancel on the second request, progress and ending lines.
//!
//! The Swift class holds the session and awaits tasks. Here every method takes `&mut EditorSession`, the slow work runs
//! through an [`AnalysisLauncher`] (a worker) and comes back as an [`AnalysisFlowsMessage`] the app routes to
//! [`AnalysisFlows::handle_message`]. What the UI closures `setJob` / `flash` did is an [`AnalysisFlowsEvent`].

use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::Duration;

use sq_analysis::reframe::ReframeOptions;
use sq_analysis::reframe_sheet_options::{ReframeSmoothness, ReframeTightness};
use sq_core_model::{Clip, MediaRef};
use sq_core_time::{Id, IdSource, Time};
use sq_library::library_folder_store::SettingsStore;

use super::analysis_job::{AnalysisJob, AnalysisJobCtx, AnalysisJobEnding, AnalysisJobError};
use super::reframe::{BoxedSubjectDetector, ReframeAnalysis, ReframeOutcome, ReframeRun};
use super::settings::{get_string, set_string};
use super::stabilize::{BoxedStabilizationAnalyzer, StabilizeAnalysis, StabilizeOutcome, StabilizeRun};
use crate::{AnalysisBackend, EditorSession, ProgramFrameSampling};

/// What `AnalysisFlows` tells the UI (Swift `AnalysisFlowUI` closures and `onStabilizeProgress`).
#[derive(Clone, Debug, PartialEq)]
pub enum AnalysisFlowsEvent {
    /// The running job's title in the status line; `None` clears it.
    // Swift: AnalysisFlows.swift:32
    SetJob(Option<String>),
    /// A message shown for `seconds`.
    // Swift: AnalysisFlows.swift:34
    Flash { message: String, seconds: f64 },
    /// A Stabilizer analysis from an Effect Controls Analyze row: its clips and progress 0...1; `None` when it ended.
    // Swift: AnalysisFlows.swift:56
    StabilizeProgress { clips: BTreeSet<Id>, progress: Option<f64> },
}

/// Which of the three jobs a message belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnalysisJobKind {
    SceneChanges,
    Reframe,
    Stabilize,
}

/// What the scene-change worker found.
#[derive(Clone, Debug, PartialEq)]
pub enum SceneWork {
    /// Media-time changes per clip.
    Found(Vec<(Id, Vec<Time>)>),
    /// The backend has no scene detector.
    Unsupported,
    /// A file could not be read (the message).
    Failed(String),
    Cancelled,
}

/// A worker's answer, routed back to [`AnalysisFlows::handle_message`] by the app's inbox.
#[derive(Clone, Debug)]
pub enum AnalysisFlowsMessage {
    Progress { job: AnalysisJobKind, generation: u64, progress: f64 },
    SceneChanges { generation: u64, work: SceneWork },
    Reframe { generation: u64, result: Result<ReframeAnalysis, AnalysisJobError> },
    Stabilize { generation: u64, result: Result<StabilizeAnalysis, AnalysisJobError> },
}

/// Posts a message to the app inbox from any thread.
pub type AnalysisPoster = Arc<dyn Fn(AnalysisFlowsMessage) + Send + Sync>;

/// Work for a worker; it gets an id source that is safe on that thread.
pub type AnalysisWork = Box<dyn FnOnce(&mut dyn IdSource) + Send>;

/// Where the analysis work runs: a worker thread of the app, with a way back into its inbox.
pub trait AnalysisLauncher {
    /// Posts a message to the app inbox from any thread.
    fn poster(&self) -> AnalysisPoster;
    /// Runs `work` on a worker.
    fn launch(&mut self, work: AnalysisWork);
}

/// A backend that offers nothing (Swift's protocol-extension defaults): every command says it is unavailable.
pub struct NoAnalysisBackend;

impl AnalysisBackend for NoAnalysisBackend {
    // Swift: AnalysisFlows.swift:24
    fn scene_changes(
        &self,
        _path: &std::path::Path,
        _range: sq_core_time::TimeRange,
        _progress: &(dyn Fn(f64) + Send + Sync),
    ) -> Result<Option<Vec<Time>>, String> {
        Ok(None)
    }
    // Swift: AnalysisFlows.swift:22
    fn offers_reframe(&self) -> bool {
        false
    }
    // Swift: AnalysisFlows.swift:23
    fn offers_stabilize(&self) -> bool {
        false
    }
    // Swift: AnalysisFlows.swift:25
    fn subject_detector(&self, _media: &MediaRef) -> Option<BoxedSubjectDetector> {
        None
    }
    // Swift: AnalysisFlows.swift:26
    fn stabilization_analyzer(&self, _media: &MediaRef) -> Option<BoxedStabilizationAnalyzer> {
        None
    }
}

/// What a running Stabilize job reports to, and what it covers.
#[derive(Clone, Debug)]
enum StabilizeFlow {
    /// Clip > Video Options > Stabilize: no progress rows.
    Command { what: String },
    /// An Effect Controls Analyze row: these clips show the progress.
    Rows { shown: BTreeSet<Id> },
}

/// Scene detection, Reframe, Stabilize and Match Color to Clip as user flows (Swift `AnalysisFlows`; the session it
/// held is a parameter of every method).
// Swift: AnalysisFlows.swift:44
// Swift: AnalysisFlows.swift:45
// Swift: AnalysisFlows.swift:49
pub struct AnalysisFlows {
    // Swift: AnalysisFlows.swift:46
    pub backend: Option<Arc<dyn AnalysisBackend>>,
    /// Reads the Program picture back for Match Color to Clip; `None` = this host cannot.
    // Swift: AnalysisFlows.swift:48
    pub frame_sampler: Option<Box<dyn ProgramFrameSampling>>,
    // Swift: AnalysisFlows.swift:50
    pub scene_job: AnalysisJob,
    // Swift: AnalysisFlows.swift:52
    pub reframe_job: AnalysisJob,
    // Swift: AnalysisFlows.swift:53
    pub stabilize_job: AnalysisJob,
    pub(crate) color_match_busy: bool,
    /// Counts Match Color runs: a timeout or a newer run makes older captures stale.
    pub(crate) color_match_run: i64,
    pub(crate) color_match_step: Option<super::color_match::ColorMatchStep>,
    /// How long a Match Color run may wait for its captures before the monitor goes back to the sequence.
    // Swift: AnalysisFlows.swift:62
    pub color_match_timeout: Duration,
    pub(crate) events: Vec<AnalysisFlowsEvent>,
    scene_run: Option<(Vec<Clip>, String)>,
    reframe_run: Option<(ReframeRun, String)>,
    stabilize_run: Option<(StabilizeRun, StabilizeFlow)>,
}

impl AnalysisFlows {
    // Swift: AnalysisFlows.swift:63
    pub fn new(backend: Option<Box<dyn AnalysisBackend>>) -> AnalysisFlows {
        AnalysisFlows {
            backend: backend.map(Arc::from),
            frame_sampler: None,
            scene_job: AnalysisJob::new(),
            reframe_job: AnalysisJob::new(),
            stabilize_job: AnalysisJob::new(),
            color_match_busy: false,
            color_match_run: 0,
            color_match_step: None,
            color_match_timeout: Duration::from_secs(5),
            events: Vec::new(),
            scene_run: None,
            reframe_run: None,
            stabilize_run: None,
        }
    }

    // Swift: AnalysisFlows.swift:69
    pub fn is_finding_scene_changes(&self) -> bool {
        self.scene_job.is_running()
    }

    // Swift: AnalysisFlows.swift:71
    pub fn is_reframing(&self) -> bool {
        self.reframe_job.is_running()
    }

    // Swift: AnalysisFlows.swift:72
    pub fn is_stabilizing(&self) -> bool {
        self.stabilize_job.is_running()
    }

    /// The status text of a flow this computer cannot run.
    // Swift: AnalysisFlows.swift:73
    pub fn unavailable(title: &str) -> String {
        format!("{title} is not available on this computer yet.")
    }

    /// The UI events since the last call, in order (Swift's `AnalysisFlowUI` closures and `onStabilizeProgress`).
    // Swift: AnalysisFlows.swift:35
    pub fn take_events(&mut self) -> Vec<AnalysisFlowsEvent> {
        std::mem::take(&mut self.events)
    }

    /// "Clip" for one clip, "3 clips" for several.
    pub(crate) fn subject(clips: &[Clip]) -> String {
        if clips.len() == 1 { format!("\u{201C}{}\u{201D}", clips[0].name) } else { format!("{} clips", clips.len()) }
    }

    pub(super) fn flash(&mut self, message: impl Into<String>, seconds: f64) {
        self.events.push(AnalysisFlowsEvent::Flash { message: message.into(), seconds });
    }

    fn set_job(&mut self, title: Option<String>) {
        self.events.push(AnalysisFlowsEvent::SetJob(title));
    }

    fn percent(p: f64) -> i64 {
        (p * 100.0).round() as i64
    }

    fn start(
        job: &mut AnalysisJob,
        kind: AnalysisJobKind,
        launcher: &dyn AnalysisLauncher,
    ) -> Option<(AnalysisJobCtx, AnalysisPoster)> {
        let post = launcher.poster();
        let p = Arc::clone(&post);
        let ctx = job.start(Arc::new(move |generation, progress| {
            p(AnalysisFlowsMessage::Progress { job: kind, generation, progress })
        }))?;
        Some((ctx, post))
    }

    // MARK: Find Scene Changes

    /// Clip > Video Options > Find Scene Changes. Running it again while it reads cancels it.
    // Swift: AnalysisFlows.swift:82
    pub fn request_find_scene_changes(&mut self, session: &mut EditorSession, launcher: &mut dyn AnalysisLauncher) {
        if self.scene_job.is_running() {
            if let Some(e) = self.scene_job.cancel::<Option<usize>>() {
                self.scene_ended(session, e, true);
            }
            return;
        }
        let clips = session.scene_change_targets();
        if clips.is_empty() {
            self.flash("Select a video clip to look through.", 5.0);
            return;
        }
        let Some(backend) = self.backend.clone() else {
            self.flash(Self::unavailable("Find Scene Changes"), 5.0);
            return;
        };
        let what = Self::subject(&clips);
        self.set_job(Some(format!("Find Scene Changes: reading {what}\u{2026}")));
        let Some((ctx, post)) = Self::start(&mut self.scene_job, AnalysisJobKind::SceneChanges, launcher) else {
            return;
        };
        let total = clips.len() as f64;
        let paths: Vec<(Id, std::path::PathBuf, sq_core_time::TimeRange)> = clips
            .iter()
            .filter(|c| c.kind == sq_core_model::TrackKind::Video && !c.is_generator())
            .map(|c| {
                (c.id, session.project().media(c.media).map(|m| m.path.clone().into()).unwrap_or_default(), c.source)
            })
            .collect();
        self.scene_run = Some((clips, what));
        launcher.launch(Box::new(move |_ids| {
            let mut found = Vec::new();
            for (done, (id, path, range)) in paths.into_iter().enumerate() {
                if ctx.cancel.is_cancelled() {
                    post(AnalysisFlowsMessage::SceneChanges { generation: ctx.generation, work: SceneWork::Cancelled });
                    return;
                }
                if path.as_os_str().is_empty() {
                    found.push((id, Vec::new()));
                    continue;
                }
                let base = done as f64 / total;
                match backend.scene_changes(&path, range, &|p| ctx.progress(base + p / total)) {
                    Ok(Some(times)) => found.push((id, times)),
                    Ok(None) => {
                        post(AnalysisFlowsMessage::SceneChanges {
                            generation: ctx.generation,
                            work: SceneWork::Unsupported,
                        });
                        return;
                    }
                    Err(e) => {
                        post(AnalysisFlowsMessage::SceneChanges {
                            generation: ctx.generation,
                            work: SceneWork::Failed(e),
                        });
                        return;
                    }
                }
            }
            post(AnalysisFlowsMessage::SceneChanges { generation: ctx.generation, work: SceneWork::Found(found) });
        }));
    }

    fn scene_ended(&mut self, _session: &mut EditorSession, ending: AnalysisJobEnding<Option<usize>>, supported: bool) {
        self.scene_run = None;
        self.set_job(None);
        let title = "Find Scene Changes";
        match ending {
            AnalysisJobEnding::Done(Some(0)) => self.flash("No scene changes found.", 4.0),
            AnalysisJobEnding::Done(Some(c)) => {
                let text = if c == 1 {
                    "1 scene change marked. Clip > Audio Options > Accept All Proposed Cuts cuts the clips there, or reject.".to_string()
                } else {
                    format!(
                        "{c} scene changes marked. Clip > Audio Options > Accept All Proposed Cuts cuts the clips there, or reject."
                    )
                };
                self.flash(text, 6.0);
            }
            AnalysisJobEnding::Done(None) => {
                if supported {
                    self.flash("Find Scene Changes failed.", 6.0)
                } else {
                    self.flash(Self::unavailable(title), 5.0)
                }
            }
            AnalysisJobEnding::Cancelled => {
                if supported {
                    self.flash("Find Scene Changes canceled.", 3.0)
                } else {
                    self.flash(Self::unavailable(title), 5.0)
                }
            }
            AnalysisJobEnding::Failed(why) => self.flash(format!("Find Scene Changes failed: {why}"), 8.0),
        }
    }

    // MARK: Auto Reframe

    /// The targets' name for the options dialog, `None` (after saying why) when there is nothing to reframe. Cancels a
    /// running analysis and returns `None` instead.
    // Swift: AnalysisFlows.swift:128
    pub fn reframe_subject(&mut self, session: &mut EditorSession) -> Option<String> {
        if self.reframe_job.is_running() {
            if let Some(e) = self.reframe_job.cancel::<ReframeOutcome>() {
                self.reframe_ended(session, e);
            }
            return None;
        }
        let targets = session.reframe_targets();
        if targets.is_empty() {
            self.flash("Select a video clip to reframe.", 5.0);
            return None;
        }
        if !self.backend.as_ref().is_some_and(|b| b.offers_reframe()) {
            self.flash(Self::unavailable("Auto Reframe"), 5.0);
            return None;
        }
        Some(Self::subject(&targets))
    }

    // Swift: AnalysisFlows.swift:135
    pub fn run_auto_reframe(
        &mut self,
        session: &mut EditorSession,
        launcher: &mut dyn AnalysisLauncher,
        options: ReframeOptions,
        what: &str,
    ) {
        if self.reframe_job.is_running() {
            return;
        }
        let Some(backend) = self.backend.clone() else { return };
        self.set_job(Some(format!("Auto Reframe: analyzing {what}\u{2026}")));
        let Some((ctx, post)) = Self::start(&mut self.reframe_job, AnalysisJobKind::Reframe, launcher) else { return };
        let Some(run) = session.reframe_run(&options) else {
            let g = ctx.generation;
            post(AnalysisFlowsMessage::Reframe {
                generation: g,
                result: Ok(ReframeAnalysis { plans: Default::default(), outcome: ReframeOutcome::default() }),
            });
            self.reframe_run = None;
            return;
        };
        self.reframe_run = Some((run.clone(), what.to_string()));
        launcher.launch(Box::new(move |ids| {
            let detector = |m: &MediaRef| -> Option<BoxedSubjectDetector> { backend.subject_detector(m) };
            let progress = |p: f64| ctx.progress(p);
            let result = run.analyze(&detector, Some(&progress), &ctx.cancel, ids).map_err(AnalysisJobError::from);
            post(AnalysisFlowsMessage::Reframe { generation: ctx.generation, result });
        }));
    }

    fn reframe_ended(&mut self, _session: &mut EditorSession, ending: AnalysisJobEnding<ReframeOutcome>) {
        self.reframe_run = None;
        self.set_job(None);
        match ending {
            AnalysisJobEnding::Done(out) => self.flash(Self::reframe_message(&out), 5.0),
            AnalysisJobEnding::Cancelled => self.flash("Auto Reframe canceled.", 3.0),
            AnalysisJobEnding::Failed(why) => self.flash(format!("Auto Reframe failed: {why}"), 8.0),
        }
    }

    /// The Auto Reframe sheet's Motion choices as row titles.
    // Swift: AnalysisFlows.swift:157
    pub fn reframe_motion_titles() -> Vec<&'static str> {
        ReframeSmoothness::ALL.iter().map(|s| s.title()).collect()
    }

    /// The Auto Reframe sheet's Framing choices as row titles.
    // Swift: AnalysisFlows.swift:158
    pub fn reframe_framing_titles() -> Vec<&'static str> {
        ReframeTightness::ALL.iter().map(|s| s.title()).collect()
    }

    /// The remembered picks (`sq.reframe.*`): (motion index, framing index).
    // Swift: AnalysisFlows.swift:159
    pub fn remembered_reframe_pick(d: &dyn SettingsStore) -> (usize, usize) {
        let m = get_string(d, "sq.reframe.smoothness")
            .as_deref()
            .and_then(ReframeSmoothness::from_raw)
            .unwrap_or(ReframeSmoothness::ALL[1]);
        let f = get_string(d, "sq.reframe.tightness")
            .as_deref()
            .and_then(ReframeTightness::from_raw)
            .unwrap_or(ReframeTightness::ALL[0]);
        (
            ReframeSmoothness::ALL.iter().position(|x| *x == m).unwrap_or(1),
            ReframeTightness::ALL.iter().position(|x| *x == f).unwrap_or(0),
        )
    }

    /// The options of a pick, which is remembered too.
    // Swift: AnalysisFlows.swift:165
    pub fn reframe_options(motion: i64, framing: i64, d: &mut dyn SettingsStore) -> ReframeOptions {
        let pick = |n: i64, len: usize| n.clamp(0, len as i64 - 1) as usize;
        let s = ReframeSmoothness::ALL[pick(motion, ReframeSmoothness::ALL.len())];
        let t = ReframeTightness::ALL[pick(framing, ReframeTightness::ALL.len())];
        set_string(d, "sq.reframe.smoothness", s.raw_value());
        set_string(d, "sq.reframe.tightness", t.raw_value());
        ReframeOptions::with_choices(s, t)
    }

    // Swift: AnalysisFlows.swift:173
    pub fn reframe_message(o: &ReframeOutcome) -> String {
        let mut parts: Vec<String> = Vec::new();
        if o.reframed > 0 {
            parts.push(format!("Reframed {} clip(s); the Position keys are in Effect Controls.", o.reframed));
        }
        if o.already_framed > 0 {
            parts.push(format!("{} clip(s) already fill the frame.", o.already_framed));
        }
        if o.no_subject > 0 {
            parts.push(format!("No subject found in {} clip(s).", o.no_subject));
        }
        if o.failed > 0 {
            parts.push(format!("{} clip(s) could not be read.", o.failed));
        }
        if o.stalled > 0 {
            parts.push(format!("{} clip(s) stopped answering and were skipped; try them again.", o.stalled));
        }
        if parts.is_empty() { "Nothing to reframe.".to_string() } else { parts.join(" ") }
    }

    // MARK: Stabilize

    /// Clip > Video Options > Stabilize on the picture analysis (the shared window). Running it again while it analyzes
    /// cancels it.
    /// Same as Swift (AnalysisFlows.swift:189): the shared window has no Gyroflow offer and no stale re-run; both live in
    /// the Effect Controls Analyze row.
    // Swift: AnalysisFlows.swift:189
    pub fn request_stabilize(&mut self, session: &mut EditorSession, launcher: &mut dyn AnalysisLauncher) {
        if self.stabilize_job.is_running() {
            if let Some(e) = self.stabilize_job.cancel::<StabilizeOutcome>() {
                self.stabilize_ended(session, launcher, e);
            }
            return;
        }
        let targets = session.stabilize_targets();
        if targets.is_empty() {
            self.flash("Select a video clip to stabilize.", 5.0);
            return;
        }
        if !self.backend.as_ref().is_some_and(|b| b.offers_stabilize()) {
            self.flash(Self::unavailable("Stabilize"), 5.0);
            return;
        }
        let what = Self::subject(&targets);
        self.set_job(Some(format!("Stabilize: analyzing {what}\u{2026}")));
        self.begin_stabilize(session, launcher, StabilizeFlow::Command { what }, None, None);
    }

    /// Starts the Stabilize worker for `only` clips of `timeline` (`None`: the targets of the open sequence).
    fn begin_stabilize(
        &mut self,
        session: &mut EditorSession,
        launcher: &mut dyn AnalysisLauncher,
        flow: StabilizeFlow,
        only: Option<&BTreeSet<Id>>,
        timeline: Option<Id>,
    ) {
        let Some(backend) = self.backend.clone() else { return };
        let Some((ctx, post)) = Self::start(&mut self.stabilize_job, AnalysisJobKind::Stabilize, launcher) else {
            return;
        };
        let Some(run) = session.stabilize_run(None, only, timeline) else {
            post(AnalysisFlowsMessage::Stabilize {
                generation: ctx.generation,
                result: Ok(StabilizeAnalysis::empty()),
            });
            self.stabilize_run = None;
            return;
        };
        let fd = session.project().timeline(run.timeline()).map_or(Time::new(1, 30), |t| t.frame_duration());
        self.stabilize_run = Some((run.clone(), flow));
        launcher.launch(Box::new(move |ids| {
            let analyzer = |m: &MediaRef| -> Option<BoxedStabilizationAnalyzer> { backend.stabilization_analyzer(m) };
            let progress = |p: f64| ctx.progress(p);
            let result = run.analyze(&analyzer, Some(&progress), &ctx.cancel, fd, ids).map_err(AnalysisJobError::from);
            post(AnalysisFlowsMessage::Stabilize { generation: ctx.generation, result });
        }));
    }

    // Swift: AnalysisFlows.swift:211
    pub fn stabilize_message(o: &StabilizeOutcome) -> String {
        let mut parts: Vec<String> = Vec::new();
        if o.stabilized > 0 {
            let scaled = (1.0 / (1.0 - o.max_crop) * 100.0 - 100.0).round() as i64;
            parts.push(format!("Stabilized {} clip(s), scaled up {scaled} %.", o.stabilized));
        }
        if o.uncovered > 0 {
            parts.push(format!("{} clip(s) move too much to hold still; edges show.", o.uncovered));
        }
        if o.left_as_shot > 0 {
            parts.push(format!(
                "{} clip(s) left as shot: too little detail to measure the shake reliably.",
                o.left_as_shot
            ));
        }
        if o.partly > 0 {
            parts.push(format!("{} clip(s) steadied only in parts (too little detail elsewhere).", o.partly));
        }
        if o.failed > 0 {
            parts.push(format!("{} clip(s) could not be read.", o.failed));
        }
        if o.gyroflow > 0 {
            parts.push(format!("{} clip(s) use the Gyroflow method and were left as they are.", o.gyroflow));
        }
        if parts.is_empty() { "Nothing to stabilize.".to_string() } else { parts.join(" ") }
    }

    pub(crate) fn begin_stabilizer_rows(
        &mut self,
        session: &mut EditorSession,
        launcher: &mut dyn AnalysisLauncher,
        ids: &BTreeSet<Id>,
        timeline: Option<Id>,
    ) {
        self.set_job(Some("Stabilize: analyzing\u{2026}".to_string()));
        self.events.push(AnalysisFlowsEvent::StabilizeProgress { clips: ids.clone(), progress: Some(0.0) });
        self.begin_stabilize(session, launcher, StabilizeFlow::Rows { shown: ids.clone() }, Some(ids), timeline);
    }

    pub(crate) fn stabilize_ended(
        &mut self,
        session: &mut EditorSession,
        launcher: &mut dyn AnalysisLauncher,
        ending: AnalysisJobEnding<StabilizeOutcome>,
    ) {
        let flow = self.stabilize_run.take().map(|(_, f)| f);
        self.set_job(None);
        let rows = match &flow {
            Some(StabilizeFlow::Rows { shown }) => Some(shown.clone()),
            _ => None,
        };
        if let Some(shown) = &rows {
            self.events.push(AnalysisFlowsEvent::StabilizeProgress { clips: shown.clone(), progress: None });
        }
        let cancelled = matches!(ending, AnalysisJobEnding::Cancelled);
        let failed = matches!(ending, AnalysisJobEnding::Failed(_));
        match ending {
            AnalysisJobEnding::Done(out) => self.flash(Self::stabilize_message(&out), 5.0),
            AnalysisJobEnding::Cancelled => self.flash("Stabilize canceled.", 3.0),
            AnalysisJobEnding::Failed(why) => self.flash(format!("Stabilize failed: {why}"), 8.0),
        }
        let Some(shown) = rows else { return };
        if cancelled {
            session.drop_queued_stabilizer_analysis();
            return;
        }
        if failed {
            session.withdraw_rolling_shutter_requests(Some(&shown));
        }
        if let Some((timeline, clips)) = session.take_next_queued_stabilizer_analysis() {
            self.analyze_stabilizers(session, launcher, &clips, Some(timeline));
        }
    }

    /// A message of a worker. Stale ones (of a canceled run) are dropped.
    pub fn handle_message(
        &mut self,
        session: &mut EditorSession,
        launcher: &mut dyn AnalysisLauncher,
        msg: AnalysisFlowsMessage,
    ) {
        match msg {
            AnalysisFlowsMessage::Progress { job, generation, progress } => self.progress(job, generation, progress),
            AnalysisFlowsMessage::SceneChanges { generation, work } => {
                if !self.scene_job.is_current(generation) {
                    return;
                }
                let clips = self.scene_run.as_ref().map(|r| r.0.clone()).unwrap_or_default();
                let (ending, supported) = match work {
                    SceneWork::Cancelled => (AnalysisJobEnding::Cancelled, true),
                    SceneWork::Unsupported => (AnalysisJobEnding::Done(None), false),
                    SceneWork::Failed(why) => {
                        session.set_error(why);
                        (AnalysisJobEnding::Done(None), true)
                    }
                    SceneWork::Found(found) => {
                        let n = session.find_scene_changes(
                            &clips,
                            &mut |c| Ok(found.iter().find(|f| f.0 == c.id).map(|f| f.1.clone()).unwrap_or_default()),
                            &|| false,
                        );
                        (AnalysisJobEnding::Done(n), true)
                    }
                };
                if let Some(e) = self.scene_job.end(generation, ending) {
                    self.scene_ended(session, e, supported);
                }
            }
            AnalysisFlowsMessage::Reframe { generation, result } => {
                if !self.reframe_job.is_current(generation) {
                    return;
                }
                let ending = match result {
                    Ok(analysis) => match self.reframe_run.as_ref().map(|r| r.0.clone()) {
                        Some(run) => AnalysisJobEnding::Done(session.finish_reframe(&run, analysis)),
                        None => AnalysisJobEnding::Done(analysis.outcome),
                    },
                    Err(e) => Result::<ReframeOutcome, _>::Err(e).into(),
                };
                if let Some(e) = self.reframe_job.end(generation, ending) {
                    self.reframe_ended(session, e);
                }
            }
            AnalysisFlowsMessage::Stabilize { generation, result } => {
                if !self.stabilize_job.is_current(generation) {
                    return;
                }
                let ending = match result {
                    Ok(analysis) => match self.stabilize_run.as_ref().map(|r| r.0.clone()) {
                        Some(run) => AnalysisJobEnding::Done(session.finish_stabilize(&run, analysis)),
                        None => AnalysisJobEnding::Done(StabilizeOutcome::default()),
                    },
                    Err(e) => Result::<StabilizeOutcome, _>::Err(e).into(),
                };
                if let Some(e) = self.stabilize_job.end(generation, ending) {
                    self.stabilize_ended(session, launcher, e);
                }
            }
        }
    }

    fn progress(&mut self, job: AnalysisJobKind, generation: u64, p: f64) {
        match job {
            AnalysisJobKind::SceneChanges => {
                if let Some(p) = self.scene_job.tick(generation, p) {
                    let what = self.scene_run.as_ref().map(|r| r.1.clone()).unwrap_or_default();
                    self.set_job(Some(format!("Find Scene Changes: reading {what}\u{2026} {} %", Self::percent(p))));
                }
            }
            AnalysisJobKind::Reframe => {
                if let Some(p) = self.reframe_job.tick(generation, p) {
                    let what = self.reframe_run.as_ref().map(|r| r.1.clone()).unwrap_or_default();
                    self.set_job(Some(format!("Auto Reframe: analyzing {what}\u{2026} {} %", Self::percent(p))));
                }
            }
            AnalysisJobKind::Stabilize => {
                if let Some(p) = self.stabilize_job.tick(generation, p) {
                    let flow = self.stabilize_run.as_ref().map(|r| r.1.clone());
                    match flow {
                        Some(StabilizeFlow::Command { what }) => {
                            self.set_job(Some(format!("Stabilize: analyzing {what}\u{2026} {} %", Self::percent(p))));
                        }
                        Some(StabilizeFlow::Rows { shown }) => {
                            self.events.push(AnalysisFlowsEvent::StabilizeProgress { clips: shown, progress: Some(p) });
                            self.set_job(Some(format!("Stabilize: analyzing\u{2026} {} %", Self::percent(p))));
                        }
                        None => {}
                    }
                }
            }
        }
    }

    /// Cancels the running Stabilize analysis of an Effect Controls row.
    // Swift: AnalysisFlows+StabilizerRow.swift:50
    pub fn cancel_stabilizer_run(&mut self, session: &mut EditorSession, launcher: &mut dyn AnalysisLauncher) {
        if let Some(e) = self.stabilize_job.cancel::<StabilizeOutcome>() {
            self.stabilize_ended(session, launcher, e);
        }
    }

    /// Analyzes these clips' Standard Stabilizers. While another run goes they wait in the session's queue and follow
    /// when it ends. Progress goes to [`AnalysisFlowsEvent::StabilizeProgress`].
    /// Same as Swift (AnalysisFlows+StabilizerRow.swift:5): no Gyroflow method and no automatic re-analysis of trimmed
    /// clips here.
    // Swift: AnalysisFlows+StabilizerRow.swift:23
    pub fn analyze_stabilizers(
        &mut self,
        session: &mut EditorSession,
        launcher: &mut dyn AnalysisLauncher,
        ids: &BTreeSet<Id>,
        timeline: Option<Id>,
    ) {
        let tid = timeline.or(session.active_timeline_id());
        if self.stabilize_job.is_running() {
            session.queue_stabilizer_analysis(ids, tid);
            return;
        }
        if !self.backend.as_ref().is_some_and(|b| b.offers_stabilize()) {
            self.flash(Self::unavailable("Stabilize"), 5.0);
            return;
        }
        self.begin_stabilizer_rows(session, launcher, ids, tid);
    }

    /// The cached analysis a re-plan reads. The portable build has no analysis cache yet.
    /// shortcut: always `None` (no cache on this host); upgrade with the app's analysis cache (Swift `StabilizationCache`).
    // Swift: AnalysisFlows+StabilizerRow.swift:11
    pub fn stabilization_lookup() -> super::stabilize::StabilizationLookup {
        Arc::new(|_, _, _, _| None)
    }
}
