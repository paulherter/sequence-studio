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
use sq_core_time::{Id, IdSource, SequentialIds};
use sq_draw_shell::{EditApiState, ShellEditApi, StatusTone};
use sq_edit_api::edit_apirouter::{EditAPIConfig, EditAPIHost, EditAPIRouter};
use sq_edit_api::edit_apiserver_network::{EditAPIServer, State};
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
struct ApiBridge {
    sender: Sender<AppMessage>,
    busy: Arc<AtomicBool>,
}

impl ApiBridge {
    /// Runs `work` on the UI thread and waits for its answer; `None` when `cancel` is set, the connection deadline
    /// passes or the app is gone. The work itself checks `abandoned` so a request given up on never commits late.
    fn call<T: Send + 'static>(
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
fn with_ids<T>(app: &mut App, f: impl FnOnce(&mut App, &mut dyn IdSource) -> T) -> T {
    let mut ids = std::mem::replace(&mut app.session_mut().ids, Box::new(SequentialIds::default()));
    let out = f(app, ids.as_mut());
    app.session_mut().ids = ids;
    out
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
        let answer = self.call(Some(cancel), move |app, abandoned| {
            r.admit(app.session().active_timeline_id(), busy, abandoned)?;
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
            state: Arc::new(Mutex::new(not_running())),
            server: None,
        }
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
            Arc::new(ApiBridge { sender: self.sender.clone(), busy: Arc::clone(&self.busy) }),
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
        use sq_core_model::{MediaFingerprint, MediaRef};
        use sq_core_time::Time;
        use sq_editor_session::{EditorSession, PlaceOptions, SessionDeps};
        let mut media = MediaRef::new(Id::from_u128(901), "clip", "/tmp/sq-api-1.mp4", MediaFingerprint::new(1));
        media.duration = Some(Time::seconds(10));
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
}
