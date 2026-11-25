// Swift: App/Sources/SharedUI/MacShell/EditAPIController.swift (EditAPIController, SessionAPIHost), EditAPIRunState.swift,
// SQEditAPI/EditAPIDiscovery.swift
//! The local Edit API as the app runs it: off by default (`sq.api.enabled`, Preferences > Advanced). When on, a
//! loopback-only server with a fresh per-launch token runs; its port and token go to `edit-api.json` for local tools.
//! Every request runs on the UI thread through the app inbox and commits through `EditorSession::try_perform`, so an
//! agent edit is ONE undo step like any other.

use crate::persist::FileDefaults;
use serde_json::json;
use sq_app_shell::{App, AppMessage};
use sq_core_model::Project;
use sq_editor_session::PlaceOptions;
use sq_core_time::{Id, IdSource, SequentialIds};
use sq_core_model::{EditError, SequenceFormat, ThreePointMode};
use sq_core_time::Time;
use sq_draw_shell::{EditApiState, FlowReply, ShellEditApi, ShellFlow, ShellHost, ShellRoot, StatusTone};
use sq_core_audio::audio_drift_fit::AudioDriftFit;
use sq_draw_shell::{ApiExportRange, ApiExportRequest, ShellImportKind};
use sq_edit_api::edit_apirouter::{
    DocumentInfo, EditAPIConfig, EditAPIHost, EditAPIRouter, ExportRange, ExportRequest, HostError, ImportedMedia,
    JobInfo, JobState, PresetInfo,
};
use std::collections::BTreeMap;
use sq_edit_api::edit_operation::EditOperation;
use sq_edit_api::edit_apiserver_network::{EditAPIServer, State};
use sq_edit_api::perceive::{PerceiveError, PerceiveRequest};
use sq_edit_api::edit_transaction::{EditTransaction, HostCommit, TransactionError, TransactionErrorKind};
use sq_runtime::channel::Sender;
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Defaults key of the switch.
pub const ENABLED_KEY: &str = "sq.api.enabled";
/// Defaults key of the port.
pub const PORT_KEY: &str = "sq.api.port";
/// The port when none (or an invalid one) is stored.
pub const DEFAULT_PORT: u16 = 19790;

/// `EditAPIRunState.text` / `tone` for the run states of the Settings page.
fn state(text: &str, tone: StatusTone, port: Option<i64>) -> EditApiState {
    EditApiState { text: text.to_string(), tone, copyable_port: port }
}

fn not_running() -> EditApiState {
    state("Not running", StatusTone::Idle, None)
}

/// The host side of the API: every call is a message to the UI thread, answered through a channel.
#[derive(Clone)]
pub(crate) struct ApiBridge {
    sender: Sender<AppMessage>,
    /// Frames, transcripts and the Premiere import (set by the app; `None` in tests without an engine).
    pub(crate) perceive: Option<crate::edit_api_perceive::PerceiveBackend>,
    /// Where the PNG files of a capture go.
    pub(crate) cache: PathBuf,
    pub(crate) busy: Arc<AtomicBool>,
    /// The one job map of the API (export, import, transcript, captions): one id space, one `GET /v1/jobs/{id}` shape.
    pub(crate) jobs: Arc<Mutex<Jobs>>,
}

/// How a background task of the API stands.
#[derive(Clone)]
pub(crate) enum TaskState {
    Running,
    Done(serde_json::Value),
    Failed(String),
}

/// What a background task writes its end into.
pub(crate) type TaskSlot = Arc<Mutex<TaskState>>;

/// One long job the API handed out.
pub(crate) enum JobEntry {
    /// Queue jobs of one export.
    Export(Vec<Id>),
    /// Work on its own thread (an import that outlived its request, a transcript, captions).
    Task { kind: &'static str, slot: TaskSlot },
}

/// The job map: ids are `<kind>-N` (`export-1`, `import-2`, `transcript-3`, `captions-4`).
#[derive(Default)]
pub(crate) struct Jobs {
    next: u64,
    entries: BTreeMap<String, JobEntry>,
}

impl Jobs {
    pub(crate) fn add(&mut self, kind: &str, entry: JobEntry) -> String {
        self.next += 1;
        let id = format!("{kind}-{}", self.next);
        self.entries.insert(id.clone(), entry);
        id
    }
}

/// The `GET /v1/jobs/{id}` answer of a task.
pub(crate) fn task_info(id: &str, kind: &'static str, state: &TaskState) -> JobInfo {
    let (state, progress, result, error) = match state {
        TaskState::Running => (JobState::Running, 0.0, None, None),
        TaskState::Done(v) => (JobState::Done, 1.0, Some(v.clone()), None),
        TaskState::Failed(e) => (JobState::Failed, 1.0, None, Some(e.clone())),
    };
    JobInfo { id: id.to_string(), kind, state, progress, result, error }
}

impl ApiBridge {
    /// Runs `work` on the UI thread and waits for its answer; `None` when `cancel` is set, the connection deadline
    /// passes or the app is gone. The work itself checks `abandoned` so a request given up on never commits late.
    pub(crate) fn call<T: Send + 'static>(
        &self,
        cancel: Option<&AtomicBool>,
        work: impl FnOnce(&mut App, &AtomicBool) -> T + Send + 'static,
    ) -> Option<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        let abandoned = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&abandoned);
        self.sender.send(AppMessage::Post(Box::new(move |app| {
            let _ = tx.send(work(app, &flag));
        })));
        let started = Instant::now();
        loop {
            match rx.recv_timeout(Duration::from_millis(25)) {
                Ok(v) => return Some(v),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if cancel.is_some_and(|c| c.load(Ordering::SeqCst)) || started.elapsed() > EditAPIServer::TIMEOUT {
                        abandoned.store(true, Ordering::SeqCst);
                        return None;
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return None,
            }
        }
    }
}

/// Runs `f` with the session's id source taken out of it (the transaction draws ids while the session commits).
pub(crate) fn with_ids<T>(app: &mut App, f: impl FnOnce(&mut App, &mut dyn IdSource) -> T) -> T {
    let mut ids = std::mem::replace(&mut app.session_mut().ids, Box::new(SequentialIds::default()));
    let out = f(app, ids.as_mut());
    app.session_mut().ids = ids;
    out
}

/// Runs a batch that holds session operations (`addClip`, `createSequence`, `setActiveSequence`) one operation at a time
/// through the same session commands the UI uses, then folds every step it made into ONE undo step named `r.name`. Any
/// failure rewinds the history to where it was and reopens the sequence that was open. Not available as a dry run.
fn run_session_batch(
    app: &mut App,
    r: &HostCommit,
    fits: &BTreeMap<(Id, Id), AudioDriftFit>,
) -> Result<(Project, Project), TransactionError> {
    let fail = |kind: TransactionErrorKind, i: usize| TransactionError {
        kind,
        operation_index: Some(i),
        operation: r.operations.get(i).map(|o| o.name().to_string()),
        detail: None,
    };
    if r.dry_run {
        return Err(TransactionError::new(TransactionErrorKind::InvalidValue(
            "dryRun is not available for batches with addClip, createSequence or setActiveSequence",
        )));
    }
    let before = app.session().project().clone();
    let (depth, opened, playhead) =
        (app.session().undo_step_depth(), app.session().active_timeline_id(), app.session().playhead());
    // The reason of an `Invalid` failure (the step's error kind has no room for text).
    let mut detail: Option<String> = None;
    let mut current = r.sequence;
    let mut failure: Option<TransactionError> = None;
    for (i, op) in r.operations.iter().enumerate() {
        let step: Result<(), TransactionErrorKind> = match op {
            EditOperation::AddClip { media, track, at, source_in, source_out, link_audio, insert } => {
                let s = app.session_mut();
                if s.project().media(*media).is_none() {
                    Err(TransactionErrorKind::MediaNotFound)
                } else if track.is_some_and(|t| s.active_timeline().is_none_or(|tl| tl.track(t).is_none())) {
                    Err(TransactionErrorKind::TrackNotFound)
                } else {
                    let options = PlaceOptions {
                        at: Some(*at),
                        video_track: *track,
                        mode: if *insert { ThreePointMode::Insert } else { ThreePointMode::Overwrite },
                        adopt_format: false,
                        streams: if *link_audio {
                            sq_core_edit::timeline_source_edit::SourceStreams::Both
                        } else {
                            sq_core_edit::timeline_source_edit::SourceStreams::VideoOnly
                        },
                        source: (source_in.is_some() || source_out.is_some()).then_some((*source_in, *source_out)),
                        ..PlaceOptions::default()
                    };
                    if s.place_media(&[*media], &options) {
                        Ok(())
                    } else {
                        Err(TransactionErrorKind::InvalidValue(
                            "addClip placed nothing: the media is offline or has no length, the range is empty, or the track is locked or of the wrong kind",
                        ))
                    }
                }
            }
            EditOperation::CreateSequence { name, width, height, fps, sample_rate } => {
                let mut format = SequenceFormat::new(fps.frame_duration());
                format.width = *width;
                format.height = *height;
                format.audio_sample_rate = sample_rate.unwrap_or(format.audio_sample_rate);
                if format.is_valid() {
                    current = app.session_mut().add_sequence(Some(name), Some(format), None);
                    Ok(())
                } else {
                    Err(TransactionErrorKind::InvalidValue(
                        "invalid sequence format: size 1...16384, a positive frame rate and sample rate",
                    ))
                }
            }
            EditOperation::SetActiveSequence { sequence } => {
                if app.session().project().timeline(*sequence).is_some() {
                    app.session_mut().set_active_timeline(*sequence);
                    current = *sequence;
                    Ok(())
                } else {
                    Err(TransactionErrorKind::Edit(EditError::TimelineNotFound))
                }
            }
            EditOperation::SyncAudio { clip, to, retime } => match fits.get(&(*clip, *to)) {
                Some(fit) if app.session_mut().sync_audio(*clip, *to, fit, *retime) => Ok(()),
                Some(_) => {
                    detail = app.session().last_error().map(str::to_string);
                    Err(TransactionErrorKind::Invalid)
                }
                None => Err(TransactionErrorKind::InvalidValue("syncAudio: no fit was computed")),
            },
            plain => with_ids(app, |app, ids| {
                let edit = |p: &mut Project| EditTransaction::apply(std::slice::from_ref(plain), p, current, &mut *ids);
                app.session_mut().try_perform(&r.name, None, edit).map_err(|e| {
                    detail = e.detail;
                    e.kind
                })
            }),
        };
        if let Err(kind) = step {
            let mut e = fail(kind, i);
            e.detail = detail.take();
            failure = Some(e);
            break;
        }
    }
    if let Some(e) = failure {
        app.session_mut().rewind_undo(depth);
        if let Some(id) = opened {
            app.session_mut().set_active_timeline(id);
        }
        app.session_mut().seek(playhead);
        return Err(e);
    }
    app.session_mut().fold_undo(depth, &r.name);
    Ok((before, app.session().project().clone()))
}

