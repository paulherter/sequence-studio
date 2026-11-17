// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RecoveryTests.swift (the start-time and default-folder tests belong to the platform backends).

use super::*;
use sq_core_time::SequentialIds;
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(1);

/// A temp folder removed on drop.
pub(crate) struct TempDir(PathBuf);

impl TempDir {
    pub(crate) fn new() -> TempDir {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("sqrec-{}-{n}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    pub(crate) fn path(&self) -> PathBuf {
        self.0.clone()
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// An empty project with a fresh id.
pub(crate) fn project(name: &str) -> Project {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    Project::new(Id::from_u128(u128::from(n) << 64), name, vec![], vec![])
}

pub(crate) fn t(s: f64) -> Timestamp {
    Timestamp::from_unix_seconds(1_700_000_000.0 + s)
}

fn set_modified(path: &Path, date: Timestamp) {
    let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs_f64(date.unix_seconds());
    let mut options = fs::OpenOptions::new();
    #[cfg(windows)]
    {
        // Windows needs write-attribute access (and backup semantics for folders) to set a time.
        use std::os::windows::fs::OpenOptionsExt;
        options.access_mode(0x100).custom_flags(0x0200_0000);
    }
    #[cfg(not(windows))]
    options.read(true);
    options.open(path).unwrap().set_modified(when).unwrap();
}

fn store(dir: &TempDir) -> AutosaveStore {
    AutosaveStore::new(dir.path(), AutosavePolicy::default())
}

fn store_with(dir: &TempDir, keep: usize, max_age: f64) -> AutosaveStore {
    AutosaveStore::new(dir.path(), AutosavePolicy::new(300.0, keep, max_age))
}

fn dead(store: &AutosaveStore) -> RecoveryScanner<'_> {
    RecoveryScanner::new(store, |_| false, |_| None)
}

fn begin(store: &AutosaveStore, id: Id, name: &str, pid: i32, date: f64) {
    SessionMarker::new(store).begin(id, None, name, pid, t(date), None).unwrap();
}

fn plain(v: &[AutosaveVersion]) -> usize {
    v.iter().filter(|v| v.name.is_none()).count()
}

#[test]
fn policy_only_when_dirty_and_interval_elapsed() {
    let p = AutosavePolicy::default();
    assert!(p.interval == 300.0 && p.keep == 10);
    assert!(!p.should_autosave(false, None, t(0.0)));
    assert!(p.should_autosave(true, None, t(0.0)));
    assert!(!p.should_autosave(true, Some(t(0.0)), t(299.0)));
    assert!(p.should_autosave(true, Some(t(0.0)), t(300.0)));
}

#[test]
fn write_list_and_read() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    let mut ids = SequentialIds::default();
    s.write(&p, t(0.0), None, &mut ids).unwrap();
    s.write(&p, t(10.0), None, &mut ids).unwrap();
    let v = s.versions(p.id);
    assert_eq!(v.len(), 2);
    assert!(v[0].date > v[1].date); // newest first
    assert!((v[0].date.unix_seconds() - t(10.0).unix_seconds()).abs() < 0.01);
    assert_eq!(s.read(&v[0]).unwrap().name, "P");
}

#[test]
fn prunes_oldest_by_count() {
    let dir = TempDir::new();
    let s = store_with(&dir, 3, AutosavePolicy::DEFAULT_MAX_AGE);
    let p = project("P");
    let mut ids = SequentialIds::default();
    for i in 0..6 {
        s.write(&p, t(f64::from(i)), None, &mut ids).unwrap();
    }
    let v = s.versions(p.id);
    assert_eq!(v.len(), 3);
    assert!((v[2].date.unix_seconds() - t(3.0).unix_seconds()).abs() < 0.01);
}

#[test]
fn named_checkpoint_survives_prune_and_is_listed() {
    let dir = TempDir::new();
    let s = store_with(&dir, 2, 100.0);
    let p = project("P");
    let mut ids = SequentialIds::default();
    let cp = s.write(&p, t(0.0), Some("Before / the: re~cut"), &mut ids).unwrap();
    assert_eq!(cp.name.as_deref(), Some("Before the re cut"));
    for i in 1..=6 {
        s.write(&p, t(f64::from(i)), None, &mut ids).unwrap();
    }
    s.prune(p.id, t(100_000.0), None).unwrap();
    let v = s.versions(p.id);
    assert_eq!(plain(&v), 1); // plain ones pruned (newest stays)
    assert!(v.iter().any(|v| v.name.as_deref() == Some("Before the re cut"))); // named one stays, even older than max_age
    let named = v.iter().find(|v| v.name.is_some()).unwrap();
    assert_eq!(s.read(named).unwrap().name, "P");
}

#[test]
fn named_does_not_count_towards_keep() {
    let dir = TempDir::new();
    let s = store_with(&dir, 3, AutosavePolicy::DEFAULT_MAX_AGE);
    let p = project("P");
    let mut ids = SequentialIds::default();
    s.write(&p, t(0.0), Some("A"), &mut ids).unwrap();
    s.write(&p, t(1.0), Some("B"), &mut ids).unwrap();
    for i in 2..8 {
        s.write(&p, t(f64::from(i)), None, &mut ids).unwrap();
    }
    let v = s.versions(p.id);
    assert_eq!(v.iter().filter(|v| v.name.is_some()).count(), 2);
    assert_eq!(plain(&v), 3);
}

#[test]
fn blank_name_is_plain_autosave() {
    let dir = TempDir::new();
    let v = store(&dir).write(&project("P"), t(0.0), Some("  / : "), &mut SequentialIds::default()).unwrap();
    assert_eq!(v.name, None);
}

#[test]
fn prunes_by_age_but_keeps_newest() {
    let dir = TempDir::new();
    let s = store_with(&dir, 10, 100.0);
    let p = project("P");
    let mut ids = SequentialIds::default();
    s.write(&p, t(0.0), None, &mut ids).unwrap();
    s.write(&p, t(50.0), None, &mut ids).unwrap();
    s.write(&p, t(1000.0), None, &mut ids).unwrap(); // others are now older than 100 s
    assert_eq!(s.versions(p.id).len(), 1);
    // Newest survives even when itself too old.
    s.prune(p.id, t(100_000.0), None).unwrap();
    assert_eq!(s.versions(p.id).len(), 1);
}

#[test]
fn failed_write_leaves_no_partial_file() {
    let dir = TempDir::new();
    let p = project("P");
    let mut ids = SequentialIds::default();
    store(&dir).write(&p, t(0.0), None, &mut ids).unwrap();
    let bad = AutosaveStore::with_writer(
        dir.path(),
        AutosavePolicy::default(),
        std::sync::Arc::new(|project, path| {
            crate::project_file::project_file().write(project, path)?;
            Err(ProjectFileError::Corrupt) // fails after data reached the temp location
        }),
    );
    assert_eq!(bad.write(&p, t(5.0), None, &mut ids), Err(ProjectFileError::Corrupt));
    assert_eq!(bad.versions(p.id).len(), 1);
    let names: Vec<String> = list_dir(&bad.folder(p.id)).iter().map(|u| last_component(u)).collect();
    assert!(names.iter().all(|n| !n.ends_with(".tmp")));
    assert_eq!(names.iter().filter(|n| n.ends_with(".sqproj")).count(), 1);
}

#[test]
fn clean_close_leaves_no_candidate() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    begin(&s, p.id, "P", 1, 0.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    SessionMarker::new(&s).end(p.id, 1);
    assert!(dead(&s).scan(t(20.0)).is_empty());
}

#[test]
fn marker_left_after_crash_gives_candidate() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    begin(&s, p.id, "P", 1, 0.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    let found = dead(&s).scan(t(20.0));
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].project_id, p.id);
    assert_eq!(found[0].project_name, "P");
}

