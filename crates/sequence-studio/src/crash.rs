//! Crash reports: a panic hook writes a plain-text report into `Crashes/` of the support folder; the next launch
//! offers to show or copy it. Nothing is ever sent over the network.
//!
//! The report carries the panic message and place, a backtrace, the app version, the system and the last log lines.
//! It never reads the project; the home folder is replaced by `~` in every line. A panic message can still quote
//! data the code formatted into it, so the message is cut to 500 characters.
//!
//! Native faults (access violation, stack overflow, fatal signals) write a shorter report of the same format from
//! `sq-platform-win` / `sq-platform-mac` (`install_native`); it has the fault, the place and the log tail, no backtrace.
//! Windows also reports a C-runtime `abort()` (SIGABRT handler); only a Rust `process::abort` (`__fastfail`) leaves none.

use crate::applog;
use sq_app_hosts::{FileManager, SystemPlatform};
use sq_app_shell::Headless;
use sq_core_project::crash_report::{CrashReport, CrashReportStore};
use sq_core_time::Timestamp;
use sq_draw_shell::{ShellDialog, ShellRoot};
use sq_uikit::app_version::AppVersion;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::backtrace::Backtrace;
use std::fs;
use std::panic::PanicHookInfo;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Reports kept on disk.
const KEEP: usize = 10;
const MAX_MESSAGE: usize = 500;
/// Holds the file name of the newest report the user has dealt with.
const REVIEWED: &str = "reviewed";

fn store(support: &Path) -> CrashReportStore {
    CrashReportStore::new(support.join("Crashes"), KEEP)
}

/// Home folders of this user, as the system spells them.
fn homes() -> Vec<String> {
    ["HOME", "USERPROFILE"].iter().filter_map(|k| std::env::var(k).ok()).collect()
}

fn unix_now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// `2026-11-08T12:30:00Z` from Unix seconds (civil-from-days, proleptic Gregorian).
fn utc_text(secs: u64) -> String {
    let (days, rest) = ((secs / 86_400) as i64, secs % 86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rest / 3600, rest / 60 % 60, rest % 60)
}

/// The report text for a panic; `homes` are replaced by `~` everywhere.
fn render(message: &str, place: &str, backtrace: &str, lines: &[String], now: u64, homes: &[String]) -> String {
    let message: String = message.chars().take(MAX_MESSAGE).collect();
    let mut out = vec![
        "Sequence Studio crash report".to_string(),
        format!("created: {}", utc_text(now)),
        format!("app: {}", AppVersion::full_name()),
        format!("system: {} {}", std::env::consts::OS, std::env::consts::ARCH),
        format!("panic: {message}"),
        format!("at: {place}"),
        String::new(),
        "Backtrace".to_string(),
    ];
    out.extend(backtrace.lines().map(str::to_string));
    out.push(String::new());
    out.push("Last log lines".to_string());
    out.extend(lines.iter().cloned());
    let text = out.join("\n") + "\n";
    homes.iter().fold(text, |t, h| CrashReport::redact(&t, h))
}

fn describe(info: &PanicHookInfo<'_>) -> (String, String) {
    let payload = info.payload();
    let message = payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "non-text panic".to_string());
    let place = info.location().map_or_else(|| "unknown".to_string(), |l| format!("{}:{}", l.file(), l.line()));
    (message, place)
}

/// Writes a report for a panic now; the hook and the tests share it. `None` when the disk refuses.
fn write_report(support: &Path, message: &str, place: &str, backtrace: &str) -> Option<PathBuf> {
    let text = render(message, place, backtrace, &applog::recent_lines(), unix_now() as u64, &homes());
    store(support).write(&text, Timestamp::from_unix_seconds(unix_now())).ok()
}

/// A panic its owner catches (export queue, playback lanes, worker threads) is logged but leaves no report: a report
/// would show "quit unexpectedly" at the next launch for a run that went on.
fn reports_panic() -> bool {
    !sq_core_time::caught_panic::is_caught()
}

/// The panic the hook saw last (message, place): the start path names it when it turns a panic into an error window.
static LAST_PANIC: std::sync::Mutex<Option<(String, String)>> = std::sync::Mutex::new(None);

/// The last panic any thread had, `(message, place)`.
pub fn last_panic() -> Option<(String, String)> {
    LAST_PANIC.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

/// Starts the log and routes every panic (any thread) into a report, then to the previous hook. Returns whether the log
/// folder itself could be written (else the log is in the temp folder, `applog::fallback_dir`).
pub fn install(support: &Path) -> bool {
    let log_ok =
        applog::init(&crate::paths::log_dir(support), applog::Level::parse(std::env::var("SQ_LOG").ok().as_deref()));
    applog::info(&format!("start {}", AppVersion::full_name()));
    install_native(support);
    let support = support.to_path_buf();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let (message, place) = describe(info);
        *LAST_PANIC.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some((message.clone(), place.clone()));
        applog::error(&format!("panic at {place}: {message}"));
        if reports_panic() {
            let backtrace = Backtrace::force_capture().to_string();
            write_report(&support, &message, &place, &backtrace);
        }
        previous(info);
    }));
    log_ok
}