/// The job answer of an export from the queue statuses of its jobs.
fn export_info(id: String, statuses: &[sq_export::core::queue::ExportJobStatus]) -> Option<JobInfo> {
    use sq_export::core::queue::ExportJobState as S;
    if statuses.is_empty() {
        return None;
    }
    let failed = statuses.iter().find_map(|s| match &s.state {
        S::Failed(why) => Some(why.clone()),
        S::Cancelled | S::Cancelling => Some("the export was canceled".to_string()),
        _ => None,
    });
    let state = if failed.is_some() {
        JobState::Failed
    } else if statuses.iter().all(|s| matches!(s.state, S::Done(_))) {
        JobState::Done
    } else if statuses.iter().any(|s| s.state == S::Running) {
        JobState::Running
    } else {
        JobState::Queued
    };
    let progress = statuses.iter().map(|s| if matches!(s.state, S::Done(_)) { 1.0 } else { s.progress }).sum::<f64>()
        / statuses.len() as f64;
    let result = statuses
        .iter()
        .find_map(|s| match &s.state {
            S::Done(url) => Some(url.to_string_lossy().into_owned()),
            _ => None,
        })
        .map(|output| serde_json::json!({ "output": output }));
    Some(JobInfo { id, kind: "export", state, progress, result, error: failed })
}

/// Waits for a flow's answer on the API thread (the UI loop runs the flow); `None` when canceled or the app is gone.
/// How long `POST /v1/import` waits before it answers 202 with a job (must stay below `EditAPIServer::TIMEOUT`).
const IMPORT_WAIT: Duration = Duration::from_secs(10);
const _: () = assert!(IMPORT_WAIT.as_secs() < EditAPIServer::TIMEOUT.as_secs());

fn wait_for_within<T>(rx: &std::sync::mpsc::Receiver<T>, cancel: &AtomicBool, limit: Duration) -> Option<T> {
    let started = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(25)) {
            Ok(v) => return Some(v),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if cancel.load(Ordering::SeqCst) || started.elapsed() >= limit {
                    return None;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return None,
        }
    }
}

