// SPDX-License-Identifier: GPL-3.0-or-later
//! Autosave versions, session markers and crash recovery.
// Swift: Recovery.swift
//
// Not ported (platform backends, injected instead): `AutosaveStore.defaultBase`, `SessionMarker.startTime(of:)` and
// `RecoveryScanner.systemProcessCheck`. The caller passes the process start time to `SessionMarker::begin` and the
// liveness checks to `RecoveryScanner::new`. Ids and clocks come from `IdSource` and `Timestamp` arguments.

use crate::crash_report::CrashedSession;
use serde::{Deserialize, Serialize};
use sq_core_file::{FILE_EXTENSION, ProjectFileError, document_file, is_project_path};
use sq_core_model::Project;
use sq_core_time::{Id, IdSource, Timestamp};
use std::fs;
use std::path::{Path, PathBuf};

/// When and how many autosave copies are made (Premiere defaults: every 5 min, 10 versions).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AutosavePolicy {
    /// Seconds between two autosaves.
    pub interval: f64,
    /// Plain versions kept (at least 1).
    pub keep: usize,
    /// Versions older than this are pruned, except the newest one.
    pub max_age: f64,
}

impl AutosavePolicy {
    /// Seconds a plain version stays by default (7 days).
    pub const DEFAULT_MAX_AGE: f64 = 7.0 * 24.0 * 3600.0;

    /// `keep` is raised to 1.
    pub fn new(interval: f64, keep: usize, max_age: f64) -> AutosavePolicy {
        AutosavePolicy { interval, keep: keep.max(1), max_age }
    }

    /// True when the project has unsaved changes and the interval since the last autosave has passed.
    pub fn should_autosave(&self, is_dirty: bool, last_autosave: Option<Timestamp>, now: Timestamp) -> bool {
        if !is_dirty {
            return false;
        }
        let Some(last) = last_autosave else { return true };
        now.unix_seconds() - last.unix_seconds() >= self.interval
    }
}

impl Default for AutosavePolicy {
    fn default() -> Self {
        AutosavePolicy::new(300.0, 10, Self::DEFAULT_MAX_AGE)
    }
}

/// One autosave package of a project.
#[derive(Clone, Debug, PartialEq)]
pub struct AutosaveVersion {
    /// The `<timestamp>.sqproj` package.
    pub path: PathBuf,
    /// When it was written.
    pub date: Timestamp,
    /// Set for a named checkpoint (`<timestamp>~<name>.sqproj`): it is never pruned.
    pub name: Option<String>,
}

/// Writes a project to a path (the default is `ProjectFile::write`).
pub type Writer = std::sync::Arc<dyn Fn(&Project, &Path) -> Result<(), ProjectFileError> + Send + Sync>;

/// One folder per project id under `base`; each version is a `<timestamp>.sqproj` package.
#[derive(Clone)]
pub struct AutosaveStore {
    /// Folder holding the per-project folders.
    pub base: PathBuf,
    /// Interval, count and age limits.
    pub policy: AutosavePolicy,
    writer: Writer,
}

const NAME_SEPARATOR: char = '~';

impl AutosaveStore {
    /// A store writing with `ProjectFile::write`.
    pub fn new(base: PathBuf, policy: AutosavePolicy) -> AutosaveStore {
        AutosaveStore::with_writer(
            base,
            policy,
            std::sync::Arc::new(|p, path| crate::project_file::project_file().write(p, path)),
        )
    }

    /// A store writing with `writer`.
    pub fn with_writer(base: PathBuf, policy: AutosavePolicy, writer: Writer) -> AutosaveStore {
        AutosaveStore { base, policy, writer }
    }

    /// The folder of one project.
    pub fn folder(&self, project_id: Id) -> PathBuf {
        self.base.join(project_id.to_string())
    }

    /// A file-name safe checkpoint name: path and separator characters become spaces, runs collapse; `None` when
    /// nothing is left.
    pub fn sanitized(raw: &str) -> Option<String> {
        let bad = |c: char| "/:\\~.".contains(c) || c.is_control() || matches!(c, '\u{2028}' | '\u{2029}');
        let words: Vec<&str> = raw.split(bad).flat_map(str::split_whitespace).collect();
        let joined = words.join(" ");
        let s: String = sq_core_time::text::graphemes(&joined).take(80).collect();
        if s.is_empty() { None } else { Some(s) }
    }

