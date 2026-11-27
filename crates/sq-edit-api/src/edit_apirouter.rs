// Swift: EditAPIRouter.swift
//! Routes and guards requests; pure apart from the host calls, so every security rule is unit-tested.

use crate::edit_diff::EditDiff;
use crate::edit_operation::{EditOperation, check_strict_keys, optional, required};
use crate::edit_transaction::{EditTransaction, HostCommit, TransactionError, TransactionErrorKind};
use crate::http::{HTTPRequest, HTTPResponse, is_blank};
use crate::perceive::{PerceiveError, PerceiveRequest};
use crate::project_state::ProjectState;
use crate::time_limits::{TimeLimits, WireTime};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use sq_core_model::{EditError, Project};
use sq_core_time::text::graphemes;
use sq_core_time::{Id, Time};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The app side of the API: the live project and ONE place that commits (EditorSession in the app). Methods are called
/// from connection threads, so a host serializes access itself (a lock or a message to its owner thread).
pub trait EditAPIHost: Send + Sync {
    /// The live project; None when none is open.
    fn project(&self) -> Option<Project>;
    /// The sequence shown in the timeline panel.
    fn active_sequence(&self) -> Option<Id>;
    /// On the host's own thread: `request.admit(...)` first, then (dry run) the result `perform` would produce on a copy,
    /// or (commit) applies the operations as ONE undo step named `request.name` via `EditTransaction::apply` inside the
    /// session's commit. Fails and changes nothing when anything fails. Returns the project before and after.
    fn run(&self, request: &HostCommit, cancel: &AtomicBool) -> Result<(Project, Project), TransactionError>;
    /// Undoes the top step only when `accept(its undo name)` holds, checked and undone in one step on the host's thread.
    fn undo(&self, accept: &dyn Fn(&str) -> bool) -> bool;
    /// The perceive family (capture, frames, transcript, levels, captions, Premiere import). Hosts that cannot answer
    /// say 501. Runs on the connection's thread; it may block for a while but must watch `cancel`. Long work answers as a
    /// job of `job`.
    fn perceive(&self, _request: &PerceiveRequest, _cancel: &AtomicBool) -> Result<Value, PerceiveError> {
        Err(PerceiveError::new(501, "not supported by this host"))
    }
    /// Redoes the next step only when `accept(its undo name)` holds (an agent never redoes the user's own step).
    fn redo(&self, _accept: &dyn Fn(&str) -> bool) -> bool {
        false
    }
    /// The playhead of the open sequence.
    fn playhead(&self) -> Option<Time> {
        None
    }
    /// The project file and whether it has unsaved changes.
    fn document(&self) -> Option<DocumentInfo> {
        None
    }
    /// Imports files the way a drop on the window does (absolute paths) and says per path which media item it became.
    fn import(&self, _paths: Vec<String>, _cancel: &AtomicBool) -> Result<Vec<ImportedMedia>, HostError> {
        Err(HostError::unsupported())
    }
    /// Saves the open project (`path` None) or saves it as `path` (a `.sqproj`); returns the file written.
    /// Saves the project (to `path` when given: like Save As, the project is bound to that file from then on). An existing
    /// file other than the project's own is only replaced with `overwrite`.
    fn save(&self, _path: Option<String>, _overwrite: bool) -> Result<String, HostError> {
        Err(HostError::unsupported())
    }
    /// Opens the project file at `path`. Refused (409) while the open project has unsaved changes unless `discard`.
    fn open(&self, _path: String, _discard: bool) -> Result<(), HostError> {
        Err(HostError::unsupported())
    }
    /// Moves the playhead of the open sequence (frame-snapped); returns where it went.
    fn seek(&self, _at: Time) -> Result<Time, HostError> {
        Err(HostError::unsupported())
    }

    /// Starts an export like the Export sheet's button and returns the job id at once.
    fn export(&self, _request: ExportRequest) -> Result<String, HostError> {
        Err(HostError::unsupported())
    }

    /// The state of a long job (export, or an import that took longer than the request deadline).
    fn job(&self, _id: &str) -> Option<JobInfo> {
        None
    }

    /// The export presets the app offers.
    fn presets(&self) -> Vec<PresetInfo> {
        Vec::new()
    }

    /// The effect presets the user saved or imported (Library > Presets), decoded; `applyPreset` takes them by id or name.
    fn user_effect_presets(&self) -> Vec<crate::transition_ops::UserEffectPreset> {
        Vec::new()
    }

    /// The title templates of the Library (Library > Titles), with their editable fields.
    fn templates(&self) -> Vec<crate::template_ops::TemplateInfo> {
        Vec::new()
    }

    /// One title template by Library id or name (case-insensitive; an id wins), decoded; `insertTemplate` places it.
    fn template(&self, _id_or_name: &str) -> Option<sq_core_model::TitleTemplate> {
        None
    }

    /// Saves the video clips `clips` of the open sequence as a title template named `name` in Library folder `folder`
    /// ("/" path); returns the new Library item id.
    fn save_template(&self, _clips: Vec<Id>, _name: String, _folder: Option<String>) -> Result<Id, HostError> {
        Err(HostError::unsupported())
    }
}

/// Which part of the sequence an export writes.
#[derive(Clone, Debug, PartialEq)]
pub enum ExportRange {
    /// The whole sequence.
    Entire,
    /// The sequence's In to Out marks.
    InOut,
    /// From `start` to `end` (sequence time).
    Custom { start: Time, end: Time },
}

/// `POST /v1/export`, already checked for shape.
#[derive(Clone, Debug, PartialEq)]
pub struct ExportRequest {
    /// The sequence (None = the open one).
    pub sequence: Option<Id>,
    /// The file to write: absolute, with the extension of the preset's container.
    pub path: String,
    /// A preset id of `GET /v1/presets` (None = what the Export sheet would propose).
    pub preset: Option<String>,
    /// The part to export.
    pub range: ExportRange,
}

/// State of a long job.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum JobState {
    /// Waiting for its turn.
    Queued,
    /// Working.
    Running,
    /// Finished; `result` holds the answer.
    Done,
    /// Failed or canceled; `error` says why.
    Failed,
}

/// One long job as `GET /v1/jobs/{id}` answers; the same shape for every kind of job.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct JobInfo {
    /// The id (`export-1`, `import-2`, `transcript-3`, `captions-4`).
    pub id: String,
    /// "export", "import", "transcript" or "captions".
    pub kind: &'static str,
    /// State.
    pub state: JobState,
    /// 0...1.
    pub progress: f64,
    /// What the job made once it is done: export `{"output": path}`, import `{"media": [...]}`, transcript and captions
    /// the same JSON their request answers with when it finishes at once.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// Why a job failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// An export preset.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PresetInfo {
    /// Stable id.
    pub id: String,
    /// Menu name.
    pub name: String,
}