fn wait_for<T>(rx: &std::sync::mpsc::Receiver<T>, cancel: &AtomicBool) -> Option<T> {
    loop {
        match rx.recv_timeout(Duration::from_millis(25)) {
            Ok(v) => return Some(v),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if cancel.load(Ordering::SeqCst) {
                    return None;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return None,
        }
    }
}

impl EditAPIHost for ApiBridge {
    fn project(&self) -> Option<Project> {
        self.call(None, |app, _| app.session().project().clone())
    }

    fn active_sequence(&self) -> Option<Id> {
        self.call(None, |app, _| app.session().active_timeline_id()).flatten()
    }

    fn run(&self, request: &HostCommit, cancel: &AtomicBool) -> Result<(Project, Project), TransactionError> {
        let (r, busy) = (request.clone(), self.busy.load(Ordering::SeqCst));
        // Sync Audio reads the files (waveforms, timecodes) in a flow before the commit applies its fit.
        let mut fits: BTreeMap<(Id, Id), AudioDriftFit> = BTreeMap::new();
        for (i, op) in r.operations.iter().enumerate() {
            let EditOperation::SyncAudio { clip, to, .. } = op else { continue };
            let (clip, to) = (*clip, *to);
            let (reply, rx) = FlowReply::channel();
            if self.call(Some(cancel), move |app, _| app.emit_flow(ShellFlow::ApiSyncFit { clip, to, reply })).is_none() {
                return Err(TransactionError::new(TransactionErrorKind::Cancelled));
            }
            match wait_for(&rx, cancel) {
                Some(Ok(fit)) => {
                    fits.insert((clip, to), fit);
                }
                Some(Err(why)) => {
                    return Err(TransactionError {
                        kind: TransactionErrorKind::Invalid,
                        operation_index: Some(i),
                        operation: Some(op.name().to_string()),
                        detail: Some(why),
                    });
                }
                None => return Err(TransactionError::new(TransactionErrorKind::Cancelled)),
            }
        }
        let answer = self.call(Some(cancel), move |app, abandoned| {
            r.admit(app.session().active_timeline_id(), busy, abandoned)?;
            if r.operations.iter().any(EditOperation::is_session_operation) {
                return run_session_batch(app, &r, &fits);
            }
            let before = app.session().project().clone();
            with_ids(app, |app, ids| {
                let edit = |p: &mut Project| EditTransaction::apply(&r.operations, p, r.sequence, &mut *ids);
                if r.dry_run {
                    let after = app.session().preview_perform(edit)?;
                    return Ok((before, after));
                }
                app.session_mut().try_perform(&r.name, None, edit)?;
                Ok((before, app.session().project().clone()))
            })
        });
        answer.unwrap_or_else(|| Err(TransactionError::new(TransactionErrorKind::Cancelled)))
    }

    fn perceive(&self, request: &PerceiveRequest, cancel: &AtomicBool) -> Result<serde_json::Value, PerceiveError> {
        self.perceive_request(request, cancel)
    }

    fn undo(&self, accept: &dyn Fn(&str) -> bool) -> bool {
        // The closure must be 'static + Send: the name check runs here on the answer of the first call.
        let Some(name) = self.call(None, |app, _| app.session().undo_name().map(str::to_string)).flatten() else {
            return false;
        };
        if self.busy.load(Ordering::SeqCst) || !accept(&name) {
            return false;
        }
        // The top step can only have changed to another agent step in between; undo checks the name again.
        self.call(None, move |app, _| app.session().undo_name() == Some(name.as_str()) && app.session_mut().undo())
            .unwrap_or(false)
    }

    fn redo(&self, accept: &dyn Fn(&str) -> bool) -> bool {
        let Some(name) = self.call(None, |app, _| app.session().redo_name().map(str::to_string)).flatten() else {
            return false;
        };
        if self.busy.load(Ordering::SeqCst) || !accept(&name) {
            return false;
        }
        self.call(None, move |app, _| app.session().redo_name() == Some(name.as_str()) && app.session_mut().redo())
            .unwrap_or(false)
    }

    fn playhead(&self) -> Option<Time> {
        self.call(None, |app, _| app.session().playhead())
    }

    fn document(&self) -> Option<DocumentInfo> {
        self.call(None, |app, _| {
            let s = app.session();
            DocumentInfo { path: s.file_url().map(|p| p.to_string_lossy().into_owned()), dirty: s.is_dirty() }
        })
    }

    fn import(&self, paths: Vec<String>, cancel: &AtomicBool) -> Result<Vec<ImportedMedia>, HostError> {
        let missing: Vec<&String> = paths.iter().filter(|p| !Path::new(p.as_str()).exists()).collect();
        if let Some(p) = missing.first() {
            return Err(HostError::new(404, format!("no such file: {p}")));
        }
        // Only media: a project, a Premiere project, a timeline, presets or subtitles would open their own dialogs, which
        // the API cannot answer. Folders are fine (their media are imported).
        for p in &paths {
            let path = Path::new(p);
            let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            let project = matches!(ext.as_str(), "sqproj" | "ssproj");
            // A `.sqproj` can be a folder (package): refused too, before the folder rule.
            if project || (!path.is_dir() && ShellImportKind::of(path) != ShellImportKind::Media) {
                return Err(HostError::new(
                    422,
                    format!("{p}: only media files and folders can be imported here (not projects, timelines, presets or subtitles)"),
                ));
            }
        }
        let (reply, rx) = FlowReply::channel();
        let urls: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
        let asked = self.call(Some(cancel), move |app, _| app.emit_flow(ShellFlow::ApiImport { urls, reply }));
        if asked.is_none() {
            return Err(HostError::new(503, "request canceled"));
        }
        // The import goes on in the app after a timeout; the media show up in /v1/state.
        // Wait less than the connection deadline, so the 202 with the job id still reaches the caller.
        let Some(done) = wait_for_within(&rx, cancel, IMPORT_WAIT) else {
            // It goes on in the app: a job holds the answer once it ends.
            let slot: TaskSlot = Arc::new(Mutex::new(TaskState::Running));
            let writer = Arc::clone(&slot);
            std::thread::spawn(move || {
                let answer = match rx.recv() {
                    Ok(done) => {
                        let media: Vec<ImportedMedia> = done
                            .into_iter()
                            .map(|d| ImportedMedia {
                                path: d.path.to_string_lossy().into_owned(),
                                media: d.media,
                                error: d.error,
                            })
                            .collect();
                        TaskState::Done(serde_json::json!({ "media": media }))
                    }
                    Err(_) => TaskState::Failed("the import ended without an answer".to_string()),
                };
                *writer.lock().unwrap_or_else(PoisonError::into_inner) = answer;
            });
            let id = self.jobs.lock().unwrap_or_else(PoisonError::into_inner).add("import", JobEntry::Task { kind: "import", slot });
            return Err(HostError::running_as(id, "the import is still running: read GET /v1/jobs/{job}"));
        };
        Ok(done
            .into_iter()
            .map(|d| ImportedMedia { path: d.path.to_string_lossy().into_owned(), media: d.media, error: d.error })
            .collect())
    }

    fn save(&self, path: Option<String>, overwrite: bool) -> Result<String, HostError> {
        self.call(None, move |app, _| {
            if path.is_none() && app.session().file_url().is_none() {
                return Err(HostError::new(409, "the project has no file yet: give \"path\""));
            }
            if let Some(p) = &path {
                let same = app.session().file_url().is_some_and(|f| f == Path::new(p));
                if Path::new(p).exists() && !same && !overwrite {
                    return Err(HostError::new(
                        409,
                        format!("{p} already exists and is not this project: send \"overwrite\": true to replace it"),
                    ));
                }
            }
            ShellHost::save_now(app.shell_parts(), path.as_deref().map(Path::new))
                .map(|written| written.to_string_lossy().into_owned())
                .map_err(|e| HostError::new(500, format!("could not save: {e}")))
        })
        .unwrap_or_else(|| Err(HostError::new(503, "app is gone")))
    }

    fn open(&self, path: String, discard: bool) -> Result<(), HostError> {
        let busy = self.busy.load(Ordering::SeqCst);
        self.call(None, move |app, _| {
            if busy {
                return Err(HostError::new(409, "a timeline edit is in progress, try again"));
            }
            if !Path::new(&path).exists() {
                return Err(HostError::new(404, format!("no such file: {path}")));
            }
            if app.session().is_dirty() && !discard {
                return Err(HostError::new(
                    409,
                    "the open project has unsaved changes: save it first or send \"discard\": true",
                ));
            }
            ShellHost::open_project_now(app.shell_parts(), Path::new(&path))
                .map_err(|e| HostError::new(422, format!("could not open: {e}")))
        })
        .unwrap_or_else(|| Err(HostError::new(503, "app is gone")))
    }

    fn export(&self, request: ExportRequest) -> Result<String, HostError> {
        let asked = ApiExportRequest {
            sequence: request.sequence,
            file: PathBuf::from(&request.path),
            preset: request.preset,
            range: match request.range {
                ExportRange::Entire => ApiExportRange::Entire,
                ExportRange::InOut => ApiExportRange::InOut,
                ExportRange::Custom { start, end } => ApiExportRange::Custom { start, end },
            },
        };
        let (reply, rx) = FlowReply::channel();
        let sent = self.call(None, move |app, _| app.emit_flow(ShellFlow::ApiExport { request: asked, reply }));
        if sent.is_none() {
            return Err(HostError::new(503, "app is gone"));
        }
        // The flow only builds and queues the job; the encode runs on its own worker.
        let answer = rx.recv_timeout(Duration::from_secs(10));
        match answer {
            Ok(Ok(ids)) => Ok(self.jobs.lock().unwrap_or_else(PoisonError::into_inner).add("export", JobEntry::Export(ids))),
            Ok(Err(why)) => Err(HostError::new(422, why)),
            Err(_) => Err(HostError::new(503, "the app did not answer the export request")),
        }
    }

    fn job(&self, id: &str) -> Option<JobInfo> {
        enum Found {
            Export(Vec<Id>),
            Task(&'static str, TaskSlot),
        }
        let found = match self.jobs.lock().unwrap_or_else(PoisonError::into_inner).entries.get(id)? {
            JobEntry::Export(ids) => Found::Export(ids.clone()),
            JobEntry::Task { kind, slot } => Found::Task(kind, Arc::clone(slot)),
        };
        let job = id.to_string();
        match found {
            Found::Task(kind, slot) => {
                let state = slot.lock().unwrap_or_else(PoisonError::into_inner).clone();
                Some(task_info(&job, kind, &state))
            }
            Found::Export(ids) => self
                .call(None, move |app, _| {
                    let shell = &*app.shell_parts().shell;
                    let statuses: Vec<_> = ids.iter().filter_map(|id| shell.api_export_status(*id)).collect();
                    export_info(job, &statuses)
                })
                .flatten(),
        }
    }

    fn presets(&self) -> Vec<PresetInfo> {
        self.call(None, |app, _| {
            app.shell_parts()
                .shell
                .api_export_presets()
                .into_iter()
                .map(|(id, name)| PresetInfo { id, name })
                .collect()
        })
        .unwrap_or_default()
    }

    fn seek(&self, at: Time) -> Result<Time, HostError> {
        self.call(None, move |app, _| {
            if app.session().active_timeline().is_none() {
                return Err(HostError::new(409, "no sequence is open"));
            }
            app.session_mut().seek(at);
            Ok(app.session().playhead())
        })
        .unwrap_or_else(|| Err(HostError::new(503, "app is gone")))
    }
}

/// `edit-api.json`: `{port, token, pid}`, created fresh (an old file or a planted link is removed first) and, where the
/// system has file modes, readable by the owner only.
fn write_discovery(path: &Path, port: u16, token: &str) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let _ = std::fs::remove_file(path);
    let bytes = serde_json::to_vec(&json!({ "port": port, "token": token, "pid": std::process::id() }))
        .map_err(std::io::Error::other)?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    std::io::Write::write_all(&mut options.open(path)?, &bytes)
}

/// Starts and stops the server to match the stored switch, and keeps the run state for the Settings page.
pub struct EditApiController {
    sender: Sender<AppMessage>,
    busy: Arc<AtomicBool>,
    discovery: PathBuf,
    cache: PathBuf,
    perceive: Option<crate::edit_api_perceive::PerceiveBackend>,
    state: Arc<Mutex<EditApiState>>,
    server: Option<EditAPIServer>,
}

impl EditApiController {
    /// A stopped controller; requests reach the app through `sender`, the connection file lives in `support`.
    pub fn new(sender: Sender<AppMessage>, support: &Path) -> EditApiController {
        EditApiController {
            sender,
            busy: Arc::new(AtomicBool::new(false)),
            discovery: support.join("edit-api.json"),
            cache: support.join("api-cache"),
            perceive: None,
            state: Arc::new(Mutex::new(not_running())),
            server: None,
        }
    }

    /// Gives the API its frame renderer and media probe (capture, frames, Premiere import).
    pub fn set_perceive(&mut self, backend: crate::edit_api_perceive::PerceiveBackend) {
        self.perceive = Some(backend);
    }

    /// True while a timeline gesture runs (Swift `isBusy`): a commit is refused as busy, an undo is not done.
    pub fn set_busy(&self, busy: bool) {
        self.busy.store(busy, Ordering::SeqCst);
    }

    /// The Advanced page: the switch lives in the stored defaults, the state line in this controller.
    pub fn shell_api(&self, defaults: Rc<RefCell<FileDefaults>>) -> ShellEditApi {
        use sq_uikit::appearance_palette::UiDefaults;
        let read = Rc::clone(&defaults);
        let state = Arc::clone(&self.state);
        ShellEditApi::new(
            move || read.borrow().integer(ENABLED_KEY).is_some_and(|v| v != 0),
            move |on| defaults.borrow_mut().set_integer(ENABLED_KEY, i64::from(on)),
            move || state.lock().unwrap_or_else(PoisonError::into_inner).clone(),
        )
    }

    /// Starts or stops the server to match the setting (`EditAPIController.sync`).
    pub fn sync(&mut self, defaults: &FileDefaults) {
        use sq_uikit::appearance_palette::UiDefaults;
        let wanted = defaults.integer(ENABLED_KEY).is_some_and(|v| v != 0);
        match (wanted, self.server.is_some()) {
            (true, false) => self.start(defaults.integer(PORT_KEY)),
            (false, true) => self.stop(),
            _ => {}
        }
    }

    fn set_state(state: &Mutex<EditApiState>, new: EditApiState) {
        *state.lock().unwrap_or_else(PoisonError::into_inner) = new;
    }

    fn start(&mut self, stored_port: Option<i64>) {
        let port = stored_port.and_then(|p| u16::try_from(p).ok()).filter(|p| *p >= 1024).unwrap_or(DEFAULT_PORT);
        let mut token_bytes = [0_u8; 32];
        if getrandom::fill(&mut token_bytes).is_err() {
            // No secure randomness: never run with a guessable token.
            Self::set_state(&self.state, state("Port in use, could not start", StatusTone::Warning, None));
            return;
        }
        let mut bytes = token_bytes.into_iter();
        let token = EditAPIConfig::make_token(&mut || bytes.next().unwrap_or(0));
        let router = EditAPIRouter::new(
            EditAPIConfig::new(token.clone(), port),
            Arc::new(ApiBridge {
                sender: self.sender.clone(),
                perceive: self.perceive.clone(),
                cache: self.cache.clone(),
                busy: Arc::clone(&self.busy),
                jobs: Arc::default(),
            }),
        );
        let (shared, path) = (Arc::clone(&self.state), self.discovery.clone());
        let server = EditAPIServer::new(router, move |s| match s {
            State::Starting => Self::set_state(&shared, state("Starting…", StatusTone::Idle, None)),
            State::Ready(p) => {
                let new = match write_discovery(&path, p, &token) {
                    Ok(()) => state(&format!("Listening on 127.0.0.1, port {p}"), StatusTone::Ok, Some(i64::from(p))),
                    Err(_) => state(
                        &format!("Listening on 127.0.0.1, port {p}, but the connection file could not be written"),
                        StatusTone::Warning,
                        Some(i64::from(p)),
                    ),
                };
                Self::set_state(&shared, new);
            }
            State::Failed(_) => {
                let _ = std::fs::remove_file(&path);
                Self::set_state(&shared, state("Port in use, could not start", StatusTone::Warning, None));
            }
            State::Stopped => {}
        });
        server.start();
        // A failed start leaves no running server: the next sync tries again (Swift sets `server = nil` on failure).
        if server_failed(&self.state) {
            return;
        }
        self.server = Some(server);
    }

    /// Stops the server and removes the connection file.
    pub fn stop(&mut self) {
        if let Some(server) = self.server.take() {
            server.stop();
            let _ = std::fs::remove_file(&self.discovery);
            Self::set_state(&self.state, not_running());
        }
    }
}

fn server_failed(state: &Mutex<EditApiState>) -> bool {
    state.lock().unwrap_or_else(PoisonError::into_inner).text == "Port in use, could not start"
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_uikit::appearance_palette::UiDefaults;

    #[test]
    fn the_discovery_file_names_port_token_and_pid() {
        let dir = crate::test_rig::test_dir("sq-edit-api-disc");
        let path = dir.join("edit-api.json");
        write_discovery(&path, 19790, "abc").expect("write");
        write_discovery(&path, 19791, "def").expect("rewrite replaces");
        let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
        assert_eq!((v["port"].as_u64(), v["token"].as_str()), (Some(19791), Some("def")));
        assert_eq!(v["pid"].as_u64(), Some(u64::from(std::process::id())));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sync_follows_the_stored_switch_and_a_busy_port_says_so() {
        let dir = crate::test_rig::test_dir("sq-edit-api-sync");
        let (tx, _rx) = sq_runtime::channel::unbounded();
        let mut c = EditApiController::new(tx, &dir);
        let mut d = FileDefaults::default();
        c.sync(&d);
        assert_eq!(c.state.lock().expect("lock").text, "Not running");
        // Take a port first so the start fails there.
        let held = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = held.local_addr().expect("addr").port();
        d.set_integer(ENABLED_KEY, 1);
        d.set_integer(PORT_KEY, i64::from(port.max(1024)));
        c.sync(&d);
        let text = c.state.lock().expect("lock").text.clone();
        assert!(text == "Port in use, could not start" || text.starts_with("Listening"), "{text}");
        d.set_integer(ENABLED_KEY, 0);
        c.sync(&d);
        c.stop();
        // As in Swift, a failed start keeps its line until the next start; a running server goes back to "Not running".
        let text = c.state.lock().expect("lock").text.clone();
        assert!(text == "Not running" || text == "Port in use, could not start", "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One HTTP request to the running server: (status, body).
    fn http(port: u16, method: &str, path: &str, token: Option<&str>, body: &str) -> (u16, String) {
        use std::io::{Read, Write};
        let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        let auth = token.map(|t| format!("Authorization: Bearer {t}\r\n")).unwrap_or_default();
        let request = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        s.write_all(request.as_bytes()).expect("write");
        let mut raw = String::new();
        s.read_to_string(&mut raw).expect("read");
        let status = raw.split(' ').nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
        (status, raw.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default())
    }

    /// Runs `client` on its own thread while this thread plays the UI loop (the server's work goes through the inbox).
    fn serve_while<T: Send + 'static>(app: &sq_app_shell::Headless, client: impl FnOnce() -> T + Send + 'static) -> T {
        let handle = std::thread::spawn(client);
        while !handle.is_finished() {
            app.turn();
            std::thread::sleep(Duration::from_millis(2));
        }
        handle.join().expect("client thread")
    }

    fn free_port() -> u16 {
        std::net::TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).map_or(41777, |a| a.port())
    }

    fn app_with_one_clip() -> sq_app_shell::Headless {
        app_with_clip_file("/tmp/sq-api-1.mp4")
    }

    fn app_with_clip_file(file: &str) -> sq_app_shell::Headless {
        use sq_core_model::{MediaFingerprint, MediaRef};
        use sq_core_time::Time;
        use sq_editor_session::{EditorSession, PlaceOptions, SessionDeps};
        let mut media = MediaRef::new(Id::from_u128(901), "clip", file, MediaFingerprint::new(1));
        media.duration = Some(Time::seconds(10));
        if file.ends_with(".wav") {
            media.duration = Some(Time::seconds(2));
            media.info = serde_json::from_value(serde_json::json!({
                "duration": { "value": 2, "timescale": 1 },
                "audio": { "sampleRate": 48000, "channels": 1, "codec": "pcm_s16le" },
                "isStill": false
            }))
            .ok();
            assert!(media.info.is_some(), "the audio info of the fixture");
        }
        let project = Project::new(Id::from_u128(2), "api", vec![media], Vec::new());
        let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-edit-api-e2e"));
        deps.ids = Box::new(SequentialIds::default());
        let mut session = EditorSession::new(project, deps);
        assert!(session.place_media(&[Id::from_u128(901)], &PlaceOptions::default()));
        let clock = Arc::new(sq_runtime::FakeClock::new());
        sq_app_shell::Headless::new(session, sq_app_shell::AppDeps::headless(clock), 800, 600)
    }

    #[test]
    fn the_default_port_is_19790() {
        assert_eq!(DEFAULT_PORT, 19790);
    }

    #[test]
    fn every_launch_has_its_own_key_and_the_server_refuses_without_it() {
        let dir = crate::test_rig::test_dir("sq-edit-api-key");
        let app = app_with_one_clip();
        let sender = app.with(|a| a.sender()).expect("app");
        let mut c = EditApiController::new(sender, &dir);
        let mut d = FileDefaults::default();
        let port = free_port();
        d.set_integer(ENABLED_KEY, 1);
        d.set_integer(PORT_KEY, i64::from(port));
        let token_of = |dir: &Path| {
            let v: serde_json::Value =
                serde_json::from_slice(&std::fs::read(dir.join("edit-api.json")).expect("file")).expect("json");
            v["token"].as_str().expect("token").to_string()
        };
        c.sync(&d);
        let first = token_of(&dir);
        assert_eq!(first.len(), 64);
        let t = first.clone();
        let (none, wrong, ok) = serve_while(&app, move || {
            (
                http(port, "GET", "/v1/state", None, "").0,
                http(port, "GET", "/v1/state", Some("nope"), "").0,
                http(port, "GET", "/v1/state", Some(&t), "").0,
            )
        });
        assert_eq!((none, wrong, ok), (401, 401, 200));
        c.stop();
        assert!(!dir.join("edit-api.json").exists(), "the connection file goes with the server");
        c.sync(&d);
        assert_ne!(token_of(&dir), first, "a new launch of the server draws a new key");
        c.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_agent_edit_is_one_agent_undo_step() {
        let dir = crate::test_rig::test_dir("sq-edit-api-undo");
        let app = app_with_one_clip();
        let sender = app.with(|a| a.sender()).expect("app");
        let mut c = EditApiController::new(sender, &dir);
        let mut d = FileDefaults::default();
        let port = free_port();
        d.set_integer(ENABLED_KEY, 1);
        d.set_integer(PORT_KEY, i64::from(port));
        c.sync(&d);
        let v: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("edit-api.json")).expect("file")).expect("json");
        let token = v["token"].as_str().expect("token").to_string();
        let depth = |a: &sq_app_shell::Headless| a.with(|a| a.session().undo_name().map(str::to_string)).flatten();
        let before = depth(&app);
        let t = token.clone();
        let (state_status, state_body) = serve_while(&app, move || http(port, "GET", "/v1/state", Some(&t), ""));
        assert_eq!(state_status, 200);
        let state: serde_json::Value = serde_json::from_str(&state_body).expect("state json");
        let sequence = state["activeSequence"].as_str().expect("active sequence").to_string();
        let body = format!(
            r#"{{"name":"Mark","sequence":"{sequence}","operations":[{{"op":"addMarker","at":{{"value":1,"timescale":1}}}},{{"op":"addMarker","at":{{"value":2,"timescale":1}}}}]}}"#
        );
        let t = token.clone();
        let (status, _) = serve_while(&app, move || http(port, "POST", "/v1/commit", Some(&t), &body));
        assert_eq!(status, 200);
        assert_eq!(depth(&app).as_deref(), Some("Agent: Mark"));
        // Two operations are ONE step: a single agent undo returns to the state before the commit.
        let t = token.clone();
        let (undo_status, _) = serve_while(&app, move || http(port, "POST", "/v1/undo", Some(&t), "{}"));
        assert_eq!(undo_status, 200);
        assert_eq!(depth(&app), before);
        c.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Probes any file into a 1920x1080 25 fps video with stereo sound, 10 s long, sized like the file.
    struct FakeProbe;

    impl sq_editor_session::ImportBackend for FakeProbe {
        fn probe(&self, path: &Path) -> Result<sq_core_model::MediaRef, sq_editor_session::ImportError> {
            use sq_core_model::{MediaFingerprint, MediaInfo, MediaRef};
            let size = std::fs::metadata(path).map_or(0, |m| i64::try_from(m.len()).unwrap_or(0));
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let key = path.to_string_lossy().bytes().fold(7u128, |h, b| h.wrapping_mul(131).wrapping_add(u128::from(b)));
            let mut m = MediaRef::new(Id::from_u128(key), &name, &path.to_string_lossy(), MediaFingerprint::new(size));
            let info: MediaInfo = serde_json::from_value(json!({
                "duration": {"value": 10, "timescale": 1},
                "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                          "nominalFrameDuration": {"value": 1, "timescale": 25}, "isVariableFrameRate": false},
                "audio": {"sampleRate": 48000, "channels": 2, "codec": "aac"}
            }))
            .expect("media info");
            m.duration = Some(info.duration);
            m.info = Some(info);
            Ok(m)
        }
    }

    /// An app with one empty sequence whose import probes with `FakeProbe` on real worker threads.
    fn empty_app() -> sq_app_shell::Headless {
        use sq_core_model::{SequenceFormat, Timeline};
        use sq_editor_session::{EditorSession, ProjectPanelDeps, SessionDeps};
        let tracks = Timeline::default_tracks(1, 1, &mut sq_core_time::RandomIds);
        let seq = Timeline::new(Id::from_u128(500), "Sequence 01", SequenceFormat::new(sq_core_time::Time::new(1, 25)), tracks);
        let project = Project::new(Id::from_u128(2), "api", Vec::new(), vec![seq]);
        let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-edit-api-tl"));
        deps.ids = Box::new(sq_core_time::RandomIds);
        let mut session = EditorSession::new(project, deps);
        session.set_active_timeline(Id::from_u128(500));
        let clock = Arc::new(sq_runtime::FakeClock::new());
        let mut app_deps = sq_app_shell::AppDeps::headless(clock);
        app_deps.import = ProjectPanelDeps {
            backend: Arc::new(FakeProbe),
            pool: Arc::new(sq_runtime::WorkerPool::threads(2)),
            ..ProjectPanelDeps::headless()
        };
        sq_app_shell::Headless::new(session, app_deps, 800, 600)
    }

    struct Api {
        app: sq_app_shell::Headless,
        controller: EditApiController,
        port: u16,
        token: String,
        dir: crate::test_rig::TestDir,
    }

    impl Api {
        fn start(tag: &str) -> Api {
            Api::start_with(tag, empty_app())
        }

        fn start_with(tag: &str, app: sq_app_shell::Headless) -> Api {
            let dir = crate::test_rig::test_dir(tag);
            let sender = app.with(|a| a.sender()).expect("app");
            let mut controller = EditApiController::new(sender, &dir);
            let mut d = FileDefaults::default();
            let port = free_port();
            d.set_integer(ENABLED_KEY, 1);
            d.set_integer(PORT_KEY, i64::from(port));
            controller.sync(&d);
            let v: serde_json::Value =
                serde_json::from_slice(&std::fs::read(dir.join("edit-api.json")).expect("file")).expect("json");
            let token = v["token"].as_str().expect("token").to_string();
            Api { app, controller, port, token, dir }
        }

        /// One request; (status, JSON body).
        fn call(&self, method: &'static str, path: &str, body: serde_json::Value) -> (u16, serde_json::Value) {
            let (port, token, body, path) = (self.port, self.token.clone(), body.to_string(), path.to_string());
            let (status, text) = serve_while(&self.app, move || http(port, method, &path, Some(&token), &body));
            (status, serde_json::from_str(&text).unwrap_or(serde_json::Value::Null))
        }

        fn state(&self) -> serde_json::Value {
            let (status, state) = self.call("GET", "/v1/state", json!({}));
            assert_eq!(status, 200);
            state
        }

        fn commit(&self, sequence: &str, name: &str, ops: serde_json::Value) -> (u16, serde_json::Value) {
            self.call("POST", "/v1/commit", json!({"sequence": sequence, "name": name, "operations": ops}))
        }
    }

    fn t(seconds: i64) -> serde_json::Value {
        json!({"value": seconds, "timescale": 1})
    }

    #[test]
    fn a_rough_cut_is_built_saved_and_reopened_through_the_api() {
        let mut api = Api::start("sq-edit-api-rough");
        let media_file = api.dir.join("clip.mp4");
        std::fs::write(&media_file, vec![0_u8; 4096]).expect("media file");
        let first = api.state()["activeSequence"].as_str().expect("sequence").to_string();

        // importMedia: the same flow as a drop; the answer names the media item.
        let (status, imported) = api.call("POST", "/v1/import", json!({"paths": [media_file.to_string_lossy()]}));
        assert_eq!(status, 200, "{imported}");
        let media = imported["media"][0]["media"].as_str().expect("media id").to_string();
        let state = api.state();
        let item = &state["media"][0];
        assert_eq!((item["id"].as_str(), item["size"].as_i64(), item["hasAudio"].as_bool()), (Some(media.as_str()), Some(4096), Some(true)));
        assert_eq!((item["width"].as_i64(), item["fps"]["num"].as_i64(), item["path"].as_str()), (Some(1920), Some(25), media_file.to_str()));

        // createSequence 1080x1920 at 30: one step, the new sequence is open.
        let (status, made) = api.commit(
            &first,
            "Vertical",
            json!([{"op": "createSequence", "name": "Reel", "width": 1080, "height": 1920, "fps": 30}]),
        );
        assert_eq!(status, 200, "{made}");
        let seq = made["sequencesAdded"][0].as_str().expect("new sequence").to_string();
        assert_eq!(made["activeSequence"].as_str(), Some(seq.as_str()));
        let state = api.state();
        assert_eq!(state["activeSequence"].as_str(), Some(seq.as_str()));
        let reel = state["sequences"].as_array().expect("sequences").iter().find(|s| s["id"] == seq.as_str()).expect("reel").clone();
        assert_eq!((reel["width"].as_i64(), reel["height"].as_i64(), reel["fps"]["num"].as_i64(), reel["sampleRate"].as_i64()), (Some(1080), Some(1920), Some(30), Some(48000)));

        // addClip: video with its linked audio, only the part from 1 s to 5 s; ONE agent undo step.
        let (status, added) = api.commit(
            &seq,
            "Add clip",
            json!([{"op": "addClip", "media": media, "at": t(0), "sourceIn": t(1), "sourceOut": t(5)}]),
        );
        assert_eq!(status, 200, "{added}");
        assert_eq!(added["undoName"].as_str(), Some("Agent: Add clip"));
        let clips = added["diff"]["added"].as_array().expect("added clips");
        assert_eq!(clips.len(), 2, "video + linked audio: {added}");
        assert!(clips.iter().all(|c| c["duration"] == t(4) && c["source"]["start"] == t(1)));
        let top = api.app.with(|a| a.session().undo_name().map(str::to_string)).flatten();
        assert_eq!(top.as_deref(), Some("Agent: Add clip"));

        // trim the tail by 1 s, speed 2x, a second audio track, mute it; the sequence stays 1080x1920.
        let state = api.state();
        let video = state["sequences"].as_array().expect("s").iter().filter(|s| s["id"] == seq.as_str()).flat_map(|s| s["tracks"].as_array().expect("t").clone()).filter(|t| t["kind"] == "video").flat_map(|t| t["clips"].as_array().expect("c").clone()).next().expect("video clip")["id"].as_str().expect("id").to_string();
        let (status, trimmed) = api.commit(
            &seq,
            "Trim",
            json!([{"op": "trim", "clip": video, "edge": "tail", "by": t(-1)}, {"op": "addTrack", "kind": "audio"}]),
        );
        assert_eq!(status, 200, "{trimmed}");
        let state = api.state();
        let reel = state["sequences"].as_array().expect("sequences").iter().find(|s| s["id"] == seq.as_str()).expect("reel").clone();
        let new_audio = reel["tracks"].as_array().expect("tracks").last().expect("track")["id"].as_str().expect("id").to_string();
        let (status, set) = api.commit(
            &seq,
            "Track state",
            json!([{"op": "setTrackState", "track": new_audio, "mute": true, "lock": true},
                   {"op": "setSequenceSettings", "sampleRate": 44100}]),
        );
        assert_eq!(status, 200, "{set}");

        // removeClip of a trimmed clip and setClipSpeed on the other: the speed shows in the state.
        let (status, spd) = api.commit(&seq, "Speed", json!([{"op": "setClipSpeed", "clip": video, "speed": {"num": 2, "den": 1}}]));
        assert_eq!(status, 200, "{spd}");
        let state = api.state();
        let find_clip = |state: &serde_json::Value| -> serde_json::Value {
            state["sequences"].as_array().expect("s").iter().filter(|s| s["id"] == seq.as_str()).flat_map(|s| s["tracks"].as_array().expect("t").clone()).flat_map(|t| t["clips"].as_array().expect("c").clone()).find(|c| c["id"] == video.as_str()).expect("clip")
        };
        assert_eq!(find_clip(&state)["speed"], json!({"num": 2, "den": 1}));

        // redo / undo through the API, only for agent steps.
        let (status, _) = api.call("POST", "/v1/undo", json!({}));
        assert_eq!(status, 200);
        assert_eq!(find_clip(&api.state())["speed"], json!({"num": 1, "den": 1}));
        let (status, redone) = api.call("POST", "/v1/redo", json!({}));
        assert_eq!((status, redone["redone"].as_bool()), (200, Some(true)));
        assert_eq!(find_clip(&api.state())["speed"], json!({"num": 2, "den": 1}));

        // removeClip: a second placement goes away again with its linked audio.
        let (status, second) = api.commit(&seq, "Again", json!([{"op": "addClip", "media": media, "at": t(10), "linkAudio": false}]));
        assert_eq!((status, second["diff"]["added"].as_array().map(Vec::len)), (200, Some(1)), "{second}");
        let extra = second["diff"]["added"][0]["id"].as_str().expect("id").to_string();
        let (status, removed) = api.commit(&seq, "Remove", json!([{"op": "removeClip", "clips": [extra]}]));
        assert_eq!((status, removed["diff"]["removed"].as_array().map(Vec::len)), (200, Some(1)), "{removed}");

        // playhead
        let (status, moved) = api.call("POST", "/v1/playhead", json!({"at": t(2)}));
        assert_eq!(status, 200, "{moved}");
        assert_eq!(api.state()["playhead"], t(2));

        // save as, reopen: the state matches (the file and the save state aside).
        let file = api.dir.join("rough.sqproj");
        let (status, saved) = api.call("POST", "/v1/save", json!({"path": file.to_string_lossy()}));
        assert_eq!(status, 200, "{saved}");
        let mut before = api.state();
        assert_eq!(before["dirty"], json!(false));
        let (status, opened) = api.call("POST", "/v1/open", json!({"path": file.to_string_lossy()}));
        assert_eq!(status, 200, "{opened}");
        let mut after = api.state();
        for s in [&mut before, &mut after] {
            let o = s.as_object_mut().expect("state object");
            o.remove("playhead");
            o.remove("dirty");
        }
        assert_eq!(after, before);
        assert_eq!(after["file"].as_str(), file.to_str());
        api.controller.stop();
    }

    #[test]
    fn open_refuses_unsaved_changes_and_bad_requests_name_the_problem() {
        let mut api = Api::start("sq-edit-api-open");
        let seq = api.state()["activeSequence"].as_str().expect("sequence").to_string();
        let file = api.dir.join("a.sqproj");
        let (status, _) = api.call("POST", "/v1/save", json!({"path": file.to_string_lossy()}));
        assert_eq!(status, 200);
        let (status, _) = api.commit(&seq, "Mark", json!([{"op": "addMarker", "at": t(1)}]));
        assert_eq!(status, 200);
        let (status, refused) = api.call("POST", "/v1/open", json!({"path": file.to_string_lossy()}));
        assert_eq!(status, 409, "{refused}");
        let (status, _) = api.call("POST", "/v1/open", json!({"path": file.to_string_lossy(), "discard": true}));
        assert_eq!(status, 200);
        assert_eq!(api.call("POST", "/v1/open", json!({"path": "relative.sqproj"})).0, 400);
        assert_eq!(api.call("POST", "/v1/save", json!({"path": "/tmp/x.txt"})).0, 400);
        assert_eq!(api.call("POST", "/v1/import", json!({"paths": ["/no/such/file.mp4"]})).0, 404);
        assert_eq!(api.call("POST", "/v1/playhead", json!({"at": t(1), "extra": 1})).0, 400);
        // A failing batch changes nothing and leaves no step: addClip of media the project does not have.
        let depth = api.app.with(|a| a.session().undo_step_depth()).expect("app");
        let (status, bad) = api.commit(&seq, "Bad", json!([{"op": "addMarker", "at": t(3)}, {"op": "addClip", "media": "00000000-0000-0000-0000-000000000009", "at": t(0)}]));
        assert_eq!(status, 422, "{bad}");
        assert_eq!(bad["operationIndex"], json!(1));
        assert_eq!(api.app.with(|a| a.session().undo_step_depth()).expect("app"), depth);
        // dryRun is refused for session operations.
        let (status, _) = api.call("POST", "/v1/commit", json!({"sequence": seq, "dryRun": true, "operations": [{"op": "createSequence", "name": "X", "width": 1080, "height": 1920, "fps": 60}]}));
        assert_eq!(status, 422);
        api.controller.stop();
    }

    #[test]
    fn an_agent_graphic_with_three_text_layers_is_animated_read_back_and_undone() {
        let dir = crate::test_rig::test_dir("sq-edit-api-graphic");
        let app = app_with_one_clip();
        let sender = app.with(|a| a.sender()).expect("app");
        let mut c = EditApiController::new(sender, &dir);
        let mut d = FileDefaults::default();
        let port = free_port();
        d.set_integer(ENABLED_KEY, 1);
        d.set_integer(PORT_KEY, i64::from(port));
        c.sync(&d);
        let v: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("edit-api.json")).expect("file")).expect("json");
        let token = v["token"].as_str().expect("token").to_string();
        let undo_name = |a: &sq_app_shell::Headless| a.with(|a| a.session().undo_name().map(str::to_string)).flatten();
        let before = undo_name(&app);
        let t = token.clone();
        let (_, body) = serve_while(&app, move || http(port, "GET", "/v1/state", Some(&t), ""));
        let state: serde_json::Value = serde_json::from_str(&body).expect("state json");
        let sequence = state["activeSequence"].as_str().expect("sequence").to_string();
        let track = state["sequences"][0]["tracks"]
            .as_array()
            .and_then(|t| t.iter().find(|t| t["kind"] == "video"))
            .and_then(|t| t["id"].as_str())
            .expect("video track")
            .to_string();
        let commit = |app: &sq_app_shell::Headless, ops: String, name: &str| {
            let (t, sequence) = (token.clone(), sequence.clone());
            let body = format!(r#"{{"name":"{name}","sequence":"{sequence}","operations":[{ops}]}}"#);
            serve_while(app, move || http(port, "POST", "/v1/commit", Some(&t), &body))
        };
        let (status, reply) = commit(
            &app,
            format!(
                r##"{{"op":"addGraphic","track":"{track}","at":{{"value":12,"timescale":1}},"duration":{{"value":3,"timescale":1}},
                "layers":[{{"text":"One","size":80,"color":"#ffffff"}},{{"text":"Two","position":{{"x":0,"y":120}}}},{{"text":"Three","weight":"bold"}}]}}"##
            ),
            "Titles",
        );
        assert_eq!(status, 200, "{reply}");
        assert_eq!(undo_name(&app).as_deref(), Some("Agent: Titles"));
        let reply: serde_json::Value = serde_json::from_str(&reply).expect("reply");
        let clip = reply["diff"]["added"][0]["id"].as_str().expect("new clip").to_string();
        let (t, path) = (token.clone(), format!("/v1/clip/{clip}/params"));
        let (status, body) = serve_while(&app, move || http(port, "GET", &path, Some(&t), ""));
        assert_eq!(status, 200);
        let params: serde_json::Value = serde_json::from_str(&body).expect("params");
        assert_eq!(params["layers"].as_array().map(Vec::len), Some(3));
        let layer2 = params["layers"][1]["id"].as_str().expect("layer id").to_string();
        let ops = format!(
            r#"{{"op":"setKeyframe","clip":"{clip}","param":"layer.{layer2}.motion.position","at":{{"value":0,"timescale":1}},"value":[-400,0]}},
            {{"op":"setKeyframe","clip":"{clip}","param":"layer.{layer2}.motion.position","at":{{"value":1,"timescale":1}},"value":[400,0]}}"#
        );
        let (status, reply) = commit(&app, ops, "Slide");
        assert_eq!(status, 200, "{reply}");
        let (t, path) = (token.clone(), format!("/v1/clip/{clip}/params"));
        let (_, body) = serve_while(&app, move || http(port, "GET", &path, Some(&t), ""));
        let params: serde_json::Value = serde_json::from_str(&body).expect("params");
        let pos = params["params"].as_array().and_then(|a| a.iter().find(|p| p["path"] == format!("layer.{layer2}.motion.position").as_str())).cloned();
        assert_eq!(pos.as_ref().and_then(|p| p["keyframes"].as_array().map(Vec::len)), Some(2), "{pos:?}");
        // Two agent steps, two agent undos: the graphic is gone.
        for _ in 0..2 {
            let t = token.clone();
            let (s, _) = serve_while(&app, move || http(port, "POST", "/v1/undo", Some(&t), "{}"));
            assert_eq!(s, 200);
        }
        assert_eq!(undo_name(&app), before);
        let gone = app.with(|a| a.session().project().timelines.iter().all(|t| !t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.is_graphics()))));
        assert_eq!(gone, Some(true));
        c.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An encoder that writes a one byte file and keeps the settings it was given.
    struct RecordingEncoder(Arc<Mutex<Vec<sq_export::core::settings::ExportSettings>>>);
    impl sq_export::core::traits::ExportEncoding for RecordingEncoder {
        fn export(
            &self,
            _: &mut dyn sq_export::core::traits::FrameSource,
            _: Option<&mut dyn sq_export::core::traits::AudioSource>,
            settings: &sq_export::core::settings::ExportSettings,
            url: &Path,
            _: &sq_export::core::error::CancelToken,
            progress: &mut dyn FnMut(f64),
        ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, sq_export::core::error::ExportError> {
            self.0.lock().unwrap_or_else(PoisonError::into_inner).push(settings.clone());
            std::fs::write(url, b"x").map_err(|e| sq_export::core::error::ExportError::Other(e.to_string()))?;
            progress(1.0);
            Ok(None)
        }
    }

    struct NoFrames;
    impl sq_export::core::traits::FrameSource for NoFrames {
        fn frame_count(&self) -> usize {
            1
        }
        fn frame_duration(&self) -> Time {
            Time::new(1, 25)
        }
        fn frame(&mut self, _: usize) -> Result<sq_export::core::traits::ExportFrame, sq_export::core::error::ExportError> {
            Err(sq_export::core::error::ExportError::EmptySource)
        }
    }

    /// Reads a job until it is done or failed.
    fn finished_job(api: &Api, job: &str) -> serde_json::Value {
        let mut last = serde_json::Value::Null;
        for _ in 0..400 {
            let (status, info) = api.call("GET", &format!("/v1/jobs/{job}"), json!({}));
            last = info.clone();
            assert_eq!(status, 200, "{info}");
            if matches!(info["state"].as_str(), Some("done" | "failed")) {
                return info;
            }
        }
        panic!("job {job} did not finish: {last}");
    }

    #[test]
    fn an_export_runs_as_a_job_with_the_sheets_settings_and_no_loudness_normalization() {
        use sq_export::core::queue::{ExportQueue, ExportSources};
        let mut api = Api::start("sq-edit-api-export");
        let media_file = api.dir.join("clip.mp4");
        std::fs::write(&media_file, vec![0_u8; 4096]).expect("media file");
        let seq = api.state()["activeSequence"].as_str().expect("sequence").to_string();
        let (_, imported) = api.call("POST", "/v1/import", json!({"paths": [media_file.to_string_lossy()]}));
        let media = imported["media"][0]["media"].as_str().expect("media").to_string();
        let (status, added) = api.commit(&seq, "Add", json!([{"op": "addClip", "media": media, "at": t(0)}]));
        assert_eq!(status, 200, "{added}");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let encoder = RecordingEncoder(Arc::clone(&seen));
        let queue = Arc::new(ExportQueue::new(Arc::new(encoder)));
        let shared = Arc::clone(&queue);
        api.app.with(|a| {
            let shell = a.shell_parts().shell;
            shell.export.sources = Some(Arc::new(|_, _| Ok(ExportSources::new(Box::new(NoFrames), None))));
            shell.export.queue = Some(shared);
        });

        let (status, presets) = api.call("GET", "/v1/presets", json!({}));
        assert_eq!(status, 200, "{presets}");
        assert!(presets["presets"].as_array().expect("presets").iter().any(|p| p["id"] == "tiktok-h264"), "{presets}");

        let out = api.dir.join("out").join("reel.mp4");
        let (status, started) =
            api.call("POST", "/v1/export", json!({"path": out.to_string_lossy(), "preset": "tiktok-9x16"}));
        assert_eq!(status, 200, "{started}");
        let job = started["job"].as_str().expect("job id").to_string();
        // The app runs the queue on `ShellEvent::RunExportQueue` (root.rs); the headless rig has no such host, so the
        // test does what that handler does.
        let worker = Arc::clone(&queue);
        std::thread::spawn(move || worker.run_all());
        let info = finished_job(&api, &job);
        assert_eq!((info["state"].as_str(), info["kind"].as_str()), (Some("done"), Some("export")), "{info}");
        assert_eq!(info["result"]["output"].as_str(), out.to_str(), "{info}");
        assert!(out.exists());
        let settings = seen.lock().unwrap_or_else(PoisonError::into_inner).clone();
        assert_eq!(settings.len(), 1);
        assert!(settings[0].audio.loudness.is_none(), "loudness normalization stays off");
        assert_eq!((settings[0].video.width, settings[0].video.height), (1080, 1920));

        // Bad requests name the problem and queue nothing.
        let wrong = api.dir.join("reel.mov");
        assert_eq!(api.call("POST", "/v1/export", json!({"path": wrong.to_string_lossy(), "preset": "tiktok-9x16"})).0, 422);
        assert_eq!(api.call("POST", "/v1/export", json!({"path": out.to_string_lossy(), "preset": "nope"})).0, 422);
        assert_eq!(api.call("POST", "/v1/export", json!({"path": "rel.mp4"})).0, 400);
        assert_eq!(api.call("POST", "/v1/export", json!({"path": "/a/../b.mp4"})).0, 400);
        assert_eq!(api.call("GET", "/v1/jobs/export-999", json!({})).0, 404);
        api.controller.stop();
    }

    #[test]
    fn a_slow_job_answers_with_its_id_before_the_connection_deadline() {
        use sq_edit_api::edit_apiserver_network::EditAPIServer;
        assert!(crate::edit_api_perceive::JOB_WAIT < EditAPIServer::TIMEOUT);
        let app = empty_app();
        let sender = app.with(|a| a.sender()).expect("app");
        let bridge = ApiBridge {
            sender,
            perceive: None,
            cache: std::env::temp_dir(),
            busy: Arc::new(AtomicBool::new(false)),
            jobs: Arc::new(Mutex::new(Jobs::default())),
        };
        let cancel = AtomicBool::new(false);
        let slow = |_: ApiBridge| {
            std::thread::sleep(Duration::from_millis(600));
            Ok(json!({"text": "late"}))
        };
        let first = bridge.run_job_waiting("transcript", &cancel, Duration::from_millis(100), slow).expect("answer");
        assert_eq!((first["id"].as_str(), first["job"].as_str(), first["kind"].as_str(), first["state"].as_str()), (Some("transcript-1"), Some("transcript-1"), Some("transcript"), Some("running")));
        assert!(first.get("progress").is_some());
        let again = bridge.run_job_waiting("transcript", &cancel, Duration::from_millis(100), |_| Ok(json!({"text": "now"}))).expect("answer");
        assert_eq!(again["text"], "now");
        std::thread::sleep(Duration::from_millis(700));
        let info = bridge.job("transcript-1").expect("job");
        assert_eq!(info.state, JobState::Done);
    }

    #[test]
    fn import_takes_only_media_and_save_as_does_not_replace_other_files() {
        let mut api = Api::start("sq-edit-api-kinds");
        let prproj = api.dir.join("a.prproj");
        std::fs::write(&prproj, b"x").expect("file");
        assert_eq!(api.call("POST", "/v1/import", json!({"paths": [prproj.to_string_lossy()]})).0, 422);
        let package = api.dir.join("pkg.sqproj");
        std::fs::create_dir_all(&package).expect("package");
        let (status, why) = api.call("POST", "/v1/import", json!({"paths": [package.to_string_lossy()]}));
        assert_eq!(status, 422, "a .sqproj folder is refused too: {why}");
        assert!(why["error"].as_str().is_some_and(|e| e.contains("only media")), "{why}");
        let other = api.dir.join("other.sqproj");
        std::fs::write(&other, b"x").expect("file");
        let (status, refused) = api.call("POST", "/v1/save", json!({"path": other.to_string_lossy()}));
        assert_eq!(status, 409, "{refused}");
        assert_eq!(std::fs::read(&other).expect("file"), b"x");
        assert_eq!(api.call("POST", "/v1/save", json!({"path": other.to_string_lossy(), "overwrite": true})).0, 200);
        api.controller.stop();
    }

    #[test]
    fn sync_audio_lines_a_clip_up_with_a_reference_in_one_agent_step() {
        let mut api = Api::start("sq-edit-api-sync");
        let media_file = api.dir.join("clip.mp4");
        std::fs::write(&media_file, vec![0_u8; 4096]).expect("media file");
        let seq = api.state()["activeSequence"].as_str().expect("sequence").to_string();
        let (_, imported) = api.call("POST", "/v1/import", json!({"paths": [media_file.to_string_lossy()]}));
        let media = imported["media"][0]["media"].as_str().expect("media").to_string();
        let (status, track) = api.commit(&seq, "Track", json!([{"op": "addTrack", "kind": "video"}]));
        assert_eq!(status, 200, "{track}");
        let state = api.state();
        let second_video = state["sequences"][0]["tracks"].as_array().expect("tracks").iter().rfind(|t| t["kind"] == "video").expect("track")["id"].as_str().expect("id").to_string();
        let (status, a) = api.commit(&seq, "A", json!([{"op": "addClip", "media": media, "at": t(0), "sourceOut": t(1), "linkAudio": false}]));
        assert_eq!(status, 200, "{a}");
        let reference = a["diff"]["added"][0]["id"].as_str().expect("clip").to_string();
        let (status, b) = api.commit(&seq, "B", json!([{"op": "addClip", "media": media, "track": second_video, "at": t(10), "sourceOut": t(1), "linkAudio": false}]));
        assert_eq!(status, 200, "{b}");
        let clip = b["diff"]["added"][0]["id"].as_str().expect("clip").to_string();
        // The same file twice: no timecode, no sound to compare in this rig, equal capture dates: offset zero.
        let (status, synced) = api.commit(&seq, "Sync", json!([{"op": "syncAudio", "clip": clip, "to": reference}]));
        assert_eq!(status, 200, "{synced}");
        assert_eq!(synced["undoName"].as_str(), Some("Agent: Sync"));
        assert_eq!(synced["diff"]["changed"][0]["after"]["start"], t(0), "{synced}");
        // Unknown clips are refused with the operation index and change nothing.
        let (status, bad) = api.commit(&seq, "Bad", json!([{"op": "syncAudio", "clip": clip, "to": "00000000-0000-0000-0000-000000000009"}]));
        assert_eq!(status, 422, "{bad}");
        assert_eq!(bad["operationIndex"], json!(0));
        api.controller.stop();
    }

    #[test]
    fn create_sequence_is_the_first_commit_of_a_project_without_sequences() {
        use sq_editor_session::{EditorSession, ProjectPanelDeps, SessionDeps};
        let project = Project::new(Id::from_u128(2), "empty", Vec::new(), Vec::new());
        let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-edit-api-nosequence"));
        deps.ids = Box::new(sq_core_time::RandomIds);
        let session = EditorSession::new(project, deps);
        let clock = Arc::new(sq_runtime::FakeClock::new());
        let mut app_deps = sq_app_shell::AppDeps::headless(clock);
        app_deps.import = ProjectPanelDeps {
            backend: Arc::new(FakeProbe),
            pool: Arc::new(sq_runtime::WorkerPool::threads(2)),
            ..ProjectPanelDeps::headless()
        };
        let mut api = Api::start_with("sq-edit-api-nosequence", sq_app_shell::Headless::new(session, app_deps, 800, 600));
        assert_eq!(api.state()["activeSequence"], serde_json::Value::Null);
        // Anything but createSequence has no sequence to act on.
        let (status, _) = api.call("POST", "/v1/commit", json!({"operations": [{"op": "addMarker", "at": t(1)}]}));
        assert_eq!(status, 404);
        let (status, made) = api.call(
            "POST",
            "/v1/commit",
            json!({"name": "First", "operations": [{"op": "createSequence", "name": "Reel", "width": 1080, "height": 1920, "fps": 30}]}),
        );
        assert_eq!(status, 200, "{made}");
        let seq = made["sequencesAdded"][0].as_str().expect("sequence").to_string();
        assert_eq!(made["sequence"].as_str(), Some(seq.as_str()));
        assert_eq!(api.state()["activeSequence"].as_str(), Some(seq.as_str()));
        // With a sequence open the id is required again.
        let (status, _) = api.call("POST", "/v1/commit", json!({"operations": [{"op": "addTrack", "kind": "audio"}]}));
        assert_eq!(status, 400);
        assert!(api.app.with(|a| a.session().undo_name().map(str::to_string)).flatten().is_some_and(|n| n == "Agent: First"));
        api.controller.stop();
    }

    /// Starts the API of `app` with a fake renderer (an orange picture) and returns (port, token, controller).
    fn start_api(app: &sq_app_shell::Headless, dir: &Path) -> (u16, String, EditApiController) {
        struct NoProbe;
        impl sq_editor_session::ImportBackend for NoProbe {
            fn probe(&self, _: &Path) -> Result<sq_core_model::MediaRef, sq_editor_session::ImportError> {
                Err(sq_editor_session::ImportError::UnsupportedCodec("test".into()))
            }
        }
        let sender = app.with(|a| a.sender()).expect("app");
        let mut c = EditApiController::new(sender, dir);
        c.set_perceive(crate::PerceiveBackend {
            render: Arc::new(|_, _, _, width| {
                let w = width.unwrap_or(640);
                let h = w * 9 / 16;
                Ok(sq_draw::RgbaImage { width: w, height: h, pixels: [255, 128, 0, 255].repeat(w * h) })
            }),
            probe: Arc::new(NoProbe),
        });
        let mut d = FileDefaults::default();
        let port = free_port();
        d.set_integer(ENABLED_KEY, 1);
        d.set_integer(PORT_KEY, i64::from(port));
        c.sync(&d);
        let v: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("edit-api.json")).expect("file")).expect("json");
        (port, v["token"].as_str().expect("token").to_string(), c)
    }



    #[test]
    fn capture_writes_a_png_of_the_asked_width_and_a_contact_sheet() {
        let dir = crate::test_rig::test_dir("sq-edit-api-capture");
        let app = app_with_one_clip();
        let (port, token, mut c) = start_api(&app, &dir);
        let body = r#"{"at":[{"value":1,"timescale":1}],"width":320,"contactSheet":{"from":{"value":0,"timescale":1},"to":{"value":8,"timescale":1},"count":6}}"#;
        let (status, text) = serve_while(&app, move || http(port, "POST", "/v1/capture", Some(&token), body));
        assert_eq!(status, 200, "{text}");
        let v: serde_json::Value = serde_json::from_str(&text).expect("json");
        let png_of = |p: &serde_json::Value| {
            sq_core_time::portable_png::decode(&std::fs::read(p.as_str().expect("path")).expect("file")).expect("png")
        };
        let frame = png_of(&v["frames"][0]["path"]);
        assert_eq!((frame.width, frame.height), (320, 180));
        assert!(frame.rgba.chunks(4).any(|p| p[0] > 200), "the picture is black");
        let sheet = png_of(&v["contactSheet"]["path"]);
        assert_eq!((sheet.width, sheet.height), (320 * 4, 180 * 2));
        assert_eq!(v["contactSheet"]["tiles"].as_array().map(Vec::len), Some(6));
        assert_eq!(v["contactSheet"]["tiles"][1]["timecode"], "00:00:01.600");
        c.stop();
    }

    #[test]
    fn levels_measure_loudness_and_find_the_silence() {
        if !sq_media_ffmpeg::shim::AVAILABLE {
            eprintln!("skipped: no linked FFmpeg shim");
            return;
        }
        let dir = crate::test_rig::test_dir("sq-edit-api-levels");
        std::fs::create_dir_all(&dir).expect("dir");
        // 2 s of 48 kHz mono 16-bit PCM: a 440 Hz tone for the first second, then silence.
        let samples: Vec<i16> = (0..96_000)
            .map(|i| if i < 48_000 { ((i as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin() * 16_000.0) as i16 } else { 0 })
            .collect();
        let mut wav = Vec::new();
        wav.extend(b"RIFF");
        wav.extend((36 + samples.len() as u32 * 2).to_le_bytes());
        wav.extend(b"WAVEfmt ");
        wav.extend(16_u32.to_le_bytes());
        wav.extend([1, 0, 1, 0]);
        wav.extend(48_000_u32.to_le_bytes());
        wav.extend(96_000_u32.to_le_bytes());
        wav.extend([2, 0, 16, 0]);
        wav.extend(b"data");
        wav.extend((samples.len() as u32 * 2).to_le_bytes());
        wav.extend(samples.iter().flat_map(|s| s.to_le_bytes()));
        let file = dir.join("tone.wav");
        std::fs::write(&file, wav).expect("wav");
        let app = app_with_clip_file(&file.to_string_lossy());
        let (port, token, mut c) = start_api(&app, &dir);
        let body = serde_json::json!({ "media": Id::from_u128(901) }).to_string();
        let (status, text) = serve_while(&app, move || http(port, "POST", "/v1/media/levels", Some(&token), &body));
        assert_eq!(status, 200, "{text}");
        let v: serde_json::Value = serde_json::from_str(&text).expect("json");
        assert!(v["integratedLufs"].is_number() && v["samplePeakDb"].as_f64().is_some_and(|p| p < 0.0 && p > -12.0), "{v}");
        let first = &v["silences"][0];
        let from = first["from"]["value"].as_f64().unwrap_or(0.0) / first["from"]["timescale"].as_f64().unwrap_or(1.0);
        assert!((0.9..=1.2).contains(&from), "{v}");
        c.stop();
    }

    /// Runs only when `SQ_REAL_PRPROJ` names a real Premiere project (a user's file copied into the build folder; never in the repo).
    #[test]
    fn a_real_premiere_project_imports_with_a_report() {
        let Some(file) = std::env::var_os("SQ_REAL_PRPROJ") else {
            eprintln!("skipped: SQ_REAL_PRPROJ not set");
            return;
        };
        let dir = crate::test_rig::test_dir("sq-edit-api-real");
        let app = app_with_one_clip();
        let (port, token, mut c) = start_api(&app, &dir);
        let body = serde_json::json!({ "path": file.to_string_lossy() }).to_string();
        let (status, text) = serve_while(&app, move || http(port, "POST", "/v1/importPremiere", Some(&token), &body));
        assert_eq!(status, 200, "{text}");
        let v: serde_json::Value = serde_json::from_str(&text).expect("json");
        println!("REAL-IMPORT {}", serde_json::to_string(&v["summary"]).unwrap_or_default());
        println!("REAL-IMPORT sequences {} mapped {} approximated {} dropped {}", v["sequences"], v["mapped"], v["approximated"], v["dropped"]);
        assert!(v["sequenceIds"].as_array().is_some_and(|s| !s.is_empty()), "{v}");
        c.stop();
    }

    #[test]
    fn import_premiere_adds_the_sequences_in_one_agent_step_and_reports() {
        let dir = crate::test_rig::test_dir("sq-edit-api-prproj");
        std::fs::create_dir_all(&dir).expect("dir");
        let s = 254_016_000_000_i64;
        let file = dir.join("Cut.prproj");
        std::fs::write(&file, format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<PremiereData Version=\"3\">\n\
<Media ObjectUID=\"M1\" Version=\"30\"><ActualMediaFilePath>/nowhere/a.mov</ActualMediaFilePath><FilePath>/nowhere/a.mov</FilePath><Title>a.mov</Title></Media>\n\
<VideoComponentChain ObjectID=\"2\"><ComponentChain><Components></Components></ComponentChain></VideoComponentChain>\n\
<VideoMediaSource ObjectID=\"3\"><MediaSource><Media ObjectURef=\"M1\"/></MediaSource></VideoMediaSource>\n\
<VideoClip ObjectID=\"4\"><Clip><Source ObjectRef=\"3\"/><InPoint>0</InPoint><OutPoint>{o}</OutPoint></Clip></VideoClip>\n\
<SubClip ObjectID=\"5\"><Clip ObjectRef=\"4\"/><Name>a</Name></SubClip>\n\
<VideoClipTrackItem ObjectID=\"6\"><ClipTrackItem><ComponentOwner><Components ObjectRef=\"2\"/></ComponentOwner><TrackItem><Node/><Start>0</Start><End>{o}</End></TrackItem><SubClip ObjectRef=\"5\"/></ClipTrackItem></VideoClipTrackItem>\n\
<VideoClipTrack ObjectUID=\"T1\"><ClipTrack><Track><ID>1</ID></Track><ClipItems><TrackItems><TrackItem Index=\"0\" ObjectRef=\"6\"/></TrackItems></ClipItems><TransitionItems><TrackItems></TrackItems></TransitionItems></ClipTrack></VideoClipTrack>\n\
<VideoTrackGroup ObjectID=\"7\"><TrackGroup><Tracks><Track Index=\"0\" ObjectURef=\"T1\"/></Tracks><FrameRate>8467200000</FrameRate></TrackGroup><FrameRect>0,0,1920,1080</FrameRect></VideoTrackGroup>\n\
<AudioTrackGroup ObjectID=\"8\"><TrackGroup><Tracks></Tracks><FrameRate>5292000</FrameRate></TrackGroup></AudioTrackGroup>\n\
<Sequence ObjectUID=\"S1\"><Name>Main</Name><TrackGroups><TrackGroup Index=\"0\"><First>a</First><Second ObjectRef=\"7\"/></TrackGroup><TrackGroup Index=\"1\"><First>b</First><Second ObjectRef=\"8\"/></TrackGroup></TrackGroups></Sequence>\n\
</PremiereData>\n", o = 5 * s)).expect("prproj");
        let app = app_with_one_clip();
        let (port, token, mut c) = start_api(&app, &dir);
        let count = |a: &sq_app_shell::Headless| a.with(|a| a.session().project().timelines.len()).unwrap_or(0);
        let before = count(&app);
        let body = serde_json::json!({ "path": file }).to_string();
        let dry = serde_json::json!({ "path": file, "dryRun": true }).to_string();
        let t = token.clone();
        let (status, _) = serve_while(&app, move || http(port, "POST", "/v1/importPremiere", Some(&t), &dry));
        assert_eq!((status, count(&app)), (200, before), "a dry run changes nothing");
        let (status, text) = serve_while(&app, move || http(port, "POST", "/v1/importPremiere", Some(&token), &body));
        assert_eq!(status, 200, "{text}");
        let v: serde_json::Value = serde_json::from_str(&text).expect("json");
        assert_eq!(v["sequences"][0]["name"], "Main");
        assert_eq!(v["sequenceIds"].as_array().map(Vec::len), Some(1));
        assert!(v["report"].as_array().is_some_and(|r| !r.is_empty()), "{v}");
        assert_eq!(count(&app), before + 1);
        let name = app.with(|a| a.session().undo_name().map(str::to_string)).flatten();
        assert_eq!(name.as_deref(), Some("Agent: Import Premiere"));
        c.stop();
    }

    #[test]
    fn every_kind_of_job_shares_one_id_space_and_one_answer_shape() {
        let mut jobs = Jobs::default();
        let slot: TaskSlot = Arc::new(Mutex::new(TaskState::Running));
        let a = jobs.add("transcript", JobEntry::Task { kind: "transcript", slot });
        let b = jobs.add("export", JobEntry::Export(Vec::new()));
        assert_eq!((a.as_str(), b.as_str()), ("transcript-1", "export-2"));
        let running = serde_json::to_value(task_info(&a, "transcript", &TaskState::Running)).expect("json");
        assert_eq!(running, json!({"id": "transcript-1", "kind": "transcript", "state": "running", "progress": 0.0}));
        let done = serde_json::to_value(task_info("import-3", "import", &TaskState::Done(json!({"media": []})))).expect("json");
        assert_eq!(done["state"], "done");
        assert_eq!(done["result"], json!({"media": []}));
        let failed = serde_json::to_value(task_info("captions-4", "captions", &TaskState::Failed("no speech".into()))).expect("json");
        assert_eq!((failed["state"].as_str(), failed["error"].as_str()), (Some("failed"), Some("no speech")));
    }
}