    /// Writes the snapshot into a hidden temp package, then renames it into place: a failure never leaves a partial
    /// version. `ids` names the temp package.
    pub fn write(
        &self,
        project: &Project,
        date: Timestamp,
        checkpoint: Option<&str>,
        ids: &mut dyn IdSource,
    ) -> Result<AutosaveVersion, ProjectFileError> {
        let dir = self.folder(project.id);
        fs::create_dir_all(&dir)?;
        let checkpoint_name = checkpoint.and_then(Self::sanitized);
        let name =
            file_stamp(date) + &checkpoint_name.as_ref().map(|n| format!("{NAME_SEPARATOR}{n}")).unwrap_or_default();
        let final_path = dir.join(format!("{name}.{FILE_EXTENSION}"));
        let tmp = dir.join(format!(".{}.tmp", ids.next_id()));
        let moved = (self.writer)(project, &tmp).and_then(|()| {
            if final_path.exists() {
                remove_item(&final_path)?;
            }
            fs::rename(&tmp, &final_path).map_err(ProjectFileError::from)
        });
        if let Err(e) = moved {
            let _ = remove_item(&tmp);
            return Err(e);
        }
        let _ = self.prune(project.id, date, Some(&final_path));
        Ok(AutosaveVersion { path: final_path, date, name: checkpoint_name })
    }

    /// Versions of a project, newest first.
    pub fn versions(&self, project_id: Id) -> Vec<AutosaveVersion> {
        let mut found: Vec<AutosaveVersion> = list_dir(&self.folder(project_id))
            .into_iter()
            .filter_map(|u| {
                if !is_project_path(&u) || last_component(&u).starts_with('.') {
                    return None;
                }
                let base = u.file_stem()?.to_string_lossy().into_owned();
                let parts: Vec<&str> = base.split(NAME_SEPARATOR).collect();
                let date = parse_file_stamp(parts.first()?)?;
                let label = if parts.len() > 1 { Self::sanitized(&parts[1..].join(" ")) } else { None };
                Some(AutosaveVersion { path: u, date, name: label })
            })
            .collect();
        found.sort_by(|a, b| b.date.partial_cmp(&a.date).unwrap_or(std::cmp::Ordering::Equal));
        found
    }

    /// Drops plain versions beyond `keep` and older than `max_age`; the newest version and `keeping` always stay
    /// (and count towards `keep`). Also removes orphaned `.<uuid>.tmp` dirs older than one hour.
    pub fn prune(&self, project_id: Id, now: Timestamp, keeping: Option<&Path>) -> Result<(), ProjectFileError> {
        let mut kept = 0;
        // Named checkpoints are never pruned and do not count towards `keep`.
        for (i, v) in self.versions(project_id).iter().filter(|v| v.name.is_none()).enumerate() {
            let is_keeping = keeping.is_some_and(|k| k.file_name() == v.path.file_name());
            if i == 0
                || is_keeping
                || (kept < self.policy.keep && now.unix_seconds() - v.date.unix_seconds() <= self.policy.max_age)
            {
                kept += 1;
            } else {
                remove_item(&v.path)?;
            }
        }
        for u in list_dir(&self.folder(project_id)) {
            if last_component(&u).starts_with('.')
                && u.extension().is_some_and(|e| e == "tmp")
                && modified(&u).is_some_and(|m| now.unix_seconds() - m.unix_seconds() > 3600.0)
            {
                let _ = remove_item(&u);
            }
        }
        Ok(())
    }

    /// Reads a version back.
    pub fn read(&self, version: &AutosaveVersion) -> Result<Project, ProjectFileError> {
        crate::project_file::project_file().read(&version.path)
    }
}

/// One "running" lock file per process and project (`running-<pid>.lock`): written at open, removed on clean close.
pub struct SessionMarker<'a> {
    /// The store whose project folders hold the markers.
    pub store: &'a AutosaveStore,
}

/// What a marker file says.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerInfo {
    /// Process id of the session.
    pub pid: i32,
    /// When the session started.
    #[serde(with = "sq_core_time::timestamp::iso8601")]
    pub started: Timestamp,
    /// Project name at that time.
    pub project_name: String,
    /// Saved project package, if the project was saved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_path: Option<String>,
    /// Start time of the process, to tell a reused pid from the original one. `None` in old markers.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "sq_core_time::timestamp::iso8601::option")]
    pub process_start: Option<Timestamp>,
    /// Set once a crash report was written for this marker, so a marker kept for recovery reports only once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reported: Option<bool>,
}