/// The open project file and its save state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentInfo {
    /// The file the project was opened from or last saved to.
    pub path: Option<String>,
    /// Unsaved changes.
    pub dirty: bool,
}

/// What one imported path became.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ImportedMedia {
    /// The path as asked for.
    pub path: String,
    /// The media item (new, or the one the project already had for that file); None when the file was not imported.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media: Option<Id>,
    /// Why not.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// A refused request of the host, with the HTTP status it maps to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostError {
    /// HTTP status.
    pub status: u16,
    /// Text for the agent.
    pub message: String,
    /// A job the work goes on as (status 202): read `GET /v1/jobs/{id}`.
    pub job: Option<String>,
}

impl HostError {
    /// An error with `status`.
    pub fn new(status: u16, message: impl Into<String>) -> HostError {
        HostError { status, message: message.into(), job: None }
    }

    /// 202: the work did not finish within the request deadline and goes on as job `id`.
    pub fn running_as(id: String, message: impl Into<String>) -> HostError {
        HostError { status: 202, message: message.into(), job: Some(id) }
    }

    fn unsupported() -> HostError {
        HostError::new(501, "this host does not support the request")
    }
}

/// Listener settings and request limits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditAPIConfig {
    /// Bearer token.
    pub token: String,
    /// Loopback port.
    pub port: u16,
    /// Largest body accepted.
    pub max_body_bytes: usize,
    /// Most operations per commit.
    pub max_operations: usize,
}

impl EditAPIConfig {
    /// A config with the default limits (1 MiB body, 1000 operations).
    pub fn new(token: String, port: u16) -> EditAPIConfig {
        EditAPIConfig { token, port, max_body_bytes: 1 << 20, max_operations: 1000 }
    }

    /// 32 random bytes, hex. A new one every launch. `random_byte` must be a cryptographically secure source (the OS
    /// generator); logic code never creates randomness itself.
    pub fn make_token(random_byte: &mut dyn FnMut() -> u8) -> String {
        (0..32).map(|_| format!("{:02x}", random_byte())).collect()
    }
}

/// `POST /v1/commit` body.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitRequest {
    /// The sequence the agent read (`activeSequence` of `/v1/state`). Required: the commit is refused (409) when it is no
    /// longer the active sequence, so a sequence switch in between never redirects the edit. Only a project with no
    /// open sequence takes a commit without it (the first `createSequence`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sequence: Option<Id>,
    /// Undo name after "Agent: "; None = "Agent Edit".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Only preview.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dry_run: Option<bool>,
    /// The batch.
    pub operations: Vec<EditOperation>,
}

impl<'de> Deserialize<'de> for CommitRequest {
    /// Strict: a misspelled `dryRun` must not turn a preview into a commit.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let map = Map::<String, Value>::deserialize(d)?;
        let build = || -> Result<CommitRequest, String> {
            check_strict_keys(&map, &["sequence", "name", "dryRun", "operations"], "commit request")?;
            Ok(CommitRequest {
                sequence: optional(&map, "sequence")?,
                name: optional(&map, "name")?,
                dry_run: optional(&map, "dryRun")?,
                operations: required(&map, "operations")?,
            })
        };
        build().map_err(serde::de::Error::custom)
    }
}

/// `POST /v1/commit` answer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResponse {
    /// Whether anything was changed (false for a dry run or a no-op).
    pub applied: bool,
    /// The sequence that was edited.
    pub sequence: Id,
    /// Undo name of the step.
    pub undo_name: String,
    /// What changed in `sequence`.
    pub diff: EditDiff,
    /// Sequences the batch created.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sequences_added: Vec<Id>,
    /// Clips the batch created in `sequence`, in track order: the combined clip (video clip first, then its linked sound
    /// clip) of `combine`, the restored clips of `uncombine`. Absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub clips_added: Vec<Id>,
    /// Folders the batch created (`createFolder`). Absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub folders_added: Vec<Id>,
    /// The open sequence after the batch, when it is not `sequence`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_sequence: Option<Id>,
    /// Gaps between clips this batch opened (`GET /v1/gaps` lists all of them); absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub gaps_opened: Vec<crate::gaps::Gap>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct UndoRequest {
    expected_name: Option<String>,
}

/// Routes and guards requests. Pure apart from the host calls, so every security rule is unit-tested.
///
/// - `GET  /v1/state`   project read model (`ProjectState`)
/// - `GET  /v1/clip/{id}/params`  every inspector parameter, effect and text layer of a clip
/// - `GET  /v1/gaps?sequence=` every gap between clips (also under one frame) and every black stretch
/// - `GET  /v1/effects` the Effects panel catalog (video and audio)
/// - `GET  /v1/transitions` every transition kind; `GET /v1/effectPresets` the built-in effect presets
/// - `GET  /v1/textAnimators` the effects, units, orders and ranges the text animator ops accept
/// - `POST /v1/commit`  `CommitRequest` -> `CommitResponse`; `dryRun` returns the diff without changing anything
/// - `POST /v1/undo`    undoes the last step only if it is an "Agent: ..." step (`{"expectedName"?: "Agent: X"}`)
pub struct EditAPIRouter {
    /// Listener settings and limits.
    pub config: EditAPIConfig,
    /// The app side.
    pub host: Arc<dyn EditAPIHost>,
}

impl EditAPIRouter {
    /// A router over `host`.
    pub fn new(config: EditAPIConfig, host: Arc<dyn EditAPIHost>) -> EditAPIRouter {
        EditAPIRouter { config, host }
    }