#[test]
fn own_marker_does_not_hide_a_crashed_session_of_the_same_project() {
    // Relaunch with the project path: this run's marker sits in the crashed run's folder.
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    begin(&s, p.id, "P", 1, 0.0);
    begin(&s, p.id, "P", std::process::id() as i32, 50.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    let own = std::process::id() as i32;
    let scanner = RecoveryScanner::new(&s, move |pid| pid == own, |_| None);
    let found = scanner.scan(t(60.0));
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].project_name, "P");
    assert!(SessionMarker::new(&s).infos(p.id).iter().any(|i| i.pid == own), "own marker stays");
}

#[test]
fn live_process_is_not_a_crash() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    begin(&s, p.id, "P", 42, 0.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    assert!(RecoveryScanner::new(&s, |pid| pid == 42, |_| None).scan(t(20.0)).is_empty());
}

#[test]
fn autosave_older_than_saved_file_is_not_candidate() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    let proj = dir.path().join("P.sqproj");
    crate::project_file::project_file().write(&p, &proj).unwrap();
    set_modified(&document_file(&proj), t(100.0));
    let mut ids = SequentialIds::default();
    SessionMarker::new(&s).begin(p.id, Some(&proj), "P", 1, t(0.0), None).unwrap();
    s.write(&p, t(50.0), None, &mut ids).unwrap();
    let scanner = dead(&s);
    assert!(scanner.scan(t(60.0)).is_empty());
    // The first scan consumed the dead marker (it was reported once); a later crash writes a new one.
    SessionMarker::new(&s).begin(p.id, Some(&proj), "P", 2, t(120.0), None).unwrap();
    s.write(&p, t(150.0), None, &mut ids).unwrap();
    assert_eq!(scanner.scan(t(160.0)).len(), 1);
}

