// Swift: UserDefaults (Preferences, start window, floating panels) and AppController+Files (autosave, crash recovery)
//! What the app keeps between runs besides the dock layout and the recents: the stored defaults (`prefs.json`), the
//! floating panel frames (`floating-panels.json`), the timed autosave of the open project and the offer to restore it
//! after a crash. [`Persist::pump`] runs after every host call; it only works when something changed or is due.

use serde_json::{Map, Value, json};
use sq_app_shell::{AppEvent, HostCx};
use sq_core_project::recovery::{AutosavePolicy, AutosaveStore, RecoveryCandidate, RecoveryScanner};
use sq_core_time::Timestamp;
use sq_draw_shell::{ShellDialog, ShellDock};
use sq_editor_session::RecoverySnapshotState;
use sq_editor_session::{AppSettings, FloatingPanelState};
use sq_uikit::appearance_palette::{AppearanceSettings, UiDefaults};
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

/// The stored defaults, mirrored to one JSON file whenever they changed.
#[derive(Default)]
pub struct FileDefaults {
    strings: BTreeMap<String, String>,
    integers: BTreeMap<String, i64>,
    lists: BTreeMap<String, Vec<String>>,
    // shortcut: bytes are JSON number arrays; fine for the few small blobs (shortcut maps), use base64 if one grows.
    blobs: BTreeMap<String, Vec<u8>>,
    numbers: BTreeMap<String, f64>,
    flags: BTreeMap<String, bool>,
    dirty: bool,
    /// The file this store mirrors (set by [`FileDefaults::load`]); [`FileDefaults::flush`] writes there.
    path: Option<std::path::PathBuf>,
}

