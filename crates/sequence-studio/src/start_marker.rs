//! A marker file that lives from the start of the window until its first presented frame. A start that dies without a
//! window (a driver crash, an access violation, a kill) cannot show anything itself, but it leaves the marker behind; the
//! next start finds it and says so in the error window (`SQS-902`), with the log and the crash report named.

use crate::start_failure::{StartCode, StartFailure};
use std::fs;
use std::path::{Path, PathBuf};

fn marker(support: &Path) -> PathBuf {
    support.join("start-pending")
}

/// Called once this process owns the app (after the single-instance claim): reports a marker an earlier start left
/// behind, then writes a fresh one for this start.
pub fn begin(support: &Path) -> Option<StartFailure> {
    begin_with(support, std::process::id(), sq_platform::process::is_alive)
}

/// `begin` with the own pid and the liveness check given, so a test can play the earlier process.
fn begin_with(support: &Path, me: u32, alive: impl Fn(u32) -> bool) -> Option<StartFailure> {
    let path = marker(support);
    let stale = fs::read_to_string(&path).ok();
    let _ = fs::write(&path, format!("{me}\n"));
    // A marker of a process that is still running (or of this very pid, reused) is a start in progress, not a crash.
    stale
        .filter(|earlier| earlier.trim().parse::<u32>().map_or(true, |pid| pid != me && !alive(pid)))
        .map(|earlier| interrupted(&earlier, &path))
}

/// The first frame was presented, or the run ended in order: the start worked.
pub fn clear(support: &Path) {
    let _ = fs::remove_file(marker(support));
}

fn interrupted(earlier: &str, path: &Path) -> StartFailure {
    let pid = earlier.trim();
    let why = if pid.is_empty() {
        "the start did not reach its first frame".to_string()
    } else {
        format!("the start of process {pid} did not reach its first frame")
    };
    StartFailure::new(StartCode::StartInterrupted, "checking the last start", why).with_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-marker-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::create_dir_all(&dir);
        dir
    }

    #[test]
    fn a_start_that_reached_its_first_frame_leaves_nothing_to_report() {
        let dir = temp("ok");
        assert_eq!(begin(&dir), None, "the first start ever");
        assert!(marker(&dir).exists());
        clear(&dir);
        assert!(!marker(&dir).exists());
        assert_eq!(begin(&dir), None, "the start after a good one");
        clear(&dir);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_start_that_died_is_reported_by_the_next_one_once() {
        let dir = temp("died");
        assert_eq!(begin_with(&dir, 111, |_| false), None);
        let report = begin_with(&dir, 222, |_| false);
        assert_eq!(report.as_ref().map(|f| f.code), Some(StartCode::StartInterrupted));
        assert!(report.is_some_and(|f| f.system.contains("did not reach its first frame")));
        clear(&dir);
        assert_eq!(begin_with(&dir, 333, |_| false), None, "once the start worked the report is gone");
        clear(&dir);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_then_orderly_quit_before_the_first_frame_leaves_nothing() {
        let dir = temp("quit");
        assert_eq!(begin_with(&dir, 111, |_| false), None);
        clear(&dir); // what the loop's exit does
        assert_eq!(begin_with(&dir, 222, |_| false), None, "nothing to report after an orderly quit");
        clear(&dir);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_closed_report_window_leaves_nothing_for_the_next_start() {
        let dir = temp("report");
        assert_eq!(begin_with(&dir, 111, |_| false), None);
        assert!(begin_with(&dir, 222, |_| false).is_some(), "the killed start is reported once");
        clear(&dir); // the report window was shown, then closed
        assert_eq!(begin_with(&dir, 333, |_| false), None, "the report does not cascade");
        clear(&dir);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_marker_of_a_running_process_or_of_this_pid_is_not_reported() {
        let dir = temp("alive");
        assert_eq!(begin_with(&dir, 111, |_| true), None);
        assert_eq!(begin_with(&dir, 222, |pid| pid == 111), None, "pid 111 still runs");
        assert_eq!(begin_with(&dir, 222, |_| false), None, "the own pid is never a crash");
        let _ = fs::remove_dir_all(&dir);
    }
}
