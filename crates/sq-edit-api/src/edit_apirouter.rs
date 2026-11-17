// Swift: EditAPIRouter.swift
//! Routes and guards requests; pure apart from the host calls, so every security rule is unit-tested.

use crate::edit_diff::EditDiff;
use crate::edit_operation::{EditOperation, check_strict_keys, optional, required};
use crate::edit_transaction::{EditTransaction, HostCommit, TransactionError, TransactionErrorKind};
use crate::http::{HTTPRequest, HTTPResponse, is_blank};
use crate::project_state::ProjectState;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use sq_core_model::{EditError, Project};
use sq_core_time::Id;
use sq_core_time::text::graphemes;
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
    /// longer the active sequence, so a sequence switch in between never redirects the edit.
    pub sequence: Id,
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
                sequence: required(&map, "sequence")?,
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
    /// What changed.
    pub diff: EditDiff,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct UndoRequest {
    expected_name: Option<String>,
}

/// Routes and guards requests. Pure apart from the host calls, so every security rule is unit-tested.
///
/// - `GET  /v1/state`   project read model (`ProjectState`)
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
                HTTPResponse::json(200, &s)
            }
            ("POST", "/v1/commit") => self.commit(&r.body, cancel),
            ("POST", "/v1/undo") => self.undo(&r.body),
            (_, "/v1/state" | "/v1/commit" | "/v1/undo") => HTTPResponse::error(405, "method not allowed", None),
            _ => HTTPResponse::error(404, "unknown endpoint", None),
        }
    }

    /// Host must name the loopback listener (DNS rebinding), a browser Origin must be loopback too, and the bearer token
    /// must match (constant-time compare).
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
        let undo_name = format!("Agent: {}", label.as_deref().unwrap_or("Edit"));
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
        let seq = req.sequence;
        EditTransaction::validate(&req.operations)?; // before any Time arithmetic, dry run included
        if cancel.load(Ordering::SeqCst) {
            return Err(TransactionError::new(TransactionErrorKind::Cancelled));
        }
        let commit =
            HostCommit { name: undo_name.to_string(), sequence: seq, operations: req.operations.clone(), dry_run: dry };
        let (before, after) = self.host.run(&commit, cancel)?;
        let (Some(b), Some(a)) = (before.timeline(seq), after.timeline(seq)) else {
            return Ok(HTTPResponse::error(409, "sequence vanished", None));
        };
        let mut diff = EditDiff::new(b, a);
        diff.note_media(&before, &after);
        let applied = !dry && !diff.is_empty();
        Ok(HTTPResponse::json(200, &CommitResponse { applied, sequence: seq, undo_name: undo_name.to_string(), diff }))
    }

    pub(crate) fn status(e: &TransactionError) -> u16 {
        match e.kind {
            TransactionErrorKind::Edit(EditError::TimelineNotFound) if e.operation_index.is_none() => 404,
            TransactionErrorKind::Edit(_) | TransactionErrorKind::MediaNotFound | TransactionErrorKind::NoPicture => {
                422
            }
            TransactionErrorKind::InvalidTime => 400,
            TransactionErrorKind::Busy | TransactionErrorKind::SequenceChanged => 409,
            TransactionErrorKind::Cancelled => 503,
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
        HTTPRequest { method: method.into(), path: path.into(), headers, body: body.as_bytes().to_vec() }
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
        assert!(text.contains("\"timescale\"") && !text.contains("/x/m.mov")); // no file paths leave the app
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
}