impl<'a> SessionMarker<'a> {
    /// Markers of `store`.
    pub fn new(store: &'a AutosaveStore) -> SessionMarker<'a> {
        SessionMarker { store }
    }

    fn file_name(pid: i32) -> String {
        format!("running-{pid}.lock")
    }

    fn file(&self, id: Id, pid: i32) -> PathBuf {
        self.store.folder(id).join(Self::file_name(pid))
    }

    /// Writes this process's marker (`process_start` is the kernel start time of the process, if known).
    pub fn begin(
        &self,
        project_id: Id,
        project_path: Option<&Path>,
        project_name: &str,
        pid: i32,
        date: Timestamp,
        process_start: Option<Timestamp>,
    ) -> Result<(), ProjectFileError> {
        fs::create_dir_all(self.store.folder(project_id))?;
        let info = MarkerInfo {
            pid,
            started: date,
            project_name: project_name.to_string(),
            project_path: project_path.map(|p| p.to_string_lossy().into_owned()),
            process_start,
            reported: None,
        };
        let data = serde_json::to_vec(&info).map_err(|e| ProjectFileError::Encode(e.to_string()))?;
        write_atomic(&self.file(project_id, pid), &data)?;
        Ok(())
    }

    /// Removes only this process's marker, and the project folder when nothing else is left in it (`remove_dir` only
    /// removes an empty folder, so a marker or autosave written meanwhile keeps it).
    pub fn end(&self, project_id: Id, pid: i32) {
        let _ = remove_item(&self.file(project_id, pid));
        let _ = fs::remove_dir(self.store.folder(project_id));
    }

    /// All markers of a project, one per process.
    pub fn infos(&self, project_id: Id) -> Vec<MarkerInfo> {
        Self::markers(&list_dir(&self.store.folder(project_id))).into_iter().map(|(_, i)| i).collect()
    }

    fn is_marker(u: &Path) -> bool {
        last_component(u).starts_with("running-") && u.extension().is_some_and(|e| e == "lock")
    }

    /// Readable markers among a folder's items, sorted by file name (unreadable ones are skipped, never deleted).
    fn markers(items: &[PathBuf]) -> Vec<(PathBuf, MarkerInfo)> {
        let mut files: Vec<&PathBuf> = items.iter().filter(|u| Self::is_marker(u)).collect();
        files.sort_by_key(|u| last_component(u));
        files
            .into_iter()
            .filter_map(|u| {
                let info = serde_json::from_slice(&fs::read(u).ok()?).ok()?;
                Some((u.clone(), info))
            })
            .collect()
    }
}

/// A project whose newest autosave can be offered after a crash.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryCandidate {
    /// The crashed project.
    pub project_id: Id,
    /// Its name.
    pub project_name: String,
    /// Saved project package, `None` for a project that was never saved.
    pub project_path: Option<PathBuf>,
    /// The newest autosave.
    pub autosave: AutosaveVersion,
}

impl RecoveryCandidate {
    /// What the title bar showed: the saved file's name without extension, else the project's name (Swift
    /// `EditorSession.displayName`).
    pub fn display_name(&self) -> String {
        match self.project_path.as_deref().and_then(Path::file_stem) {
            Some(stem) => stem.to_string_lossy().into_owned(),
            None => self.project_name.clone(),
        }
    }
}

/// Finds crashed sessions in an autosave store.
pub struct RecoveryScanner<'a> {
    /// The scanned store.
    pub store: &'a AutosaveStore,
    is_process_alive: Box<dyn Fn(i32) -> bool + 'a>,
    process_start: Box<dyn Fn(i32) -> Option<Timestamp> + 'a>,
}