#[test]
fn marker_lifecycle_reports_a_crash_only_once() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    let scanner = dead(&s);
    let m = SessionMarker::new(&s);
    // start -> clean quit -> next start: no crash.
    begin(&s, p.id, "P", 1, 0.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    m.end(p.id, 1);
    assert!(scanner.scan_sessions(t(15.0)).1.is_empty());
    // start -> no clean quit -> next start reports the crash, the one after does not.
    begin(&s, p.id, "P", 2, 20.0);
    let first = scanner.scan_sessions(t(25.0));
    assert_eq!(first.1.len(), 1);
    scanner.mark_reported(&first.1);
    assert!(scanner.scan_sessions(t(25.0)).1.is_empty());
    assert_eq!(scanner.scan(t(25.0)).len(), 1); // still offered for recovery until dismissed
}

#[test]
fn crash_with_saved_file_is_reported_once_and_marker_removed() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    let proj = dir.path().join("P.sqproj");
    crate::project_file::project_file().write(&p, &proj).unwrap();
    set_modified(&document_file(&proj), t(100.0));
    SessionMarker::new(&s).begin(p.id, Some(&proj), "P", 1, t(0.0), None).unwrap();
    s.write(&p, t(50.0), None, &mut SequentialIds::default()).unwrap();
    let scanner = dead(&s);
    assert_eq!(scanner.scan_sessions(t(60.0)).1.len(), 1);
    assert!(scanner.scan_sessions(t(60.0)).1.is_empty()); // not reported again at every launch
}

#[test]
fn candidates_ordered_newest_first() {
    let dir = TempDir::new();
    let s = store(&dir);
    let (a, b) = (project("A"), project("B"));
    let mut ids = SequentialIds::default();
    for (p, d) in [(&a, 10.0), (&b, 20.0)] {
        begin(&s, p.id, &p.name, 1, 0.0);
        s.write(p, t(d), None, &mut ids).unwrap();
    }
    let names: Vec<String> = dead(&s).scan(t(30.0)).into_iter().map(|c| c.project_name).collect();
    assert_eq!(names, ["B", "A"]);
}