    /// Answers one request; `cancel` is set when the connection's deadline passes or the peer is gone.
    pub fn handle(&self, r: &HTTPRequest, cancel: &AtomicBool) -> HTTPResponse {
        if let Some(refused) = self.guard_request(r) {
            return refused;
        }
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/v1/state") => {
                let Some(p) = self.host.project() else { return HTTPResponse::error(503, "no project open", None) };
                let mut s = ProjectState::new(&p);
                if let Some(a) = self.host.active_sequence() {
                    s.active_sequence = Some(a);
                }
                s.playhead = self.host.playhead();
                if let Some(d) = self.host.document() {
                    s.file = d.path;
                    s.dirty = Some(d.dirty);
                }
                HTTPResponse::json(200, &s)
            }
            ("GET", "/v1/gaps") => self.gaps(&r.query),
            ("GET", "/v1/textAnimators") => HTTPResponse::json(200, &crate::text_animators::catalog_json()),
            ("GET", "/v1/transitions") => HTTPResponse::json(200, &crate::transition_ops::transitions_json()),
            ("GET", "/v1/effectPresets") => {
                HTTPResponse::json(200, &crate::transition_ops::presets_json(&self.host.user_effect_presets()))
            }
            ("GET", "/v1/templates") => {
                HTTPResponse::json(200, &crate::template_ops::templates_json(&self.host.templates()))
            }
            ("POST", "/v1/templates") => self.save_template(&r.body),
            ("GET", "/v1/effects") => HTTPResponse::json(200, &crate::clip_params::effects_catalog_json()),
            ("GET", p) if p.starts_with("/v1/clip/") => self.clip_params(p),
            ("POST", "/v1/commit") => self.commit(&r.body, cancel),
            ("POST", "/v1/undo") => self.undo(&r.body),
            ("POST", "/v1/redo") => self.redo(&r.body),
            ("POST", "/v1/import") => self.import(&r.body, cancel),
            ("POST", "/v1/export") => self.export(&r.body),
            ("GET", "/v1/presets") => HTTPResponse::json(200, &serde_json::json!({ "presets": self.host.presets() })),
            ("GET", p) if p.starts_with("/v1/jobs/") => match self.host.job(&p["/v1/jobs/".len()..]) {
                Some(info) => HTTPResponse::json(200, &info),
                None => HTTPResponse::error(404, "no such job", None),
            },
            ("POST", "/v1/save") => self.save(&r.body),
            ("POST", "/v1/open") => self.open(&r.body),
            ("POST", "/v1/playhead") => self.playhead(&r.body),
            ("GET", "/v1/captionStyles") => self.perceive(Ok(PerceiveRequest::CaptionStyles), cancel),
            ("GET", "/v1/fonts") => self.perceive(Ok(PerceiveRequest::Fonts), cancel),
            ("POST", p) if PerceiveRequest::POST_PATHS.contains(&p) => {
                self.perceive(PerceiveRequest::parse(p, &r.body), cancel)
            }
            (_, p) if PerceiveRequest::POST_PATHS.contains(&p) || p == "/v1/captionStyles" || p == "/v1/fonts" => {
                HTTPResponse::error(405, "method not allowed", None)
            }
            (
                _,
                "/v1/state" | "/v1/commit" | "/v1/undo" | "/v1/redo" | "/v1/import" | "/v1/export" | "/v1/presets"
                | "/v1/save" | "/v1/open" | "/v1/playhead" | "/v1/effects" | "/v1/textAnimators" | "/v1/transitions"
                | "/v1/effectPresets" | "/v1/gaps" | "/v1/templates",
            ) => HTTPResponse::error(405, "method not allowed", None),
            _ => HTTPResponse::error(404, "unknown endpoint", None),
        }
    }

    fn perceive(&self, parsed: Result<PerceiveRequest, String>, cancel: &AtomicBool) -> HTTPResponse {
        let request = match parsed {
            Ok(r) => r,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        match self.host.perceive(&request, cancel) {
            Ok(v) => HTTPResponse::json(200, &v),
            Err(e) => HTTPResponse::error(e.status, &e.message, None),
        }
    }

    /// Host must name the loopback listener (DNS rebinding), a browser Origin must be loopback too, and the bearer token
    /// must match (constant-time compare).
    /// `GET /v1/clip/{id}/params`: every inspector parameter, effect and layer of the clip.
    /// `GET /v1/gaps?sequence=<id>` (default: the open sequence).
    fn gaps(&self, query: &str) -> HTTPResponse {
        let Some(p) = self.host.project() else { return HTTPResponse::error(503, "no project open", None) };
        let asked = query.split('&').find_map(|kv| kv.strip_prefix("sequence="));
        let id = match asked {
            Some(v) => match Id::parse(v) {
                Some(id) => Some(id),
                None => return HTTPResponse::error(400, "sequence: not an id", None),
            },
            None => self.host.active_sequence(),
        };
        match id.and_then(|i| p.timeline(i)) {
            Some(t) => HTTPResponse::json(200, &crate::gaps::find(t)),
            None => HTTPResponse::error(404, "no such sequence", None),
        }
    }

    fn clip_params(&self, path: &str) -> HTTPResponse {
        let id = path.strip_prefix("/v1/clip/").and_then(|r| r.strip_suffix("/params")).and_then(Id::parse);
        let Some(id) = id else { return HTTPResponse::error(404, "unknown endpoint", None) };
        let Some(p) = self.host.project() else { return HTTPResponse::error(503, "no project open", None) };
        let found = p.timelines.iter().flat_map(|t| t.tracks.iter()).find_map(|tr| tr.clip(id));
        match found {
            Some(c) => HTTPResponse::json(200, &crate::clip_params::clip_params_json(c)),
            None => HTTPResponse::error(404, "no such clip", None),
        }
    }

    fn guard_request(&self, r: &HTTPRequest) -> Option<HTTPResponse> {
        let port = self.config.port;
        let loopback = [format!("127.0.0.1:{port}"), format!("localhost:{port}")];
        let host = r.headers.get("host").map(|h| h.to_lowercase());
        if !host.is_some_and(|h| loopback.contains(&h)) {
            return Some(HTTPResponse::error(403, "bad host", None));
        }
        if let Some(origin) = r.headers.get("origin").map(|o| o.to_lowercase())
            && !loopback.iter().any(|l| format!("http://{l}") == origin)
        {
            return Some(HTTPResponse::error(403, "cross-origin requests are refused", None));
        }
        let bearer = r.headers.get("authorization").and_then(|a| a.strip_prefix("Bearer "));
        if !bearer.is_some_and(|t| Self::constant_time_equal(t, &self.config.token)) {
            return Some(HTTPResponse::error(401, "missing or wrong token", None));
        }
        if r.body.len() > self.config.max_body_bytes {
            return Some(HTTPResponse::error(413, "body too large", None));
        }
        None
    }

    pub(crate) fn constant_time_equal(a: &str, b: &str) -> bool {
        let (x, y) = (a.as_bytes(), b.as_bytes());
        if x.len() != y.len() {
            return false;
        }
        x.iter().zip(y).fold(0_u8, |d, (p, q)| d | (p ^ q)) == 0
    }

    fn commit(&self, body: &[u8], cancel: &AtomicBool) -> HTTPResponse {
        let req: CommitRequest = match serde_json::from_slice(body) {
            Ok(r) => r,
            Err(e) => return HTTPResponse::error(400, &format!("invalid request: {e}"), None),
        };
        if req.operations.is_empty() {
            return HTTPResponse::error(400, "operations is empty", None);
        }
        let max = self.config.max_operations;
        if req.operations.len() > max {
            return HTTPResponse::error(413, &format!("more than {max} operations"), None);
        }
        let label = req
            .name
            .as_deref()
            .map(|n| n.trim_matches(|c: char| is_blank(c) || matches!(c as u32, 0x0A..=0x0D | 0x85 | 0x2028 | 0x2029)))
            .filter(|n| !n.is_empty())
            .map(|n| graphemes(n).take(80).collect::<String>());
        if req.sequence.is_none() && self.host.active_sequence().is_some() {
            return HTTPResponse::error(
                400,
                "sequence is required while a sequence is open (see activeSequence of /v1/state)",
                None,
            );
        }
        let only_zoom_cuts =
            !req.operations.is_empty() && req.operations.iter().all(|o| matches!(o, EditOperation::AddZoomCut(_)));
        let undo_name = format!(
            "Agent: {}",
            label.as_deref().unwrap_or(if only_zoom_cuts { zoom_label(&req.operations) } else { "Edit" })
        );
        let dry = req.dry_run == Some(true);
        match self.run_commit(&req, &undo_name, dry, cancel) {
            Ok(response) => response,
            Err(e) => HTTPResponse::error(Self::status(&e), &e.message(), e.operation_index),
        }
    }

    fn run_commit(
        &self,
        req: &CommitRequest,
        undo_name: &str,
        dry: bool,
        cancel: &AtomicBool,
    ) -> Result<HTTPResponse, TransactionError> {
        let seq = match req.sequence {
            Some(s) => s,
            None if self.host.active_sequence().is_none() => HostCommit::NO_SEQUENCE,
            None => return Err(TransactionError::new(TransactionErrorKind::SequenceChanged)),
        };
        EditTransaction::validate(&req.operations)?; // before any Time arithmetic, dry run included
        if cancel.load(Ordering::SeqCst) {
            return Err(TransactionError::new(TransactionErrorKind::Cancelled));
        }
        let mut operations = req.operations.clone();
        if operations.iter().any(|o| matches!(o, EditOperation::ApplyPreset { .. })) {
            operations = crate::transition_ops::resolve_user_presets(operations, &self.host.user_effect_presets())
                .map_err(|why| TransactionError::invalid(&why))?;
        }
        for (i, op) in operations.iter_mut().enumerate() {
            let EditOperation::InsertTemplate { template, fields, resolved, .. } = op else { continue };
            let Some(found) = self.host.template(template) else {
                let why = format!("no such template '{template}' (GET /v1/templates lists the ids and names)");
                return Ok(HTTPResponse::error(404, &why, Some(i)));
            };
            match crate::template_ops::parse_fields(&found, fields) {
                Ok(values) => {
                    *resolved = Some(Box::new(crate::template_ops::ResolvedTemplate { template: found, values }))
                }
                Err(why) => return Ok(HTTPResponse::error(400, &why, Some(i))),
            }
        }
        let commit = HostCommit { name: undo_name.to_string(), sequence: seq, operations, dry_run: dry };
        let active_before = self.host.active_sequence();
        let (before, after) = self.host.run(&commit, cancel)?;
        // A commit without a sequence created the first one: it is the open one now, and the "before" is empty.
        let seq = if seq == HostCommit::NO_SEQUENCE {
            self.host.active_sequence().or_else(|| after.timelines.last().map(|t| t.id)).unwrap_or(seq)
        } else {
            seq
        };
        // deleteSequence of the sequence the batch ran on: the reply names the sequence that is open now (no clip diff).
        let seq = if after.timeline(seq).is_none()
            && req.operations.iter().any(|o| matches!(o, EditOperation::DeleteSequence { .. }))
        {
            self.host.active_sequence().filter(|a| after.timeline(*a).is_some()).unwrap_or(seq)
        } else {
            seq
        };
        let Some(a) = after.timeline(seq) else {
            return Ok(HTTPResponse::error(409, "sequence vanished", None));
        };
        let empty;
        let b = match before.timeline(seq) {
            Some(b) => b,
            None if !dry => {
                let mut e = a.clone();
                e.tracks.iter_mut().for_each(|t| *t = sq_core_model::Track::new(t.id, t.kind));
                empty = e;
                &empty
            }
            None => return Ok(HTTPResponse::error(409, "sequence vanished", None)),
        };
        let gaps_opened = crate::gaps::opened(b, a);
        let mut diff = EditDiff::new(b, a);
        diff.note_media(&before, &after);
        // A dry run does not move the open sequence, a real setActiveSequence does (the project itself stays equal).
        let changed = !diff.is_empty() || before != after || (!dry && self.host.active_sequence() != active_before);
        if !changed {
            // Never a silent 200: an agent that sees `applied: false` cannot tell "nothing to do" from "did not work".
            return Err(TransactionError::invalid(
                "nothing changed: the operations left the sequence as it was (already in that state, or a trim the neighbors and the media allow no room for)",
            ));
        }
        let applied = !dry;
        let sequences_added: Vec<Id> =
            after.timelines.iter().map(|t| t.id).filter(|id| before.timeline(*id).is_none()).collect();
        // After createSequence the new sequence is the open one: it is what the reply names (the diff stays the one of
        // the sequence the batch ran on).
        let clips_added: Vec<Id> = {
            let ids = |t: &sq_core_model::Timeline| -> Vec<Id> {
                t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect()
            };
            let old = ids(b);
            ids(a).into_iter().filter(|id| !old.contains(id)).collect()
        };
        let folders_added: Vec<Id> = {
            let old = before.root_bin.all_refs();
            after
                .root_bin
                .all_refs()
                .into_iter()
                .filter(|r| !old.contains(r))
                .filter_map(|r| match r {
                    sq_core_model::BinItemRef::Bin(id) => Some(id),
                    _ => None,
                })
                .collect()
        };
        let active_now = self.host.active_sequence();
        let active_sequence = active_now.filter(|a| *a != seq);
        let seq = active_now.filter(|a| !dry && sequences_added.contains(a)).unwrap_or(seq);
        Ok(HTTPResponse::json(
            200,
            &CommitResponse {
                applied,
                sequence: seq,
                undo_name: undo_name.to_string(),
                diff,
                sequences_added,
                clips_added,
                folders_added,
                active_sequence,
                gaps_opened,
            },
        ))
    }

    pub(crate) fn status(e: &TransactionError) -> u16 {
        match e.kind {
            TransactionErrorKind::Edit(EditError::TimelineNotFound) if e.operation_index.is_none() => 404,
            TransactionErrorKind::Edit(_)
            | TransactionErrorKind::Invalid
            | TransactionErrorKind::MediaNotFound
            | TransactionErrorKind::NoPicture
            | TransactionErrorKind::TrackNotFound
            | TransactionErrorKind::InvalidValue(_)
            | TransactionErrorKind::NeedsSession => 422,
            TransactionErrorKind::InvalidTime => 400,
            TransactionErrorKind::Busy | TransactionErrorKind::SequenceChanged => 409,
            TransactionErrorKind::Cancelled => 503,
        }
    }

    /// Parses a strict JSON object body (`{}` when empty).
    fn object(body: &[u8], allowed: &[&str], what: &str) -> Result<Map<String, Value>, HTTPResponse> {
        let value: Value = if body.is_empty() {
            Value::Object(Map::new())
        } else {
            serde_json::from_slice(body)
                .map_err(|e| HTTPResponse::error(400, &format!("invalid request: {e}"), None))?
        };
        let Value::Object(map) = value else {
            return Err(HTTPResponse::error(400, "invalid request: expected a JSON object", None));
        };
        check_strict_keys(&map, allowed, what).map_err(|e| HTTPResponse::error(400, &e, None))?;
        Ok(map)
    }

    /// A path from a request: absolute, no control characters; `extension` (a project file) when given.
    fn checked_path(path: &str, extension: Option<&str>) -> Result<(), HTTPResponse> {
        let bad = |why: &str| Err(HTTPResponse::error(400, &format!("path '{path}': {why}"), None));
        if path.is_empty() || path.chars().any(char::is_control) {
            return bad("empty or has control characters");
        }
        if !std::path::Path::new(path).is_absolute() {
            return bad("must be absolute");
        }
        if std::path::Path::new(path).components().any(|c| matches!(c, std::path::Component::ParentDir)) {
            return bad("must not contain '..'");
        }
        if let Some(ext) = extension {
            let ok = std::path::Path::new(path).extension().is_some_and(|e| e.eq_ignore_ascii_case(ext));
            if !ok {
                return bad(&format!("must end in .{ext}"));
            }
        }
        Ok(())
    }

    fn host_error(e: &HostError) -> HTTPResponse {
        match &e.job {
            Some(job) => HTTPResponse::json(e.status, &serde_json::json!({ "job": job, "message": e.message })),
            None => HTTPResponse::error(e.status, &e.message, None),
        }
    }

    /// `POST /v1/export {sequence?, path, preset?, range?}`: starts the export, answers `{job}` at once.
    fn export(&self, body: &[u8]) -> HTTPResponse {
        let map = match Self::object(body, &["sequence", "path", "preset", "range"], "export request") {
            Ok(m) => m,
            Err(e) => return e,
        };
        let parsed = (|| -> Result<ExportRequest, String> {
            let range = match map.get("range") {
                None | Some(Value::Null) => ExportRange::Entire,
                Some(Value::String(s)) if s == "entire" => ExportRange::Entire,
                Some(Value::String(s)) if s == "inOut" => ExportRange::InOut,
                Some(Value::Object(m)) => {
                    check_strict_keys(m, &["start", "end"], "range")?;
                    let (start, end) = (required::<WireTime>(m, "start")?.time, required::<WireTime>(m, "end")?.time);
                    if !TimeLimits::is_valid_time(start) || !TimeLimits::is_valid_time(end) {
                        return Err(TimeLimits::message());
                    }
                    if end <= start {
                        return Err("range: end must be after start".into());
                    }
                    ExportRange::Custom { start, end }
                }
                Some(_) => return Err("range: use \"entire\", \"inOut\" or {start, end}".into()),
            };
            Ok(ExportRequest {
                sequence: optional(&map, "sequence")?,
                path: required(&map, "path")?,
                preset: optional(&map, "preset")?,
                range,
            })
        })();
        let request = match parsed {
            Ok(r) => r,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        if let Err(e) = Self::checked_path(&request.path, None) {
            return e;
        }
        match self.host.export(request) {
            Ok(job) => HTTPResponse::json(200, &serde_json::json!({ "job": job })),
            Err(e) => Self::host_error(&e),
        }
    }

    /// `POST /v1/redo`: redoes the next step only when it is an "Agent: ..." step.
    fn redo(&self, body: &[u8]) -> HTTPResponse {
        let parsed = Self::object(body, &["expectedName"], "redo request");
        let map = match parsed {
            Ok(m) => m,
            Err(e) => return e,
        };
        let expected = match optional::<String>(&map, "expectedName") {
            Ok(v) => v,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        let ok = self.host.redo(&|name| name.starts_with("Agent: ") && expected.as_deref().is_none_or(|e| name == e));
        if ok {
            HTTPResponse::json(200, &serde_json::json!({"redone": true}))
        } else {
            HTTPResponse::error(409, "the next step is not this agent's edit (or there is nothing to redo)", None)
        }
    }

    /// `POST /v1/import {paths}`: the media become project items, as after a drop on the window.
    fn import(&self, body: &[u8], cancel: &AtomicBool) -> HTTPResponse {
        let map = match Self::object(body, &["paths"], "import request") {
            Ok(m) => m,
            Err(e) => return e,
        };
        let paths = match required::<Vec<String>>(&map, "paths") {
            Ok(p) if !p.is_empty() && p.len() <= 1000 => p,
            Ok(_) => return HTTPResponse::error(400, "paths: give 1 to 1000 files", None),
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        for p in &paths {
            if let Err(e) = Self::checked_path(p, None) {
                return e;
            }
        }
        match self.host.import(paths, cancel) {
            Ok(media) => HTTPResponse::json(200, &serde_json::json!({ "media": media })),
            Err(e) => Self::host_error(&e),
        }
    }

    /// `POST /v1/save {path?, overwrite?}`: save the open project, or save it as `path` (like Save As: the project is bound
    /// to that file afterwards). A `path` that exists and is not the project's own file needs `overwrite: true`.
    fn save(&self, body: &[u8]) -> HTTPResponse {
        let map = match Self::object(body, &["path", "overwrite"], "save request") {
            Ok(m) => m,
            Err(e) => return e,
        };
        let path = match optional::<String>(&map, "path") {
            Ok(p) => p,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        if let Some(p) = &path
            && let Err(e) = Self::checked_path(p, Some("sqproj"))
        {
            return e;
        }
        let overwrite = match optional::<bool>(&map, "overwrite") {
            Ok(o) => o.unwrap_or(false),
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        match self.host.save(path, overwrite) {
            Ok(written) => HTTPResponse::json(200, &serde_json::json!({ "saved": written })),
            Err(e) => Self::host_error(&e),
        }
    }

    /// `POST /v1/open {path, discard?}`: opens a `.sqproj`; unsaved changes need `discard: true`.
    fn open(&self, body: &[u8]) -> HTTPResponse {
        let map = match Self::object(body, &["path", "discard"], "open request") {
            Ok(m) => m,
            Err(e) => return e,
        };
        let path = match required::<String>(&map, "path") {
            Ok(p) => p,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        let discard = match optional::<bool>(&map, "discard") {
            Ok(d) => d.unwrap_or(false),
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        if let Err(e) = Self::checked_path(&path, Some("sqproj")) {
            return e;
        }
        match self.host.open(path, discard) {
            Ok(()) => HTTPResponse::json(200, &serde_json::json!({ "opened": true })),
            Err(e) => Self::host_error(&e),
        }
    }

    /// `POST /v1/playhead {at}`: moves the playhead.
    /// `POST /v1/templates {clips, name, folder?}`: the Save as Template command on `clips`; answers `{id}`.
    fn save_template(&self, body: &[u8]) -> HTTPResponse {
        let map = match Self::object(body, &["clips", "name", "folder"], "template request") {
            Ok(m) => m,
            Err(e) => return e,
        };
        let parsed = (|| -> Result<(Vec<Id>, String, Option<String>), String> {
            Ok((required(&map, "clips")?, required(&map, "name")?, optional(&map, "folder")?))
        })();
        let (clips, name, folder) = match parsed {
            Ok(p) => p,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        if clips.is_empty() || clips.len() > 200 {
            return HTTPResponse::error(400, "clips: 1...200 clip ids of the open sequence", None);
        }
        if name.trim().is_empty() || name.chars().any(char::is_control) || name.chars().count() > 120 {
            return HTTPResponse::error(400, "name: 1...120 characters, no control characters", None);
        }
        match self.host.save_template(clips, name, folder) {
            Ok(id) => HTTPResponse::json(200, &serde_json::json!({ "id": id })),
            Err(e) => Self::host_error(&e),
        }
    }

    fn playhead(&self, body: &[u8]) -> HTTPResponse {
        let map = match Self::object(body, &["at"], "playhead request") {
            Ok(m) => m,
            Err(e) => return e,
        };
        let at = match required::<WireTime>(&map, "at") {
            Ok(w) => w.time,
            Err(e) => return HTTPResponse::error(400, &e, None),
        };
        if !TimeLimits::is_valid_time(at) {
            return HTTPResponse::error(400, &TimeLimits::message(), None);
        }
        match self.host.seek(at) {
            Ok(went) => HTTPResponse::json(200, &serde_json::json!({ "playhead": went })),
            Err(e) => Self::host_error(&e),
        }
    }

    /// Undo for agents: only an "Agent: ..." step (and, if given, exactly `expectedName`), so an agent never undoes the
    /// user's own edit.
    fn undo(&self, body: &[u8]) -> HTTPResponse {
        let parsed = if body.is_empty() { Some(UndoRequest::default()) } else { serde_json::from_slice(body).ok() };
        let Some(parsed) = parsed else { return HTTPResponse::error(400, "invalid request", None) };
        let expected = parsed.expected_name;
        let ok = self.host.undo(&|name| name.starts_with("Agent: ") && expected.as_deref().is_none_or(|e| name == e));
        if ok {
            HTTPResponse::json(200, &serde_json::json!({"undone": true}))
        } else {
            HTTPResponse::error(409, "the last step is not this agent's edit", None)
        }
    }
}

/// Undo name of a batch of zoom cuts: "Zoom Layer" when any of them is laid as an adjustment layer.
fn zoom_label(ops: &[EditOperation]) -> &'static str {
    if ops.iter().any(|o| matches!(o, EditOperation::AddZoomCut(z) if z.as_layer)) { "Zoom Layer" } else { "Zoom cut" }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::edit_transaction::fixture::{Fixture, s};
    use sq_core_edit::history::History;
    use sq_core_edit::timeline_markers::TimelineMarkersExt;
    use sq_core_time::SequentialIds;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct Inner {
        history: History<Project>,
        active: Id,
        busy: bool,
    }

    /// Host backed by a plain History, standing in for EditorSession.
    pub(crate) struct FakeHost(Mutex<Inner>);

    impl FakeHost {
        pub(crate) fn new(f: &Fixture) -> Arc<FakeHost> {
            Arc::new(FakeHost(Mutex::new(Inner {
                history: History::with_default_limit(f.project.clone()),
                active: f.seq,
                busy: false,
            })))
        }
        fn inner(&self) -> std::sync::MutexGuard<'_, Inner> {
            self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
        }
        /// Stands in for EditorSession's extra perform steps (style tokens, pending scale): renames the project.
        fn extra_step(p: &mut Project) {
            p.name = "after extra steps".into();
        }
        fn user_edit(&self) {
            let mut ids = SequentialIds::default();
            self.inner().history.commit("Move", |p| {
                p.timelines[0].add_marker(s(3), "", &mut ids);
            });
        }
        fn depth(&self) -> usize {
            self.inner().history.undo_depth()
        }
    }

    impl EditAPIHost for FakeHost {
        fn project(&self) -> Option<Project> {
            Some(self.inner().history.current().clone())
        }
        fn active_sequence(&self) -> Option<Id> {
            Some(self.inner().active)
        }
        fn run(&self, r: &HostCommit, cancel: &AtomicBool) -> Result<(Project, Project), TransactionError> {
            let mut g = self.inner();
            r.admit(Some(g.active), g.busy, cancel)?;
            let before = g.history.current().clone();
            let edit = |p: &mut Project| {
                EditTransaction::apply(&r.operations, p, r.sequence, &mut SequentialIds::default())?;
                Self::extra_step(p);
                Ok(())
            };
            if r.dry_run {
                let mut p = before.clone();
                edit(&mut p)?;
                return Ok((before, p));
            }
            g.history.try_commit(&r.name, edit)?;
            Ok((before, g.history.current().clone()))
        }
        fn undo(&self, accept: &dyn Fn(&str) -> bool) -> bool {
            let mut g = self.inner();
            let ok = !g.busy && g.history.undo_name().is_some_and(accept);
            ok && g.history.undo()
        }
    }

    fn shared(host: &Arc<FakeHost>) -> Arc<dyn EditAPIHost> {
        Arc::<FakeHost>::clone(host)
    }

    fn config() -> EditAPIConfig {
        EditAPIConfig::new("secret-token".into(), 4321)
    }

    fn req(method: &str, path: &str, body: &str) -> HTTPRequest {
        let headers: HashMap<String, String> = [
            ("host".to_string(), "127.0.0.1:4321".to_string()),
            ("authorization".to_string(), "Bearer secret-token".to_string()),
        ]
        .into();
        HTTPRequest {
            method: method.into(),
            path: path.split('?').next().unwrap_or(path).into(),
            query: path.split_once('?').map(|(_, q)| q.to_string()).unwrap_or_default(),
            headers,
            body: body.as_bytes().to_vec(),
        }
    }

    fn with(mut r: HTTPRequest, key: &str, value: Option<&str>) -> HTTPRequest {
        match value {
            Some(v) => r.headers.insert(key.into(), v.into()),
            None => r.headers.remove(key),
        };
        r
    }

    fn handle(router: &EditAPIRouter, r: &HTTPRequest) -> HTTPResponse {
        router.handle(r, &AtomicBool::new(false))
    }

    fn json(r: &HTTPResponse) -> Value {
        serde_json::from_slice(&r.body).unwrap_or(Value::Null)
    }

    fn commit_body(f: &Fixture, ops: &str, name: &str, dry_run: bool, sequence: Option<Id>) -> String {
        format!(
            r#"{{"name":"{name}","dryRun":{dry_run},"sequence":"{}","operations":[{ops}]}}"#,
            sequence.unwrap_or(f.seq)
        )
    }

    const MARKER: &str = r#"{"op":"addMarker","at":{"value":1,"timescale":1}}"#;

    #[test]
    fn security_checks() {
        let router = EditAPIRouter::new(config(), FakeHost::new(&Fixture::new()));
        let state = req("GET", "/v1/state", "");
        assert_eq!(handle(&router, &with(state.clone(), "authorization", None)).status, 401);
        assert_eq!(handle(&router, &with(state.clone(), "authorization", Some("Bearer wrong"))).status, 401);
        assert_eq!(handle(&router, &with(state.clone(), "host", Some("evil.example:4321"))).status, 403); // DNS rebinding
        assert_eq!(handle(&router, &with(state.clone(), "host", Some("127.0.0.1:9999"))).status, 403);
        assert_eq!(handle(&router, &with(state.clone(), "origin", Some("https://evil.example"))).status, 403);
        let local = with(with(state.clone(), "host", Some("localhost:4321")), "origin", Some("http://localhost:4321"));
        assert_eq!(handle(&router, &local).status, 200);
        assert_eq!(handle(&router, &req("GET", "/nope", "")).status, 404);
        assert_eq!(handle(&router, &req("DELETE", "/v1/state", "")).status, 405);
    }

    #[test]
    fn perceive_routes_check_the_body_before_the_host_and_a_plain_host_says_501() {
        let router = EditAPIRouter::new(config(), FakeHost::new(&Fixture::new()));
        assert_eq!(handle(&router, &req("POST", "/v1/capture", "{}")).status, 400);
        assert_eq!(handle(&router, &req("POST", "/v1/capture", r#"{"at":{"value":1,"timescale":1}}"#)).status, 501);
        assert_eq!(handle(&router, &req("GET", "/v1/jobs/abc", "")).status, 404);
        assert_eq!(handle(&router, &req("GET", "/v1/capture", "")).status, 405);
    }

    #[test]
    fn state_returns_sequences() {
        let f = Fixture::new();
        let router = EditAPIRouter::new(config(), FakeHost::new(&f));
        let r = handle(&router, &req("GET", "/v1/state", ""));
        assert_eq!(r.status, 200);
        let s: ProjectState = serde_json::from_slice(&r.body).unwrap_or_else(|e| panic!("state: {e}"));
        let clips = s.sequences[0].tracks[0].clips.iter().map(|c| c.id).collect::<Vec<_>>();
        assert_eq!(clips, vec![f.a, f.b]);
        assert_eq!(s.active_sequence, Some(f.seq));
        let text = String::from_utf8_lossy(&r.body).into_owned();
        assert!(text.contains("\"timescale\"") && text.contains("/x/m.mov")); // media file paths are part of the read model
    }

    #[test]
    fn dry_run_returns_diff_runs_extra_steps_and_changes_nothing() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let op = format!(r#"{{"op":"rippleDelete","clips":["{}"]}}"#, f.b);
        let r = handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &op, "Tighten", true, None)));
        assert_eq!(r.status, 200);
        let res: CommitResponse = serde_json::from_slice(&r.body).unwrap_or_else(|e| panic!("response: {e}"));
        assert!(!res.applied && res.diff.removed.iter().map(|c| c.id).collect::<Vec<_>>() == vec![f.b]);
        assert_eq!(host.depth(), 0);
        let commit = HostCommit {
            name: "x".into(),
            sequence: f.seq,
            operations: vec![EditOperation::AddMarker { at: s(1), name: String::new() }],
            dry_run: true,
        };
        let dry = host.run(&commit, &AtomicBool::new(false));
        assert_eq!(dry.map(|(_, after)| after.name), Ok("after extra steps".to_string())); // the host's steps ran on the copy
    }

    #[test]
    fn unknown_keys_are_refused_instead_of_ignored() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let op = format!(r#"{{"op":"rippleDelete","clips":["{}"]}}"#, f.b);
        // A misspelled dryRun must not commit.
        let typo = format!(r#"{{"dryrun":true,"sequence":"{}","operations":[{op}]}}"#, f.seq);
        let r1 = handle(&router, &req("POST", "/v1/commit", &typo));
        assert_eq!(r1.status, 400);
        assert!(String::from_utf8_lossy(&r1.body).contains("dryrun"));
        // An extra key inside an operation is refused too.
        let bad_op = format!(r#"{{"op":"razor","at":{{"value":1,"timescale":1}},"clip":"{}"}}"#, f.b);
        let r2 = handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &bad_op, "T", false, None)));
        assert_eq!(r2.status, 400);
        assert_eq!(host.depth(), 0);
    }

    #[test]
    fn commit_is_one_undo_step_and_agent_undo_only_undoes_agent_steps() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let ops =
            format!(r#"{{"op":"razor","at":{{"value":1,"timescale":1}}}},{{"op":"rippleDelete","clips":["{}"]}}"#, f.b);
        let r = handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &ops, "Tighten", false, None)));
        let res: CommitResponse = serde_json::from_slice(&r.body).unwrap_or_else(|e| panic!("response: {e}"));
        assert!(r.status == 200 && res.applied && res.undo_name == "Agent: Tighten");
        assert_eq!(host.depth(), 1);
        let undo = |body: &str| handle(&router, &req("POST", "/v1/undo", body)).status;
        assert_eq!(undo(r#"{"expectedName":"Agent: Other"}"#), 409);
        assert_eq!(undo(r#"{"expectedName":"Agent: Tighten"}"#), 200);
        host.user_edit(); // the user's own step on top
        assert_eq!(undo(""), 409);
        assert_eq!(host.depth(), 1);
    }

    #[test]
    fn failing_batch_rolls_back_with_422() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let ops = format!(
            r#"{{"op":"rippleDelete","clips":["{}"]}},{{"op":"lift","clips":["{}"]}}"#,
            f.b,
            Id::from_u128(9999)
        );
        let r = handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &ops, "T", false, None)));
        assert_eq!(r.status, 422);
        assert_eq!(json(&r)["operationIndex"], 1);
        assert_eq!(host.depth(), 0);
        assert_eq!(host.project(), Some(f.project));
    }

    #[test]
    fn busy_gesture_and_changed_sequence_are_refused() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let post = |body: String| handle(&router, &req("POST", "/v1/commit", &body)).status;
        host.inner().busy = true;
        assert_eq!(post(commit_body(&f, MARKER, "T", false, None)), 409);
        host.inner().busy = false;
        assert_eq!(post(commit_body(&f, MARKER, "T", false, Some(Id::from_u128(31337)))), 409);
        host.inner().active = Id::from_u128(31338); // user switched sequence after the agent read state
        assert_eq!(post(commit_body(&f, MARKER, "T", false, None)), 409);
        assert_eq!(host.depth(), 0);
        assert_eq!(post(format!(r#"{{"operations":[{MARKER}]}}"#)), 400);
    }

    #[test]
    fn cancelled_request_is_not_applied() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let r = req("POST", "/v1/commit", &commit_body(&f, MARKER, "T", false, None));
        assert_eq!(router.handle(&r, &AtomicBool::new(true)).status, 503);
        assert_eq!(host.depth(), 0);
    }

    #[test]
    fn huge_times_are_rejected_without_crashing() {
        let f = Fixture::new();
        let host = FakeHost::new(&f);
        let router = EditAPIRouter::new(config(), shared(&host));
        let huge = format!(
            r#"{{"op":"trim","clip":"{}","edge":"tail","by":{{"value":9223372036854775807,"timescale":9223372036854775807}}}}"#,
            f.a
        );
        let post = |ops: &str, dry: bool| {
            handle(&router, &req("POST", "/v1/commit", &commit_body(&f, ops, "T", dry, None))).status
        };
        assert_eq!(post(&huge, false), 400);
        assert_eq!(post(&huge, true), 400);
        assert_eq!(post(r#"{"op":"razor","at":{"value":-9223372036854775808,"timescale":1}}"#, false), 400);
        assert_eq!(host.depth(), 0);
    }

    #[test]
    fn limits_and_bad_input() {
        let f = Fixture::new();
        let small = EditAPIConfig { max_operations: 1, ..config() };
        let router = EditAPIRouter::new(small, FakeHost::new(&f));
        let two = commit_body(&f, &format!("{MARKER},{MARKER}"), "T", false, None);
        let post = |body: &str| handle(&router, &req("POST", "/v1/commit", body)).status;
        assert_eq!(post(&two), 413);
        assert_eq!(post("{nope"), 400);
        assert_eq!(post(&commit_body(&f, "", "T", false, None)), 400);
    }

    #[test]
    fn token_is_hex_and_comparison_is_exact() {
        let mut n = 0_u8;
        let token = EditAPIConfig::make_token(&mut || {
            n = n.wrapping_add(37);
            n
        });
        assert_eq!(token.len(), 64);
        assert!(token.bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(EditAPIRouter::constant_time_equal(&token, &token.clone()));
        assert!(!EditAPIRouter::constant_time_equal("abc", "abd") && !EditAPIRouter::constant_time_equal("ab", "abc"));
    }

    #[test]
    fn params_and_effects_endpoints_and_the_param_diff() {
        let f = Fixture::new();
        let router = EditAPIRouter::new(config(), FakeHost::new(&f));
        let r = handle(&router, &req("GET", &format!("/v1/clip/{}/params", f.a_audio), ""));
        assert_eq!(r.status, 200);
        let paths: Vec<String> = json(&r)["params"]
            .as_array()
            .map(|a| a.iter().filter_map(|p| p["path"].as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        assert!(paths.contains(&"audio.volumeDb".to_string()) && paths.contains(&"audio.gainDb".to_string()));
        assert_eq!(handle(&router, &req("GET", &format!("/v1/clip/{}/params", Id::from_u128(31337)), "")).status, 404);
        assert_eq!(handle(&router, &req("GET", "/v1/clip/nope/params", "")).status, 404);
        let fx = json(&handle(&router, &req("GET", "/v1/effects", "")));
        let scopes: Vec<&str> = fx["effects"]
            .as_array()
            .map(|a| a.iter().filter_map(|e| e["scope"].as_str()).collect())
            .unwrap_or_default();
        assert!(scopes.contains(&"audio") && scopes.contains(&"video"));
        assert!(fx["effects"].as_array().is_some_and(|a| a.iter().any(|e| e["kind"] == "color")));
        // A parameter change is a diff the agent can read back; a dry run changes nothing.
        let op = format!(r#"{{"op":"setParam","clip":"{}","param":"audio.gainDb","value":4}}"#, f.a_audio);
        let dry = json(&handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &op, "Gain", true, None))));
        assert_eq!(
            (dry["applied"].as_bool(), dry["diff"]["paramChanges"][0]["params"][0]["param"].as_str()),
            (Some(false), Some("audio.gainDb"))
        );
        let real = json(&handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &op, "Gain", false, None))));
        assert_eq!(real["applied"], serde_json::json!(true));
        assert_eq!(real["diff"]["paramChanges"][0]["params"][0]["after"]["value"], serde_json::json!(4.0));
        // A bad parameter is a 422 with the reason.
        let bad = format!(r#"{{"op":"setParam","clip":"{}","param":"opacity","value":1}}"#, f.a_audio);
        let r = handle(&router, &req("POST", "/v1/commit", &commit_body(&f, &bad, "Bad", false, None)));
        assert_eq!(r.status, 422);
        assert!(json(&r)["error"].as_str().is_some_and(|m| m.contains("not a parameter of this clip")));
    }
}