/// Native fault reports into the same `Crashes/` folder; the log tail comes from the log file.
fn install_native(support: &Path) {
    use sq_platform::{FaultConfig, install_fault_report};
    let Some(logs) = applog::directory() else { return };
    install_fault_report(&FaultConfig {
        crashes_dir: support.join("Crashes"),
        log_file: logs.join("sq.log"),
        app: AppVersion::full_name(),
        system: format!("{} {}", std::env::consts::OS, std::env::consts::ARCH),
        homes: homes(),
    });
}

/// The newest report the user has not dealt with yet.
pub fn pending(support: &Path) -> Option<PathBuf> {
    let newest = store(support).reports().into_iter().next()?;
    let name = newest.file_name()?.to_string_lossy().into_owned();
    let seen = fs::read_to_string(support.join("Crashes").join(REVIEWED)).unwrap_or_default();
    (name.as_str() > seen.trim()).then_some(newest)
}

/// Remembers that `report` was dealt with, so the next launch stays quiet.
pub fn mark_reviewed(support: &Path, report: &Path) {
    if let Some(name) = report.file_name() {
        let _ = fs::write(support.join("Crashes").join(REVIEWED), name.to_string_lossy().as_bytes());
    }
}

/// The start-of-launch question: Show Report (file manager), Copy Report (clipboard) or Dismiss.
pub fn offer_dialog() -> ShellDialog {
    let mut d = ShellDialog::new(
        "Sequence Studio quit unexpectedly last time",
        "A crash report was saved on this computer. It holds the error, the app version and the last log lines, \
         no project content. Nothing is sent anywhere; you decide whether to share it.",
    );
    d.add_button("Show Report", SQDialogRole::Default, false);
    d.add_button("Copy Report", SQDialogRole::Normal, false);
    d.add_button("Dismiss", SQDialogRole::Normal, true);
    d
}

/// Points Help > Reveal Logs and Reports at the log folder and asks about the newest unreviewed report, if any.
pub fn connect(app: &Headless, support: &Path) {
    app.with(|a| a.shell_parts().shell.log_directory = applog::directory());
    let Some(report) = pending(support) else { return };
    let (h, support) = (app.handle(), support.to_path_buf());
    app.executor().spawn_local(async move {
        let Some(ask) = h.with(|a| a.shell_parts().shell.present(offer_dialog())) else { return };
        let response = ask.await;
        answer(&support, &report, response, |p| {
            let _ = SystemPlatform.reveal(p);
        });
    });
}

/// What a button of [`offer_dialog`] does.
pub fn answer(support: &Path, report: &Path, response: SQDialogResponse, reveal: impl FnOnce(&Path)) {
    match response {
        SQDialogResponse::FIRST => reveal(report),
        SQDialogResponse::SECOND => {
            if let (Ok(text), Ok(mut clipboard)) = (fs::read_to_string(report), arboard::Clipboard::new()) {
                let _ = clipboard.set_text(text);
            }
        }
        _ => {}
    }
    mark_reviewed(support, report);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-crash-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_panic_its_owner_catches_leaves_no_report() {
        assert!(reports_panic());
        let seen = sq_core_time::caught_panic::catching(reports_panic);
        assert_eq!(seen.ok(), Some(false), "inside catching the hook must stay quiet");
        assert!(reports_panic());
    }

    #[test]
    fn utc_text_is_iso() {
        assert_eq!(utc_text(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_text(1_762_562_400), "2025-11-08T00:40:00Z");
    }

    #[test]
    fn a_report_has_the_version_and_no_home_paths() {
        let lines = vec!["10 INFO opened /Users/zoe/Movies/film.sqproj".to_string()];
        let text =
            render("boom", "/Users/zoe/src/a.rs:4", "0: f\n  at /Users/zoe/x.rs:1", &lines, 0, &["/Users/zoe".into()]);
        assert!(text.contains(&AppVersion::full_name()));
        assert!(text.contains("panic: boom") && text.contains("Last log lines"));
        assert!(!text.contains("zoe"), "{text}");
        assert!(text.contains("~/Movies/film.sqproj"));
    }

    #[test]
    fn a_long_message_is_cut() {
        let text = render(&"x".repeat(5000), "p", "", &[], 0, &[]);
        assert!(text.len() < 1500);
    }

    #[test]
    fn a_panic_in_a_thread_writes_a_report_that_stays_pending_until_reviewed() {
        let support = temp("thread");
        applog::init(&support.join("Logs"), applog::Level::Debug);
        applog::info("status: Imported 3 clips");
        let for_hook = support.clone();
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let (message, place) = describe(info);
            write_report(&for_hook, &message, &place, &Backtrace::force_capture().to_string());
        }));
        let worker = std::thread::spawn(|| panic!("worker failed"));
        assert!(worker.join().is_err());
        std::panic::set_hook(previous);

        let report = pending(&support);
        let text = report.as_ref().and_then(|r| fs::read_to_string(r).ok()).unwrap_or_default();
        assert!(text.contains("panic: worker failed"), "{text}");
        assert!(text.contains(&AppVersion::full_name()));
        assert!(text.contains("status: Imported 3 clips"));
        if let Some(report) = report {
            let mut revealed = None;
            answer(&support, &report, SQDialogResponse::FIRST, |p| revealed = Some(p.to_path_buf()));
            assert_eq!(revealed, Some(report));
        }
        assert_eq!(pending(&support), None);
        let _ = fs::remove_dir_all(&support);
    }
}