#[test]
fn recover_keeps_id_and_name() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    begin(&s, p.id, "P", 1, 0.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    let scanner = dead(&s);
    let copy = scanner.recover(&scanner.scan(t(20.0))[0]).unwrap();
    assert_eq!(copy.id, p.id);
    assert_eq!(copy.name, "P");
}

#[test]
fn marker_without_autosave_is_no_candidate() {
    let dir = TempDir::new();
    let s = store(&dir);
    begin(&s, project("x").id, "P", 1, 0.0);
    assert!(dead(&s).scan(t(10.0)).is_empty());
}

#[test]
fn markers_per_pid_coexist_and_end_removes_only_own() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    let m = SessionMarker::new(&s);
    begin(&s, p.id, "P", 1, 0.0);
    begin(&s, p.id, "P", 2, 0.0);
    assert_eq!(m.infos(p.id).len(), 2);
    m.end(p.id, 1);
    assert_eq!(m.infos(p.id).iter().map(|i| i.pid).collect::<Vec<_>>(), [2]);
}

#[test]
fn live_session_blocks_crash_of_other_session() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    begin(&s, p.id, "P", 1, 0.0);
    begin(&s, p.id, "P", 2, 0.0);
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    // pid 1 dead, pid 2 alive and open: not a crash yet.
    assert!(RecoveryScanner::new(&s, |pid| pid == 2, |_| None).scan(t(20.0)).is_empty());
    // pid 2 closes cleanly; pid 1's stale marker remains -> candidate.
    SessionMarker::new(&s).end(p.id, 2);
    assert_eq!(dead(&s).scan(t(20.0)).len(), 1);
}

#[test]
fn reused_pid_with_different_start_time_is_dead() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    SessionMarker::new(&s).begin(p.id, None, "P", 42, t(0.0), Some(t(0.0))).unwrap();
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    let reused = RecoveryScanner::new(&s, |_| true, |_| Some(t(5000.0)));
    assert_eq!(reused.scan(t(20.0)).len(), 1);
    let alive = RecoveryScanner::new(&s, |_| true, |_| Some(t(0.0)));
    assert!(alive.scan(t(20.0)).is_empty());
}

#[test]
fn writing_older_date_never_prunes_just_written_version() {
    let dir = TempDir::new();
    let s = store_with(&dir, 2, AutosavePolicy::DEFAULT_MAX_AGE);
    let p = project("P");
    let mut ids = SequentialIds::default();
    s.write(&p, t(100.0), None, &mut ids).unwrap();
    s.write(&p, t(200.0), None, &mut ids).unwrap();
    let v = s.write(&p, t(0.0), None, &mut ids).unwrap(); // older than everything
    assert!(v.path.exists());
    assert!(s.versions(p.id).iter().any(|x| x.path.file_name() == v.path.file_name()));
}

#[test]
fn prune_removes_orphaned_tmp_dirs_older_than_one_hour() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("P");
    s.write(&p, t(0.0), None, &mut SequentialIds::default()).unwrap();
    let folder = s.folder(p.id);
    let (old, fresh) = (folder.join(".A.tmp"), folder.join(".B.tmp"));
    for u in [&old, &fresh] {
        fs::create_dir_all(u).unwrap();
    }
    set_modified(&old, t(0.0));
    set_modified(&fresh, t(7000.0));
    s.prune(p.id, t(7200.0), None).unwrap();
    assert!(!old.exists());
    assert!(fresh.exists());
}

