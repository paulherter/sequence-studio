// SPDX-License-Identifier: GPL-3.0-or-later
//! Plain-text crash report written at the next launch.
// Swift: CrashReport.swift
//
// Not ported: `CrashReportStore.defaultDirectory` (it needs `AutosaveStore.defaultBase`, a platform path); callers pass the
// directory. The home folder and the clock are arguments.

use crate::recovery::{AutosaveVersion, MarkerInfo, file_stamp, iso8601, last_component, list_dir};
use sq_core_model::Project;
use sq_core_time::{Id, Timestamp};
use std::fs;
use std::path::PathBuf;

/// A session that ended without a clean close: its marker was left behind and its process is gone.
#[derive(Clone, Debug, PartialEq)]
pub struct CrashedSession {
    /// The project that was open.
    pub project_id: Id,
    /// The leftover marker.
    pub info: MarkerInfo,
    /// Newest autosave of the project, `None` when none was written.
    pub autosave: Option<AutosaveVersion>,
}

/// Plain-text crash report written at the next launch (the process itself cannot write after a crash): what was open,
/// a summary of the last autosaved state (counts and media names only, no paths) and the tail of the app log.
pub struct CrashReport;

impl CrashReport {
    /// Counts and media names of a project: no file paths, no text content.
    pub fn state_summary(project: &Project) -> Vec<String> {
        let mut lines = vec![
            format!("project: {}", project.name),
            format!("media items: {}", project.media.len()),
            format!("sequences: {}", project.timelines.len()),
        ];
        for tl in project.timelines.iter().take(10) {
            let clips: usize = tl.tracks.iter().map(|t| t.clips().len()).sum();
            lines.push(format!("  sequence \"{}\": {} tracks, {} clips", tl.name, tl.tracks.len(), clips));
        }
        let names: Vec<String> = project.media.iter().take(30).map(|m| format!("  {}", m.name)).collect();
        if !names.is_empty() {
            lines.push("media names:".to_string());
            lines.extend(names);
        }
        if project.media.len() > 30 {
            lines.push(format!("  ... and {} more", project.media.len() - 30));
        }
        lines
    }

    /// Replaces the home folder in a log line with `~` so a report does not carry the user name.
    pub fn redact(line: &str, home: &str) -> String {
        if sq_core_time::text::graphemes(home).count() <= 1 {
            return line.to_string();
        }
        line.replace(home, "~")
    }

    /// The last `count` lines of the log files given newest first (`sq.log`, `sq.1.log`, ...), in time order.
    pub fn log_tail(files: &[PathBuf], count: usize) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for f in files {
            let Ok(text) = fs::read_to_string(f) else { continue };
            let mut lines: Vec<String> = text.split('\n').filter(|l| !l.is_empty()).map(str::to_string).collect();
            lines.append(&mut out);
            out = lines;
            if out.len() >= count {
                break;
            }
        }
        out.split_off(out.len().saturating_sub(count))
    }

    /// The report text.
    #[allow(clippy::too_many_arguments)]
    pub fn render(
        session: &CrashedSession,
        project: Option<&Project>,
        log: &[String],
        app_version: &str,
        os: &str,
        system_report: Option<&str>,
        now: Timestamp,
        home: &str,
    ) -> String {
        let mut out = vec![
            "Sequence Studio crash report".to_string(),
            format!("created: {}", iso8601(now)),
            format!("app: {app_version}"),
            format!("system: {os}"),
            format!("session started: {} (pid {})", iso8601(session.info.started), session.info.pid),
            format!("project open: {}", session.info.project_name),
            format!("saved to disk: {}", if session.info.project_path.is_none() { "never saved" } else { "yes" }),
        ];
        match &session.autosave {
            Some(a) => out.push(format!("last autosave: {}", iso8601(a.date))),
            None => out.push("last autosave: none".to_string()),
        }
        if let Some(r) = system_report {
            out.push(format!("system crash report: {r}"));
        }
        out.push(String::new());
        out.push("State at last autosave".to_string());
        match project {
            Some(p) => out.extend(Self::state_summary(p)),
            None => out.push("(no autosave to read)".to_string()),
        }
        out.push(String::new());
        out.push("Last log lines".to_string());
        out.extend(log.iter().map(|l| Self::redact(l, home)));
        out.join("\n") + "\n"
    }
}

/// Folder of written reports (`Sequence Studio/Crash Reports`); the newest ones stay.
#[derive(Clone, Debug, PartialEq)]
pub struct CrashReportStore {
    /// Where the reports go.
    pub directory: PathBuf,
    /// Reports kept (at least 1).
    pub keep: usize,
}

impl CrashReportStore {
    /// `keep` is raised to 1.
    pub fn new(directory: PathBuf, keep: usize) -> CrashReportStore {
        CrashReportStore { directory, keep: keep.max(1) }
    }

    /// Writes `crash-<timestamp>.txt` and deletes the reports beyond `keep`.
    pub fn write(&self, text: &str, date: Timestamp) -> std::io::Result<PathBuf> {
        fs::create_dir_all(&self.directory)?;
        let url = self.directory.join(format!("crash-{}.txt", file_stamp(date)));
        fs::write(&url, text)?;
        for old in self.reports().into_iter().skip(self.keep) {
            let _ = fs::remove_file(old);
        }
        Ok(url)
    }