impl<'a> RecoveryScanner<'a> {
    /// `is_process_alive` says whether a pid exists; `process_start` gives its start time (`None` when unknown).
    pub fn new(
        store: &'a AutosaveStore,
        is_process_alive: impl Fn(i32) -> bool + 'a,
        process_start: impl Fn(i32) -> Option<Timestamp> + 'a,
    ) -> RecoveryScanner<'a> {
        RecoveryScanner { store, is_process_alive: Box::new(is_process_alive), process_start: Box::new(process_start) }
    }

    /// Alive = the pid exists and, when recorded, the process start time still matches (pid reuse is not alive).
    fn is_alive(&self, info: &MarkerInfo) -> bool {
        if !(self.is_process_alive)(info.pid) {
            return false;
        }
        let (Some(recorded), Some(current)) = (info.process_start, (self.process_start)(info.pid)) else {
            return true;
        };
        (current.unix_seconds() - recorded.unix_seconds()).abs() < 2.0
    }

    /// This run's own marker: it says nothing about a crash or about another live session.
    fn is_own_live(&self, info: &MarkerInfo) -> bool {
        info.pid == std::process::id() as i32 && self.is_alive(info)
    }

    /// Projects with a dead session's marker and no live session, whose newest autosave is newer than the saved file.
    /// Newest first. Folders without any autosave version can never be recovered: their dead markers are removed (and
    /// the folder when nothing else is left), so stale markers do not pile up and slow the next launch. Touches the
    /// disk: call it off the UI thread.
    pub fn scan(&self, now: Timestamp) -> Vec<RecoveryCandidate> {
        self.scan_sessions(now).0
    }

    /// `scan` plus every crashed session found (also those without an autosave or already saved), for crash reports.
    pub fn scan_sessions(&self, now: Timestamp) -> (Vec<RecoveryCandidate>, Vec<CrashedSession>) {
        let mut out: Vec<RecoveryCandidate> = Vec::new();
        let mut crashed: Vec<CrashedSession> = Vec::new();
        for dir in list_dir(&self.store.base) {
            let Some(id) = Id::parse(&last_component(&dir)) else { continue };
            let items = list_dir(&dir);
            if items.is_empty() {
                // Left by older builds' clean close. A fresh one may belong to a session about to write its marker.
                if modified(&dir).is_some_and(|m| now.unix_seconds() - m.unix_seconds() > 3600.0) {
                    let _ = fs::remove_dir(&dir);
                }
                continue;
            }
            if !items.iter().any(|u| SessionMarker::is_marker(u)) {
                continue;
            }
            let markers = SessionMarker::markers(&items);
            // This run's own marker (relaunch with the project path) is neither a crash nor another live session.
            let infos: Vec<&MarkerInfo> = markers.iter().map(|(_, i)| i).filter(|i| !self.is_own_live(i)).collect();
            let newest_version = self.store.versions(id).into_iter().next();
            let any_alive = infos.iter().any(|i| self.is_alive(i));
            if let Some(latest) = latest_started(&infos).filter(|l| !any_alive && l.reported != Some(true)) {
                crashed.push(CrashedSession { project_id: id, info: latest.clone(), autosave: newest_version.clone() });
            }
            let Some(newest) = newest_version else {
                self.remove_dead(&markers);
                let _ = fs::remove_dir(&dir); // only when nothing else is left
                continue;
            };
            let Some(info) = latest_started(&infos).filter(|_| !any_alive) else { continue };
            let path = info.project_path.as_ref().map(PathBuf::from);
            let saved_after = path.as_ref().and_then(|p| modified(&document_file(p))).is_some_and(|s| newest.date <= s);
            if saved_after {
                // Saved after the last autosave: nothing to recover, and a dead marker left here would be reported at
                // every launch as a crash (the session is reported once, in this scan's `crashed`).
                self.remove_dead(&markers);
                let _ = fs::remove_dir(&dir);
                continue;
            }
            out.push(RecoveryCandidate {
                project_id: id,
                project_name: info.project_name.clone(),
                project_path: path,
                autosave: newest,
            });
        }
        out.sort_by(|a, b| b.autosave.date.partial_cmp(&a.autosave.date).unwrap_or(std::cmp::Ordering::Equal));
        crashed.sort_by(|a, b| b.info.started.partial_cmp(&a.info.started).unwrap_or(std::cmp::Ordering::Equal));
        (out, crashed)
    }

    fn remove_dead(&self, markers: &[(PathBuf, MarkerInfo)]) {
        for (url, _) in markers.iter().filter(|(_, i)| !self.is_alive(i)) {
            let _ = fs::remove_file(url);
        }
    }

    /// Marks the sessions as reported: a marker kept for the recovery offer no longer raises a crash report.
    pub fn mark_reported(&self, sessions: &[CrashedSession]) {
        let marker = SessionMarker::new(self.store);
        for s in sessions {
            let mut info = s.info.clone();
            info.reported = Some(true);
            let url = marker.file(s.project_id, info.pid);
            if !url.exists() {
                continue;
            }
            if let Ok(data) = serde_json::to_vec(&info) {
                let _ = write_atomic(&url, &data);
            }
        }
    }

    /// The autosave as the project it was: same id and name, so it carries on as that project (the session decides
    /// where it saves).
    pub fn recover(&self, candidate: &RecoveryCandidate) -> Result<Project, ProjectFileError> {
        self.store.read(&candidate.autosave)
    }

    /// Discards the stale markers (user declined recovery or finished it).
    pub fn dismiss(&self, candidate: &RecoveryCandidate) {
        let marker = SessionMarker::new(self.store);
        for info in marker.infos(candidate.project_id).iter().filter(|i| !self.is_alive(i)) {
            marker.end(candidate.project_id, info.pid);
        }
    }
}