impl FileDefaults {
    /// The defaults stored in `path` (none when the file is missing or unreadable).
    pub fn load(path: &Path) -> FileDefaults {
        let value = std::fs::read(path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
        let mut d = FileDefaults { path: Some(path.to_path_buf()), ..FileDefaults::default() };
        let Some(Value::Object(root)) = value else { return d };
        let section = |name: &str| root.get(name).and_then(Value::as_object).cloned().unwrap_or_default();
        for (k, v) in section("strings") {
            d.strings.extend(v.as_str().map(|s| (k.clone(), s.to_string())));
        }
        for (k, v) in section("integers") {
            d.integers.extend(v.as_i64().map(|n| (k.clone(), n)));
        }
        for (k, v) in section("lists") {
            d.lists.extend(serde_json::from_value(v).ok().map(|l| (k.clone(), l)));
        }
        for (k, v) in section("blobs") {
            d.blobs.extend(serde_json::from_value(v).ok().map(|b| (k.clone(), b)));
        }
        for (k, v) in section("numbers") {
            d.numbers.extend(v.as_f64().map(|n| (k.clone(), n)));
        }
        for (k, v) in section("flags") {
            d.flags.extend(v.as_bool().map(|b| (k.clone(), b)));
        }
        d
    }

    fn to_json(&self) -> Value {
        let map = |m: Map<String, Value>| Value::Object(m);
        json!({
            "strings": map(self.strings.iter().map(|(k, v)| (k.clone(), json!(v))).collect()),
            "integers": map(self.integers.iter().map(|(k, v)| (k.clone(), json!(v))).collect()),
            "lists": map(self.lists.iter().map(|(k, v)| (k.clone(), json!(v))).collect()),
            "blobs": map(self.blobs.iter().map(|(k, v)| (k.clone(), json!(v))).collect()),
            "numbers": map(self.numbers.iter().map(|(k, v)| (k.clone(), json!(v))).collect()),
            "flags": map(self.flags.iter().map(|(k, v)| (k.clone(), json!(v))).collect()),
        })
    }

    /// Writes the file now, for a change that must not wait for the next turn of [`Persist`] (the Style star). The
    /// dirty mark stays, so `Persist` still applies the change to the running app; it writes the same bytes again.
    pub fn flush(&self) {
        let Some(path) = &self.path else { return };
        let bytes = serde_json::to_vec_pretty(&self.to_json()).unwrap_or_default();
        if let Err(e) = write_atomic(path, &bytes) {
            eprintln!("sq: the preferences could not be saved: {e}");
        }
    }

    /// Writes the file through a temporary one, so a crash never leaves half a file.
    fn save(&mut self, path: &Path) -> std::io::Result<()> {
        self.dirty = false;
        write_atomic(path, &serde_json::to_vec_pretty(&self.to_json()).map_err(std::io::Error::other)?)
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

impl UiDefaults for FileDefaults {
    fn string(&self, key: &str) -> Option<String> {
        self.strings.get(key).cloned()
    }
    fn integer(&self, key: &str) -> Option<i64> {
        self.integers.get(key).copied()
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        self.lists.get(key).cloned()
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.blobs.get(key).cloned()
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.dirty |= self.strings.insert(key.to_string(), value.to_string()).as_deref() != Some(value);
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.dirty |= self.integers.insert(key.to_string(), value) != Some(value);
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.dirty |= self.lists.insert(key.to_string(), value.to_vec()).as_deref() != Some(value);
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.dirty |= self.blobs.insert(key.to_string(), value.to_vec()).as_deref() != Some(value);
    }
    fn remove(&mut self, key: &str) {
        let gone = [
            self.strings.remove(key).is_some(),
            self.integers.remove(key).is_some(),
            self.lists.remove(key).is_some(),
            self.blobs.remove(key).is_some(),
            self.numbers.remove(key).is_some(),
            self.flags.remove(key).is_some(),
        ];
        self.dirty |= gone.contains(&true);
    }
}

impl sq_audiofx::monitor_gain::MonitorDefaults for FileDefaults {
    fn number(&self, key: &str) -> Option<f64> {
        self.numbers.get(key).copied()
    }
    fn flag(&self, key: &str) -> bool {
        self.flags.get(key).copied().unwrap_or(false)
    }
    fn set_number(&mut self, key: &str, value: f64) {
        self.dirty |= self.numbers.insert(key.to_string(), value) != Some(value);
    }
    fn set_flag(&mut self, key: &str, value: bool) {
        self.dirty |= self.flags.insert(key.to_string(), value) != Some(value);
    }
    fn store_id(&self) -> usize {
        std::ptr::from_ref(self) as usize
    }
}

/// A handle on the one stored-defaults file for a panel that wants its own `Box<dyn ...>` (Library, Effects, meters):
/// every handle reads and writes the same store, so the settings survive a restart under the same `sq.*` keys.
#[derive(Clone)]
pub struct FileView(pub Rc<RefCell<FileDefaults>>);

impl UiDefaults for FileView {
    fn string(&self, key: &str) -> Option<String> {
        self.0.borrow().string(key)
    }
    fn integer(&self, key: &str) -> Option<i64> {
        self.0.borrow().integer(key)
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        self.0.borrow().string_array(key)
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.0.borrow().data(key)
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.0.borrow_mut().set_string(key, value);
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.0.borrow_mut().set_integer(key, value);
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.0.borrow_mut().set_string_array(key, value);
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.0.borrow_mut().set_data(key, value);
    }
    fn remove(&mut self, key: &str) {
        self.0.borrow_mut().remove(key);
    }
}

impl sq_audiofx::monitor_gain::MonitorDefaults for FileView {
    fn number(&self, key: &str) -> Option<f64> {
        self.0.borrow().number(key)
    }
    fn flag(&self, key: &str) -> bool {
        self.0.borrow().flag(key)
    }
    fn set_number(&mut self, key: &str, value: f64) {
        self.0.borrow_mut().set_number(key, value);
    }
    fn set_flag(&mut self, key: &str, value: bool) {
        self.0.borrow_mut().set_flag(key, value);
    }
    fn store_id(&self) -> usize {
        Rc::as_ptr(&self.0) as *const u8 as usize
    }
}

impl sq_library::library_folder_store::SettingsStore for FileView {
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        let d = self.0.borrow();
        d.data(key).or_else(|| d.string(key).map(String::into_bytes))
    }
    fn set_data(&mut self, key: &str, value: Vec<u8>) {
        self.0.borrow_mut().set_data(key, &value);
    }
    fn remove(&mut self, key: &str) {
        self.0.borrow_mut().remove(key);
    }
}

/// The stored editing settings the session itself reads: audio scrubbing, Selection Follows Playhead (off by default; the
/// session starts with it on) and the edit mode of new sequences. Swift: `SharedUIController.applySessionSettings`,
/// run at launch.
pub fn apply_session_settings(support: &Path, session: &mut sq_editor_session::EditorSession) {
    let stored = FileDefaults::load(&support.join("prefs.json"));
    apply_session_settings_from(&AppSettings::load(&stored), session);
    apply_media_defaults(&stored, session);
}

/// The stored app settings under `support` (the export reads "Use proxies when exporting" from them when a job starts).
pub fn stored_settings(support: &Path) -> AppSettings {
    AppSettings::load(&FileDefaults::load(&support.join("prefs.json")))
}

/// Stores the Program monitor's quality choice in `support/prefs.json` before the app starts, the way Preferences > Playback
/// does: `None` = Auto (the default of a fresh install), `Some(q)` = a fixed Default Quality. The app then applies it
/// through its own start path (`apply_monitor_settings`); the playback bench uses this for `--quality`.
pub fn store_start_quality(support: &Path, fixed: Option<sq_editor_session::MonitorQuality>) {
    let path = support.join("prefs.json");
    let mut d = FileDefaults::load(&path);
    let stored = AppSettings::load(&d);
    let next = match fixed {
        Some(q) => stored.choosing_fixed_quality(q),
        None => AppSettings { preview_quality_auto: true, ..stored },
    };
    next.save(&mut d);
    let _ = std::fs::create_dir_all(support);
    let _ = d.save(&path);
}

/// [`apply_session_settings`] for settings already at hand (Preferences saved them: Swift runs it again then).
pub fn apply_session_settings_from(settings: &AppSettings, session: &mut sq_editor_session::EditorSession) {
    session.engine_mut().set_audio_scrubbing(settings.audio_scrubbing);
    session.set_selection_follows_playhead(settings.selection_follows_playhead);
    session.set_use_proxies_for_export(settings.use_proxies_for_export);
    session.set_new_sequence_edit_mode(settings.new_sequence_edit_mode);
    session.engine_mut().set_frame_cache_bytes(program_frame_cache_bytes(settings.frame_cache_gb));
}

/// Preferences > Media: the app-wide defaults (Outside files, copy Library items, watch folder) reach the session, the one
/// place the import, the menu rows and the LUT collection at save read them from (a project's own policy still wins).
/// They are not in `AppSettings`, so launch and every settings change hand over the store itself.
pub fn apply_media_defaults(d: &dyn UiDefaults, session: &mut sq_editor_session::EditorSession) {
    let media = sq_editor_session::MediaSettings::load(d);
    session.set_media_policy_defaults(Box::new(move || media));
}

/// Preferences > Playback > Frame Cache (0 = Auto): the Program monitor's share of the one budget for both monitors.
pub fn program_frame_cache_bytes(frame_cache_gb: i64) -> usize {
    let ram = sq_platform::physical_memory().unwrap_or(16 << 30);
    let budget = sq_playback::engine::memory_budget::MemoryBudget::current(|k| std::env::var(k).ok(), ram);
    let total = budget.frame_cache_bytes(u64::try_from(frame_cache_gb).ok());
    sq_playback::engine::memory_budget::MemoryBudget::split(total).0
}

/// Marks the welcome tour as seen in the stored defaults under `support`: headless and test builds call it so the first
/// drawn frame opens no dialog that swallows the first click (a real first launch leaves it unset and shows the tour once).
pub fn mark_welcome_seen(support: &Path) {
    let path = support.join("prefs.json");
    let mut d = FileDefaults::load(&path);
    let mut settings = AppSettings::load(&d);
    settings.onboarding_seen = true;
    settings.save(&mut d);
    let _ = std::fs::create_dir_all(support);
    let _ = d.save(&path);
}

/// Points the projects folder (where New Project, template cards and Create write) at `folder` in `support/prefs.json`:
/// headless shots and exports must never write projects into the user's own `~/Movies/Sequence Studio`.
pub fn use_projects_folder(support: &Path, folder: &Path) {
    let path = support.join("prefs.json");
    let mut d = FileDefaults::load(&path);
    let mut locations = sq_editor_session::StorageLocations::load(&d);
    locations.projects_folder = Some(folder.to_path_buf());
    locations.save(&mut d);
    let _ = std::fs::create_dir_all(support);
    let _ = d.save(&path);
}

/// Adds `folder` to the Library's watched folders in `support/prefs.json` (headless shots of a Library with known media).
pub fn watch_library_folder(support: &Path, folder: &Path) {
    let defaults = FileDefaults::shared(support);
    let mut store = FileView(Rc::clone(&defaults));
    let mut folders = sq_library::library_folder_store::LibraryFolderStore::load(&mut store);
    folders.push(sq_library::watched_folder::WatchedFolder::new(
        sq_core_time::Id::from_u128(0x5e_0001),
        folder.to_path_buf(),
        None,
        None,
    ));
    sq_library::library_folder_store::LibraryFolderStore::save(&folders, &mut store);
    let _ = std::fs::create_dir_all(support);
    let _ = defaults.borrow_mut().save(&support.join("prefs.json"));
}

/// Stores an Appearance choice in `support/prefs.json` before the app starts (headless shots of the light theme).
pub fn store_appearance(support: &Path, look: &AppearanceSettings) {
    let path = support.join("prefs.json");
    let mut d = FileDefaults::load(&path);
    look.save(&mut d);
    let _ = std::fs::create_dir_all(support);
    let _ = d.save(&path);
}

impl FileDefaults {
    /// The shared store of the file `prefs.json` under `support`.
    pub fn shared(support: &Path) -> Rc<RefCell<FileDefaults>> {
        Rc::new(RefCell::new(FileDefaults::load(&support.join("prefs.json"))))
    }
}

/// Whether a process with this id runs (`kill -0` / `tasklist`: no FFI in this crate).
// shortcut: a spawned shell per marker at launch; the platform crates can answer without a process.
fn process_alive(pid: i32) -> bool {
    let out = if cfg!(windows) {
        std::process::Command::new("tasklist").args(["/FI", &format!("PID eq {pid}"), "/NH"]).output()
    } else {
        std::process::Command::new("kill").args(["-0", &pid.to_string()]).output()
    };
    match out {
        Ok(o) if cfg!(windows) => String::from_utf8_lossy(&o.stdout).contains(&pid.to_string()),
        Ok(o) => o.status.success(),
        Err(_) => true, // cannot tell: never offer a project another run may still have open
    }
}

fn wall_clock() -> Timestamp {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    Timestamp::from_unix_seconds(now.map(|d| d.as_secs_f64()).unwrap_or(0.0))
}

/// Stored defaults, floating frames, autosave and the recovery offer of one window.
pub struct Persist {
    defaults: Rc<RefCell<FileDefaults>>,
    prefs_path: PathBuf,
    floating_path: PathBuf,
    store: AutosaveStore,
    /// The pids that count as running (replaced in tests, which cannot crash their own process).
    pub(crate) alive: Box<dyn Fn(i32) -> bool>,
    applied: Option<(AppearanceSettings, i64)>,
    applied_interval: Option<f64>,
    scanned: bool,
    candidate: Option<RecoveryCandidate>,
    /// A project was recovered in this run.
    recovered: bool,
    answer: Rc<RefCell<Option<bool>>>,
    /// The extra recovery snapshot after each edit (Swift `startRecoveryTimer`), between the timed versions.
    snapshots: RecoverySnapshotState,
}

/// Seconds the project stays unchanged before a recovery snapshot is written (it follows an edit about a second later;
/// Swift `tickRecovery(minGap:)` used 5 s between writes).
const SNAPSHOT_GAP: f64 = 1.0;

impl Persist {
    /// The state under `support`; autosave versions go to the same folder the session writes them to.
    #[cfg(test)]
    pub fn open(support: &Path) -> Persist {
        Persist::open_with(support, FileDefaults::shared(support))
    }

    /// The state under `support` over an already loaded store (the panels built earlier write into the same one).
    pub fn open_with(support: &Path, defaults: Rc<RefCell<FileDefaults>>) -> Persist {
        let prefs_path = support.join("prefs.json");
        Persist {
            defaults,
            prefs_path,
            floating_path: FloatingPanelState::default_path(support),
            store: AutosaveStore::new(support.to_path_buf(), AutosavePolicy::default()),
            alive: Box::new(process_alive),
            applied: None,
            applied_interval: None,
            scanned: false,
            candidate: None,
            recovered: false,
            answer: Rc::new(RefCell::new(None)),
            snapshots: RecoverySnapshotState::new(),
        }
    }

    /// The stored defaults, to be the store of the shell.
    pub fn defaults(&self) -> Rc<RefCell<FileDefaults>> {
        Rc::clone(&self.defaults)
    }

    /// The floating panel frames saved last run.
    pub fn floating(&self) -> FloatingPanelState {
        FloatingPanelState::load(&self.floating_path)
    }

    /// The recovery offer is not settled: not scanned yet, or its question is open.
    pub fn recovery_pending(&self) -> bool {
        !self.scanned || self.candidate.is_some()
    }

    /// Whether the loop must wake again by itself: an edit waits for its recovery snapshot or the write is running.
    pub fn snapshot_needs_poll(&self) -> bool {
        self.snapshots.needs_poll()
    }

    /// The user recovered a project in this run.
    pub fn recovered(&self) -> bool {
        self.recovered
    }

    /// One round: stores changed defaults and applies them, saves quiet floating frames, autosaves, and answers or
    /// raises the recovery offer. Returns the dialog the root has to show.
    pub fn pump(&mut self, cx: &mut HostCx, dock: &mut ShellDock) -> Option<ShellDialog> {
        self.store_and_apply(cx);
        if let Some(state) = dock.floating.flush(false) {
            let _ = state.save(&self.floating_path); // a failed write only loses window positions (a convenience, like the layout)
        }
        let answered = self.answer.borrow_mut().take();
        if let Some(yes) = answered {
            self.finish_recovery(cx, yes);
        }
        // A timed version wins the round: a snapshot in the same millisecond would share its file name.
        if !cx.session.tick_autosave() {
            let now = cx.session.now();
            cx.session.tick_recovery(&mut self.snapshots, SNAPSHOT_GAP, now);
        }
        if self.scanned {
            return None;
        }
        self.scanned = true;
        self.offer_recovery()
    }

    fn store_and_apply(&mut self, cx: &mut HostCx) {
        let first = self.applied.is_none();
        if sq_draw::experimental::take_changed() {
            // A notice was closed: keep it for good.
            sq_draw::experimental::prefs().save(&mut *self.defaults.borrow_mut());
        }
        let was_dirty = self.defaults.borrow().dirty;
        if was_dirty && let Err(e) = self.defaults.borrow_mut().save(&self.prefs_path) {
            // Swift `ShellPreferences` says only this; the reason goes to the app log.
            eprintln!("sq: the preferences could not be saved: {e}");
            cx.emit(AppEvent::Status("Your defaults could not be saved.".to_string()));
        }
        if !first && !was_dirty {
            return;
        }
        let d = self.defaults.borrow();
        sq_draw::experimental::set_prefs(sq_draw::experimental::Prefs::load(&*d));
        let (look, scale) = (AppearanceSettings::from_defaults(&*d), stored_scale(&*d));
        let interval = AppSettings::load(&*d).autosave_interval;
        drop(d);
        if self.applied != Some((look, (scale * 100.0).round() as i64)) {
            self.applied = Some((look, (scale * 100.0).round() as i64));
            cx.emit(AppEvent::Appearance { settings: look, ui_scale: scale });
        }
        if self.applied_interval != Some(interval) {
            self.applied_interval = Some(interval);
            cx.session.set_autosave_interval(interval);
        }
    }

    /// The newest unsaved autosave of a run that did not end, as a question; `None` when Preferences turned it off.
    fn offer_recovery(&mut self) -> Option<ShellDialog> {
        if !AppSettings::load(&*self.defaults.borrow()).offer_recovery {
            return None;
        }
        let scanner = RecoveryScanner::new(&self.store, &self.alive, |_| None);
        let found = scanner.scan(wall_clock()).into_iter().next()?;
        let date = sq_draw_shell::absolute_time(found.autosave.date);
        let mut d = sq_draw_shell::ShellHost::recovery_dialog(&found.display_name(), &date);
        let answer = Rc::clone(&self.answer);
        d.completion =
            Some(Box::new(move |r: SQDialogResponse| *answer.borrow_mut() = Some(r == SQDialogResponse::FIRST)));
        self.candidate = Some(found);
        Some(d)
    }

    fn finish_recovery(&mut self, cx: &mut HostCx, yes: bool) {
        let Some(candidate) = self.candidate.take() else { return };
        let scanner = RecoveryScanner::new(&self.store, &self.alive, |_| None);
        if yes {
            if cx.session.recover(&candidate, &scanner).is_ok() {
                self.recovered = true;
                cx.emit(AppEvent::Status(format!("Recovered “{}”.", candidate.display_name())));
            }
        } else {
            scanner.dismiss(&candidate);
        }
    }
}

fn stored_scale(d: &dyn UiDefaults) -> f64 {
    sq_core_edit::interface_scale::load(
        d.string(sq_core_edit::interface_scale::DEFAULTS_KEY).and_then(|s| s.trim().parse().ok()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_rig::Rig;
    use sq_core_model::Project;
    use sq_core_time::Id;
    use sq_editor_session::{SessionDeps, WorkspaceStore};

    #[test]
    fn the_start_quality_is_stored_like_preferences_do() {
        use sq_editor_session::MonitorQuality;
        let support = scratch("start-quality");
        store_start_quality(&support, Some(MonitorQuality::Half));
        let s = stored_settings(&support);
        assert!(!s.preview_quality_auto);
        assert_eq!(s.start_quality(MonitorQuality::Auto), MonitorQuality::Half);
        store_start_quality(&support, None);
        let s = stored_settings(&support);
        assert!(s.preview_quality_auto);
        assert_eq!(s.start_quality(MonitorQuality::Full), MonitorQuality::Full);
    }

    #[test]
    fn a_headless_support_folder_gets_its_own_projects_folder() {
        let support = scratch("projects-folder");
        let folder = support.join("Projects");
        use_projects_folder(&support, &folder);
        let d = FileDefaults::load(&support.join("prefs.json"));
        let root = sq_editor_session::StorageLocations::load(&d).projects_root();
        assert_eq!(root, folder, "New Project and template cards write there, not into ~/Movies/Sequence Studio");
        assert!(!root.to_string_lossy().contains("Sequence Studio"), "{root:?}");
        let _ = std::fs::remove_dir_all(&support);
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = crate::test_rig::unique_dir(&format!("sq-persist-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn session(dir: &Path, id: u128, name: &str) -> sq_editor_session::EditorSession {
        let project = Project::new(Id::from_u128(id), name, Vec::new(), Vec::new());
        sq_editor_session::EditorSession::new(project, SessionDeps::headless(dir.to_path_buf()))
    }

    fn dock() -> ShellDock {
        ShellDock::new(WorkspaceStore::default())
    }

    fn appearance(rig: &Rig) -> Option<f64> {
        rig.events.iter().rev().find_map(|e| match e {
            AppEvent::Appearance { ui_scale, .. } => Some(*ui_scale),
            _ => None,
        })
    }

    #[test]
    fn a_failed_preferences_save_says_the_swift_text() {
        let dir = scratch("prefs-fail");
        let mut rig = Rig::new(session(&dir, 1, "A"));
        let mut p = Persist::open(&dir);
        p.alive = Box::new(|_| true);
        std::fs::create_dir_all(dir.join("prefs.json")).expect("block the file");
        p.defaults().borrow_mut().set_integer("sq.start.tab", 2);
        p.pump(&mut rig.cx(), &mut dock());
        assert!(
            rig.events.iter().any(|e| matches!(e, AppEvent::Status(s) if s == "Your defaults could not be saved."))
        );
    }

    #[test]
    fn defaults_survive_a_restart_and_apply() {
        let dir = scratch("prefs");
        let mut rig = Rig::new(session(&dir, 1, "A"));
        let mut first = Persist::open(&dir);
        first.alive = Box::new(|_| true);
        first.pump(&mut rig.cx(), &mut dock());
        assert_eq!(appearance(&rig), Some(1.0));
        {
            let store = first.defaults();
            let mut d = store.borrow_mut();
            d.set_string(sq_core_edit::interface_scale::DEFAULTS_KEY, "1.25");
            d.set_integer("sq.start.tab", 2);
            d.set_data("blob", &[1, 2, 3]);
            d.set_string_array("list", &["a".to_string()]);
            AppSettings { autosave_interval: 90.0, ..AppSettings::standard() }.save(&mut *d);
        }
        first.pump(&mut rig.cx(), &mut dock());
        assert_eq!(appearance(&rig), Some(1.25), "the new size reaches the app");
        assert!(dir.join("prefs.json").exists());

        let mut again = Persist::open(&dir);
        again.alive = Box::new(|_| true);
        let mut rig = Rig::new(session(&dir, 2, "B"));
        again.pump(&mut rig.cx(), &mut dock());
        let store = again.defaults();
        let d = store.borrow();
        assert_eq!(d.integer("sq.start.tab"), Some(2));
        assert_eq!(d.data("blob"), Some(vec![1, 2, 3]));
        assert_eq!(d.string_array("list"), Some(vec!["a".to_string()]));
        assert_eq!(AppSettings::load(&*d).autosave_interval, 90.0);
        drop(d);
        assert_eq!(appearance(&rig), Some(1.25), "the stored size applies at launch");
    }

    #[test]
    fn the_frame_cache_setting_sizes_the_program_engine_cache() {
        let dir = scratch("frame-cache");
        let mut s = session(&dir, 1, "A");
        let cache = |s: &mut sq_editor_session::EditorSession| {
            s.engine_mut()
                .as_any()
                .downcast_ref::<sq_editor_session::StubProgramEngine>()
                .and_then(|e| e.frame_cache_bytes)
        };
        apply_session_settings_from(&AppSettings { frame_cache_gb: 1, ..AppSettings::standard() }, &mut s);
        let one = cache(&mut s).expect("the engine hears the frame cache");
        apply_session_settings_from(&AppSettings { frame_cache_gb: 2, ..AppSettings::standard() }, &mut s);
        let two = cache(&mut s).expect("heard");
        assert!(two > one, "a larger Frame Cache setting reaches the engine ({one} then {two})");
        apply_session_settings_from(&AppSettings { frame_cache_gb: 0, ..AppSettings::standard() }, &mut s);
        assert_eq!(cache(&mut s), Some(program_frame_cache_bytes(0)), "Auto");
    }

    #[test]
    fn the_media_defaults_reach_the_session_at_launch() {
        use sq_core_model::{MediaPolicyDefaults, OutsideMediaMode};
        let dir = scratch("media-defaults");
        let mut s = session(&dir, 1, "A");
        assert_eq!(s.media_policy_defaults(), MediaPolicyDefaults::default(), "built in until the store is applied");
        let changed =
            MediaPolicyDefaults { outside: OutsideMediaMode::Move, copy_library_items: false, watch_folder: false };
        let mut stored = FileDefaults::load(&dir.join("prefs.json"));
        sq_editor_session::MediaSettings::store(changed, &mut stored);
        let _ = stored.save(&dir.join("prefs.json"));
        apply_session_settings(&dir, &mut s);
        assert_eq!(s.media_policy_defaults(), changed);
    }

    #[test]
    fn floating_frames_are_stored_and_loaded() {
        use sq_uikit::panel_id::PanelID;
        let dir = scratch("floating");
        let now = Rc::new(std::cell::Cell::new(10.0));
        let mut d = dock();
        d.set_frame(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 1000.0, 800.0));
        let clock = Rc::clone(&now);
        d.floating.clock = Box::new(move || clock.get());
        assert!(d.float(PanelID::Library, None));
        let mut p = Persist::open(&dir);
        let mut rig = Rig::new(session(&dir, 1, "A"));
        p.pump(&mut rig.cx(), &mut d);
        assert!(!dir.join("floating-panels.json").exists(), "a moving window is not written yet");
        now.set(11.0);
        p.pump(&mut rig.cx(), &mut d);
        let mut back = dock();
        back.load_floating(Persist::open(&dir).floating());
        assert!(back.floating.is_floating(PanelID::Library), "the window is back after a restart");
    }

    fn timed_session(
        dir: &Path,
        id: u128,
        name: &str,
        now: Rc<std::cell::Cell<f64>>,
    ) -> sq_editor_session::EditorSession {
        let project = Project::new(Id::from_u128(id), name, Vec::new(), Vec::new());
        let mut deps = SessionDeps::headless(dir.to_path_buf());
        deps.clock = Box::new(move || Timestamp::from_unix_seconds(now.get()));
        sq_editor_session::EditorSession::new(project, deps)
    }

    #[test]
    fn an_idle_window_keeps_asking_for_polls_until_the_snapshot_is_written() {
        let dir = scratch("idle-wake");
        let now = Rc::new(std::cell::Cell::new(1_790_000_000.0));
        let mut rig = Rig::new(timed_session(&dir, 9, "Idle", Rc::clone(&now)));
        let mut p = Persist::open(&dir);
        p.pump(&mut rig.cx(), &mut dock());
        assert!(!p.snapshot_needs_poll(), "nothing changed: the loop may sleep");
        // The first edit gets the timed version (it wins its round); the next one is a recovery snapshot.
        rig.session.perform("Rename", None, |p| p.name = "One".to_string());
        p.pump(&mut rig.cx(), &mut dock());
        now.set(1_790_000_020.0);
        rig.session.perform("Rename", None, |p| p.name = "Two".to_string());
        p.pump(&mut rig.cx(), &mut dock());
        assert!(p.snapshot_needs_poll(), "an edit waits for its debounce: the loop must wake by itself");
        now.set(1_790_000_021.5);
        p.pump(&mut rig.cx(), &mut dock());
        assert!(p.snapshot_needs_poll(), "the write runs");
        p.snapshots.finish_pending();
        p.pump(&mut rig.cx(), &mut dock());
        assert!(!p.snapshot_needs_poll(), "written: the loop sleeps again");
    }

    #[test]
    fn autosaves_carry_the_real_time_and_follow_every_edit() {
        let dir = scratch("timed");
        let now = Rc::new(std::cell::Cell::new(1_790_000_000.0));
        let mut rig = Rig::new(timed_session(&dir, 7, "Trip", Rc::clone(&now)));
        let mut p = Persist::open(&dir);
        rig.session.perform("Rename", None, |p| p.name = "One".to_string());
        p.pump(&mut rig.cx(), &mut dock());
        let first = rig.session.autosave_versions();
        assert_eq!(first.len(), 1);
        assert!(!first[0].path.to_string_lossy().contains("20010101"), "a real timestamp: {:?}", first[0].path);

        // A second edit 20 s later: the recovery snapshot follows 1.5 s after it, next to the timed version.
        now.set(1_790_000_020.0);
        rig.session.perform("Rename", None, |p| p.name = "Two".to_string());
        p.pump(&mut rig.cx(), &mut dock());
        now.set(1_790_000_021.5);
        p.pump(&mut rig.cx(), &mut dock());
        p.snapshots.finish_pending();
        let second = rig.session.autosave_versions();
        assert_eq!(second.len(), 2, "the edit reached the disk 20 s later, the timed version stays");

        // The timed version joins after the interval and keeps history.
        now.set(1_790_000_400.0);
        rig.session.perform("Rename", None, |p| p.name = "Three".to_string());
        p.pump(&mut rig.cx(), &mut dock());
        let third = rig.session.autosave_versions();
        assert_eq!(third.len(), 3, "the timed version joined after the interval");
        // The next recovery snapshot replaces only its own previous one.
        now.set(1_790_000_410.0);
        rig.session.perform("Rename", None, |p| p.name = "Four".to_string());
        p.pump(&mut rig.cx(), &mut dock());
        now.set(1_790_000_411.5);
        p.pump(&mut rig.cx(), &mut dock());
        p.snapshots.finish_pending();
        assert_eq!(rig.session.autosave_versions().len(), 3);
    }

    #[test]
    fn the_autosave_of_a_crashed_run_is_offered_and_restored() {
        let dir = scratch("recovery");
        // Run 1: an edit, the timed autosave, then no clean close (the marker stays).
        let mut rig = Rig::new(session(&dir, 7, "Trip"));
        rig.session.perform("Rename", None, |p| p.name = "Trip edited".to_string());
        let mut run1 = Persist::open(&dir);
        run1.pump(&mut rig.cx(), &mut dock());
        assert_eq!(rig.session.autosave_versions().len(), 1, "the autosave was written");

        // Run 2: the old process is gone; the question comes up and Recover brings the project back.
        let mut rig = Rig::new(session(&dir, 8, "Untitled"));
        let mut run2 = Persist::open(&dir);
        run2.alive = Box::new(|_| false);
        let mut dialog = run2.pump(&mut rig.cx(), &mut dock()).expect("the recovery question");
        assert!(dialog.message_text.contains("Trip"));
        let answer = dialog.completion.take().expect("an answer hook");
        answer(SQDialogResponse::FIRST);
        run2.pump(&mut rig.cx(), &mut dock());
        assert_eq!(rig.session.project().name, "Trip edited");
        assert!(rig.session.is_dirty(), "the recovered project asks to be saved");
    }

    #[test]
    fn a_clean_close_offers_nothing_and_discard_forgets() {
        let dir = scratch("clean");
        let mut rig = Rig::new(session(&dir, 7, "Trip"));
        rig.session.perform("Rename", None, |p| p.name = "Edited".to_string());
        Persist::open(&dir).pump(&mut rig.cx(), &mut dock());
        rig.session.close();
        let mut rig = Rig::new(session(&dir, 8, "Untitled"));
        let mut next = Persist::open(&dir);
        next.alive = Box::new(|_| false);
        assert!(next.pump(&mut rig.cx(), &mut dock()).is_none());
    }

    #[test]
    fn discard_dismisses_and_the_switch_in_preferences_turns_the_offer_off() {
        let dir = scratch("discard");
        let mut rig = Rig::new(session(&dir, 7, "Trip"));
        rig.session.perform("Rename", None, |p| p.name = "Edited".to_string());
        Persist::open(&dir).pump(&mut rig.cx(), &mut dock());

        let mut rig = Rig::new(session(&dir, 8, "Untitled"));
        let mut off = Persist::open(&dir);
        off.alive = Box::new(|_| false);
        AppSettings { offer_recovery: false, ..AppSettings::standard() }.save(&mut *off.defaults().borrow_mut());
        assert!(off.pump(&mut rig.cx(), &mut dock()).is_none(), "switched off in Preferences");

        let mut next = Persist::open(&dir);
        next.alive = Box::new(|_| false);
        AppSettings::standard().save(&mut *next.defaults().borrow_mut()); // switched on again
        let mut dialog = next.pump(&mut rig.cx(), &mut dock()).expect("still offered");
        (dialog.completion.take().expect("hook"))(SQDialogResponse(1));
        next.pump(&mut rig.cx(), &mut dock());
        let mut last = Persist::open(&dir);
        last.alive = Box::new(|_| false);
        assert!(last.pump(&mut rig.cx(), &mut dock()).is_none(), "discarded once, not asked again");
    }

    /// A window over `support` (the real root with its storage), showing a project that is not empty.
    fn window(support: &Path) -> sq_app_shell::Headless {
        use sq_app_shell::{AppDeps, Headless};
        use sq_runtime::FakeClock;
        let clock = std::sync::Arc::new(FakeClock::new());
        let h = Headless::new(
            session(support, 5, "Trip"),
            AppDeps::headless(std::sync::Arc::clone(&clock) as _),
            1000,
            800,
        );
        let root = crate::standard_root(support, clock, sq_draw::DrawTheme::default()).expect("root");
        h.with(|a| {
            a.session_mut().perform("Rename", None, |p| p.name = "Trip 2".to_string());
            a.add_host(Box::new(root));
            a.launch();
        });
        h
    }

    /// Makes the markers under `dir` those of a process that is gone (pid that does not exist), as after a crash.
    fn kill_markers(dir: &Path) {
        for folder in std::fs::read_dir(dir).expect("support").flatten().map(|e| e.path()).filter(|p| p.is_dir()) {
            for file in std::fs::read_dir(&folder).expect("folder").flatten().map(|e| e.path()) {
                let name = file.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
                if !(name.starts_with("running-") && name.ends_with(".lock")) {
                    continue;
                }
                let mut v: Value = serde_json::from_slice(&std::fs::read(&file).expect("marker")).expect("json");
                v["pid"] = json!(4_000_000);
                v.as_object_mut().expect("object").remove("processStart");
                std::fs::write(folder.join("running-4000000.lock"), serde_json::to_vec(&v).expect("json"))
                    .expect("write");
                std::fs::remove_file(&file).expect("remove old marker");
            }
        }
    }

    /// Start, recover prompt, Discard: the window ends on exactly what a normal start shows (the start window over an
    /// empty untitled session). Nothing is opened, not even the newest recent project that Enter or "Open last project on
    /// launch" would open (F19: a smoke run ended in an older project after the prompt).
    #[test]
    fn start_then_the_recover_prompt_then_discard_ends_on_the_start_window() {
        use sq_draw::{InputEvent, InputModifiers};
        use sq_draw_shell::ShellRoot;
        let dir = scratch("start-discard");
        let mut rig = Rig::new(session(&dir, 7, "Trip"));
        rig.session.perform("Rename", None, |p| p.name = "Trip edited".to_string());
        let mut run1 = Persist::open(&dir);
        run1.pump(&mut rig.cx(), &mut dock());
        kill_markers(&dir);
        mark_welcome_seen(&dir);
        // An older project sits first in the recent list.
        let older = dir.join("Older.sqproj");
        std::fs::write(&older, b"{}").expect("older project file");
        let entries = json!({"entries": [{"path": older.to_string_lossy(), "name": "Older", "opened": 1.0}]});
        std::fs::write(dir.join("recents.json"), serde_json::to_vec(&entries).expect("json")).expect("recents");

        use sq_app_shell::{AppDeps, Headless};
        use sq_runtime::FakeClock;
        let clock = std::sync::Arc::new(FakeClock::new());
        let h = Headless::new(
            session(&dir, 8, "Untitled"),
            AppDeps::headless(std::sync::Arc::clone(&clock) as _),
            1000,
            800,
        );
        let root = crate::standard_root(&dir, clock, sq_draw::DrawTheme::default()).expect("root");
        h.with(|a| {
            a.add_host(Box::new(root));
            a.launch();
        });
        for _ in 0..4 {
            h.turn();
        }
        let state = |h: &Headless| {
            h.with(|a| {
                let empty = a.session().is_empty_untitled();
                let shell = a.shell_parts().shell;
                (shell.is_start_shown(), shell.dialog().is_some(), empty)
            })
            .expect("window")
        };
        // Esc answers the prompt with its cancel button, Discard (the same answer a click on it gives).
        h.input(&InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE });
        for _ in 0..6 {
            h.turn();
        }
        assert_eq!(state(&h), (true, false, true), "Discard: the start window, no dialog, no project opened");
        let name = h.with(|a| a.session().project().name.clone()).expect("window");
        assert_eq!(name, "Untitled");
    }

    #[test]
    fn the_welcome_tour_opens_once_on_a_first_launch_and_never_on_a_marked_folder() {
        use sq_draw_shell::ShellRoot;
        let up = |support: &Path| {
            let h = window(support);
            for _ in 0..4 {
                h.turn();
            }
            h.with(|a| a.shell_parts().shell.dialog().is_some()).unwrap_or(false)
        };
        let first = scratch("tour-first");
        assert!(up(&first), "a first launch shows the tour on the first frames");
        assert!(!up(&first), "the second launch of the same folder shows it no more");
        let headless = scratch("tour-headless");
        mark_welcome_seen(&headless);
        assert!(!up(&headless), "a marked folder (headless and test builds) opens no tour");
    }

    #[test]
    fn the_interface_language_choice_lands_in_prefs_json_for_the_next_start() {
        // Settings > General > Interface Language: stored under `sq.language`, read once at launch by the app's
        // language.rs (`stored_language` reads `strings["sq.language"]`); "System" removes the key.
        let dir = scratch("language");
        let path = dir.join("prefs.json");
        let _ = std::fs::create_dir_all(&dir);
        let mut d = FileDefaults::load(&path);
        let mut x = sq_draw_shell::PreferencesExtras::load(&d);
        assert_eq!(x.ui_language, "system");
        x.ui_language = "de".to_string();
        x.save(&mut d);
        d.save(&path).expect("save");
        let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
        assert_eq!(sq_uikit::localization::DEFAULTS_KEY, "sq.language");
        assert_eq!(json["strings"]["sq.language"], "de");
        assert_eq!(sq_draw_shell::PreferencesExtras::load(&FileDefaults::load(&path)).ui_language, "de");
        x.ui_language = "system".to_string();
        x.save(&mut d);
        d.save(&path).expect("save");
        let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
        assert!(json["strings"]["sq.language"].is_null(), "System removes the override");
    }

    #[test]
    fn a_saved_autosave_interval_applies_to_the_running_session() {
        let dir = scratch("interval");
        let mut rig = Rig::new(session(&dir, 3, "A"));
        let mut p = Persist::open(&dir);
        AppSettings { autosave_interval: 600.0, ..AppSettings::standard() }.save(&mut *p.defaults().borrow_mut());
        p.pump(&mut rig.cx(), &mut dock());
        assert_eq!(rig.session.autosave_interval(), 600.0);
    }

    #[test]
    fn preferences_open_with_the_shortcut_and_their_values_return_after_a_restart() {
        use sq_draw::{InputEvent, InputKey, InputModifiers};
        use sq_draw_shell::ShellRoot;
        let dir = scratch("window");
        let h = window(&dir);
        h.turn();
        let comma = InputEvent::KeyDown { key: InputKey::Character(','), modifiers: InputModifiers::COMMAND };
        h.input(&comma);
        for _ in 0..3 {
            h.turn();
        }
        assert_eq!(h.with(|a| a.shell_parts().shell.dialog().is_some()), Some(true), "Preferences are up");

        // A value Preferences wrote lands in prefs.json and applies to the look; a restart finds both.
        h.with(|a| {
            let defaults = &mut a.shell_parts().shell.defaults;
            defaults.set_string(sq_core_edit::interface_scale::DEFAULTS_KEY, "1.5");
            defaults.set_string("sq.start.tab", "templates");
        });
        h.input(&InputEvent::MouseMoved { x: 1.0, y: 1.0 });
        h.turn();
        assert_eq!(h.with(|a| a.theme().scale), Some(1.5));
        let file = std::fs::read_to_string(dir.join("prefs.json")).expect("prefs.json");
        assert!(file.contains("templates") && file.contains("1.5"));

        let again = window(&dir);
        again.turn();
        assert_eq!(again.with(|a| a.theme().scale), Some(1.5), "the stored size applies at start");
        let tab = again.with(|a| a.shell_parts().shell.defaults.string("sq.start.tab"));
        assert_eq!(tab, Some(Some("templates".to_string())));
    }

    #[test]
    fn the_interface_size_commands_apply_to_the_running_window_right_away() {
        use sq_draw::{InputEvent, InputKey, InputModifiers};
        let dir = scratch("live-scale");
        let h = window(&dir);
        h.turn();
        let chord = |c: char| InputEvent::KeyDown {
            key: InputKey::Character(c),
            modifiers: InputModifiers::COMMAND | InputModifiers::OPTION,
        };
        // The first round raises the start-up dialog (recovery offer or welcome); it owns every key until closed, which is
        // why a second chord used to look lost. A real window shows the same dialog first.
        let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
        let mut scales = Vec::new();
        for c in ['=', '=', '-', '0'] {
            h.input(&esc);
            h.input(&chord(c));
            for _ in 0..3 {
                h.turn();
            }
            scales.push(h.with(|a| a.theme().scale));
        }
        assert_eq!(scales, [Some(1.1), Some(1.25), Some(1.1), Some(1.0)], "every chord applies at once");
    }
}