    /// Report files, newest first (the name sorts by time).
    pub fn reports(&self) -> Vec<PathBuf> {
        let mut found: Vec<PathBuf> = list_dir(&self.directory)
            .into_iter()
            .filter(|p| last_component(p).starts_with("crash-") && p.extension().is_some_and(|e| e == "txt"))
            .collect();
        found.sort_by_key(|p| std::cmp::Reverse(last_component(p)));
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::tests::{TempDir, project, t};
    use crate::recovery::{AutosaveStore, RecoveryScanner, SessionMarker};
    use sq_core_model::{MediaFingerprint, MediaRef};
    use sq_core_time::SequentialIds;

    fn dead(store: &AutosaveStore) -> RecoveryScanner<'_> {
        RecoveryScanner::new(store, |_| false, |_| None)
    }

    #[test]
    fn crashed_session_is_found_even_without_autosave() {
        let dir = TempDir::new();
        let store = AutosaveStore::new(dir.path(), Default::default());
        let p = project("P");
        SessionMarker::new(&store).begin(p.id, None, "P", 1, t(0.0), None).unwrap();
        let (candidates, crashed) = dead(&store).scan_sessions(t(0.0));
        assert!(candidates.is_empty());
        assert_eq!(crashed.len(), 1);
        assert!(crashed[0].autosave.is_none());
        assert_eq!(crashed[0].info.project_name, "P");
    }

    #[test]
    fn clean_close_and_live_session_are_not_crashes() {
        let dir = TempDir::new();
        let store = AutosaveStore::new(dir.path(), Default::default());
        let (a, b) = (project("A"), project("B"));
        let m = SessionMarker::new(&store);
        m.begin(a.id, None, "A", 1, t(0.0), None).unwrap();
        m.end(a.id, 1);
        m.begin(b.id, None, "B", 2, t(0.0), None).unwrap();
        let live = RecoveryScanner::new(&store, |_| true, |_| None);
        assert!(live.scan_sessions(t(0.0)).1.is_empty());
    }

    #[test]
    fn crashed_session_carries_newest_autosave() {
        let dir = TempDir::new();
        let store = AutosaveStore::new(dir.path(), Default::default());
        let p = project("P");
        let mut ids = SequentialIds::default();
        SessionMarker::new(&store).begin(p.id, None, "P", 1, t(0.0), None).unwrap();
        store.write(&p, t(10.0), None, &mut ids).unwrap();
        store.write(&p, t(20.0), None, &mut ids).unwrap();
        let (_, crashed) = dead(&store).scan_sessions(t(30.0));
        let date = crashed[0].autosave.as_ref().map(|a| a.date.unix_seconds().round());
        assert_eq!(date, Some(t(20.0).unix_seconds().round()));
    }

    #[test]
    fn summary_has_counts_and_names_but_no_paths() {
        let mut p = project("Wedding");
        p.media =
            vec![MediaRef::new(Id::fixed(1), "a.mov", "/Users/someone/Movies/a.mov", MediaFingerprint::new(1))].into();
        let text = CrashReport::state_summary(&p).join("\n");
        assert!(text.contains("Wedding"));
        assert!(text.contains("a.mov"));
        assert!(text.contains("media items: 1"));
        assert!(!text.contains("/Users/someone"));
    }

    #[test]
    fn redacts_home_folder_in_log_lines() {
        assert_eq!(CrashReport::redact("open /Users/me/Movies/x.mov", "/Users/me"), "open ~/Movies/x.mov");
    }

    #[test]
    fn log_tail_takes_last_lines_across_files_in_order() {
        let dir = TempDir::new();
        let (cur, old) = (dir.path().join("sq.log"), dir.path().join("sq.1.log"));
        fs::write(&cur, "c1\nc2\n").unwrap();
        fs::write(&old, "o1\no2\no3\n").unwrap();
        assert_eq!(CrashReport::log_tail(&[cur, old], 3), ["o3", "c1", "c2"]);
        assert!(CrashReport::log_tail(&[dir.path().join("none.log")], 3).is_empty());
    }

    #[test]
    fn render_contains_session_state_and_redacted_log() {
        let info = MarkerInfo {
            pid: 9,
            started: Timestamp::from_unix_seconds(0.0),
            project_name: "P".into(),
            project_path: Some("/x/P.sqproj".into()),
            process_start: None,
            reported: None,
        };
        let s = CrashedSession { project_id: Id::fixed(1), info, autosave: None };
        let text = CrashReport::render(
            &s,
            Some(&project("P")),
            &["err /Users/me/a".to_string()],
            "1.0 (5)",
            "macOS 27",
            Some("Sequence Studio-2026.ips"),
            t(0.0),
            "/Users/me",
        );
        assert!(text.contains("app: 1.0 (5)"));
        assert!(text.contains("project open: P"));
        assert!(text.contains("err ~/a"));
        assert!(!text.contains("/Users/me"));
        assert!(!text.contains("/x/P.sqproj"));
        assert!(text.contains("Sequence Studio-2026.ips"));
        assert!(text.contains("session started: 1970-01-01T00:00:00Z (pid 9)"));
    }

    #[test]
    fn store_writes_and_keeps_newest_only() {
        let dir = TempDir::new();
        let store = CrashReportStore::new(dir.path(), 2);
        for i in 0..4 {
            store.write(&format!("r{i}"), t(f64::from(i))).unwrap();
        }
        let r = store.reports();
        assert_eq!(r.len(), 2);
        assert_eq!(fs::read_to_string(&r[0]).unwrap(), "r3");
    }
}