#[test]
fn scan_removes_folders_holding_only_dead_markers() {
    let dir = TempDir::new();
    let s = store(&dir);
    let marker = SessionMarker::new(&s);
    let (dead_id, alive, foreign) = (project("a").id, project("b").id, project("c").id);
    begin(&s, dead_id, "Dead", 1, 0.0);
    begin(&s, alive, "Alive", 2, 0.0);
    let with_version = project("Crashed");
    begin(&s, with_version.id, "Crashed", 1, 0.0);
    s.write(&with_version, t(10.0), None, &mut SequentialIds::default()).unwrap();
    begin(&s, foreign, "Other", 1, 0.0);
    fs::write(s.folder(foreign).join("notes.txt"), "x").unwrap();
    let found = RecoveryScanner::new(&s, |pid| pid == 2, |_| None).scan(t(20.0));
    assert_eq!(found.iter().map(|c| c.project_id).collect::<Vec<_>>(), [with_version.id]);
    assert!(!s.folder(dead_id).exists()); // nothing to recover: gone
    assert_eq!(marker.infos(alive).len(), 1); // a running session keeps its marker
    assert_eq!(marker.infos(with_version.id).len(), 1); // a candidate is never touched
    assert!(marker.infos(foreign).is_empty()); // dead marker dropped ...
    assert!(s.folder(foreign).join("notes.txt").exists()); // ... other files stay
}

#[test]
fn clean_end_removes_the_empty_project_folder() {
    let dir = TempDir::new();
    let s = store(&dir);
    let marker = SessionMarker::new(&s);
    let id = project("u").id;
    begin(&s, id, "U", 1, 0.0);
    begin(&s, id, "U", 2, 0.0);
    marker.end(id, 1);
    assert!(s.folder(id).exists()); // another session's marker is still there
    marker.end(id, 2);
    assert!(!s.folder(id).exists());
}

#[test]
fn scan_removes_only_old_empty_folders() {
    let dir = TempDir::new();
    let s = store(&dir);
    let (old, fresh) = (s.folder(project("a").id), s.folder(project("b").id));
    fs::create_dir_all(&old).unwrap();
    fs::create_dir_all(&fresh).unwrap();
    let now = t(100_000.0);
    set_modified(&old, Timestamp::from_unix_seconds(now.unix_seconds() - 7200.0));
    set_modified(&fresh, now);
    assert!(dead(&s).scan(now).is_empty());
    assert!(!old.exists());
    assert!(fresh.exists()); // may be a session that is just writing its marker
}

#[test]
fn scan_of_many_stale_folders_leaves_nothing() {
    let dir = TempDir::new();
    let s = store(&dir);
    for _ in 0..200 {
        begin(&s, project("u").id, "U", 1, 0.0);
    }
    let scanner = dead(&s);
    assert!(scanner.scan(t(10.0)).is_empty());
    assert!(list_dir(&s.base).is_empty());
    assert!(scanner.scan(t(10.0)).is_empty());
}

#[test]
fn stamp_round_trips_and_formats_utc() {
    assert_eq!(file_stamp(Timestamp::from_unix_seconds(0.0)), "19700101-000000-000");
    assert_eq!(file_stamp(Timestamp::from_unix_seconds(1_700_000_000.25)), "20231114-221320-250");
    let parsed = parse_file_stamp("20231114-221320-250").unwrap();
    assert!((parsed.unix_seconds() - 1_700_000_000.25).abs() < 1e-6);
    assert!(parse_file_stamp("20231114-221320").is_none());
    assert_eq!(iso8601(t(0.0)), "2023-11-14T22:13:20Z");
}

#[test]
fn candidate_is_named_like_the_title_bar() {
    let dir = TempDir::new();
    let s = store(&dir);
    let p = project("C-Userspaulmedia.wav");
    SessionMarker::new(&s).begin(p.id, Some(Path::new("/tmp/Holiday.sqproj")), &p.name, 1, t(0.0), None).unwrap();
    s.write(&p, t(10.0), None, &mut SequentialIds::default()).unwrap();
    let found = dead(&s).scan(t(20.0));
    assert_eq!(found[0].display_name(), "Holiday");
    let unsaved = RecoveryCandidate { project_path: None, ..found[0].clone() };
    assert_eq!(unsaved.display_name(), "C-Userspaulmedia.wav");
}