/// The marker that started last; the first one wins a tie (Swift `max(by:)`).
fn latest_started<'i>(infos: &[&'i MarkerInfo]) -> Option<&'i MarkerInfo> {
    infos.iter().copied().fold(None, |best: Option<&MarkerInfo>, e| match best {
        Some(b) if b.started >= e.started => Some(b),
        _ => Some(e),
    })
}

// ---- file system and date helpers (shared with `crash_report`) ----

/// Directory entries by file name; empty when unreadable.
pub(crate) fn list_dir(dir: &Path) -> Vec<PathBuf> {
    let mut items: Vec<PathBuf> = fs::read_dir(dir).into_iter().flatten().flatten().map(|e| e.path()).collect();
    items.sort();
    items
}

pub(crate) fn last_component(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Modification date of a file or folder.
pub(crate) fn modified(p: &Path) -> Option<Timestamp> {
    let d = fs::metadata(p).ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
    Some(Timestamp::from_unix_seconds(d.as_secs_f64()))
}

/// Removes a file or a folder tree.
fn remove_item(p: &Path) -> std::io::Result<()> {
    if p.is_dir() { fs::remove_dir_all(p) } else { fs::remove_file(p) }
}

/// Writes next to the target, then renames (the temp name is a dot file the prune step cleans up).
fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_file_name(format!(".{}.tmp", last_component(path)));
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

pub(crate) fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `yyyyMMdd-HHmmss-SSS` in UTC (the fraction is cut off, not rounded).
pub(crate) fn file_stamp(date: Timestamp) -> String {
    let ms = (date.unix_seconds() * 1000.0).floor() as i64;
    let (days, ms_of_day) = (ms.div_euclid(86_400_000), ms.rem_euclid(86_400_000));
    let (y, mo, d) = civil_from_days(days);
    let (h, mi, s, f) = (ms_of_day / 3_600_000, ms_of_day / 60_000 % 60, ms_of_day / 1000 % 60, ms_of_day % 1000);
    format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}-{f:03}")
}

fn parse_file_stamp(s: &str) -> Option<Timestamp> {
    let b = s.as_bytes();
    if b.len() != 19 || b[8] != b'-' || b[15] != b'-' {
        return None;
    }
    if !s.bytes().enumerate().all(|(i, c)| i == 8 || i == 15 || c.is_ascii_digit()) {
        return None;
    }
    let n = |a: usize, z: usize| s[a..z].parse::<i64>().ok();
    let (y, mo, d, h, mi, sec, ms) = (n(0, 4)?, n(4, 6)?, n(6, 8)?, n(9, 11)?, n(11, 13)?, n(13, 15)?, n(16, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    let total = days_from_civil(y, mo, d) * 86_400_000 + h * 3_600_000 + mi * 60_000 + sec * 1000 + ms;
    Some(Timestamp::from_unix_seconds(total as f64 / 1000.0))
}

/// `2026-11-05T12:00:00Z`, whole seconds in UTC (Swift `ISO8601DateFormatter`).
pub(crate) fn iso8601(date: Timestamp) -> String {
    let secs = date.unix_seconds().floor() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem / 60 % 60, rem % 60)
}

#[cfg(test)]
pub(crate) mod tests;
