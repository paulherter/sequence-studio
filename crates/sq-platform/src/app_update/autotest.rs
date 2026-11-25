//! The pure parts of the updater's UI-free test hook (`SQ_UPDATE_AUTOTEST`): the mode, the log line, and the environment a
//! relaunched app must get so it stays windowless. The driver itself lives in the app (`update_autotest.rs`).
//!
//! `SQ_UPDATE_AUTOTEST=update|later` runs check, download, verify and install without any window or input; `report` only
//! logs one `started` line. `SQ_UPDATE_AUTOTEST_LOG=<file>` also receives every line. Unset = no change to the app.

use std::io::Write;
use std::path::Path;

/// The switch that turns the hook on.
pub const MODE_VAR: &str = "SQ_UPDATE_AUTOTEST";
/// The file that also receives every log line.
pub const LOG_VAR: &str = "SQ_UPDATE_AUTOTEST_LOG";
/// Every line starts with this.
pub const LINE_PREFIX: &str = "sq-update-autotest:";

/// What the hook does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutotestMode {
    /// The "Restart to Update" path: install, restart the new version, quit.
    Update,
    /// The "Later" path: install without a restart, quit.
    Later,
    /// Log what version started, then quit (the relaunched app of an `update` run).
    Report,
}

impl AutotestMode {
    /// The mode named by `text`; anything else (also empty) is `None`, so a typo never runs an install.
    pub fn parse(text: &str) -> Option<Self> {
        match text.trim() {
            "update" => Some(Self::Update),
            "later" => Some(Self::Later),
            "report" => Some(Self::Report),
            _ => None,
        }
    }

    /// The mode of this process's environment.
    pub fn from_env() -> Option<Self> {
        Self::parse(&std::env::var(MODE_VAR).ok()?)
    }

    /// Whether the new version is started after the install.
    pub fn restarts(self) -> bool {
        self == Self::Update
    }
}

/// One log line: `sq-update-autotest: <step> <detail>` (no trailing space without a detail, never a line break).
pub fn step_line(step: &str, detail: &str) -> String {
    let detail = detail.replace(['\n', '\r'], " ");
    let detail = detail.trim();
    if detail.is_empty() { format!("{LINE_PREFIX} {step}") } else { format!("{LINE_PREFIX} {step} {detail}") }
}

/// Writes a line to stderr and, when given, appends it to the log file.
pub fn log(log_file: Option<&Path>, step: &str, detail: &str) {
    let line = step_line(step, detail);
    eprintln!("{line}");
    if let Some(file) = log_file
        && let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(file)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// The variables the relaunched app needs to stay windowless and report: the mode becomes `report`, the log file and the
/// no-external-open switch carry over. Empty when the hook is off, so a normal restart is untouched. `get` reads one variable.
pub fn relaunch_env(get: &dyn Fn(&str) -> Option<String>) -> Vec<(String, String)> {
    if get(MODE_VAR).and_then(|v| AutotestMode::parse(&v)).is_none() {
        return Vec::new();
    }
    let mut env = vec![(MODE_VAR.to_string(), "report".to_string())];
    if let Some(file) = get(LOG_VAR).filter(|v| !v.is_empty()) {
        env.push((LOG_VAR.to_string(), file));
    }
    env.push(("SQ_NO_EXTERNAL_OPEN".to_string(), "1".to_string()));
    env
}

/// [`relaunch_env`] for this process.
pub fn relaunch_env_now() -> Vec<(String, String)> {
    relaunch_env(&|k| std::env::var(k).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string())
    }

    #[test]
    fn modes_parse_and_a_typo_runs_nothing() {
        assert_eq!(AutotestMode::parse("update"), Some(AutotestMode::Update));
        assert_eq!(AutotestMode::parse(" later\n"), Some(AutotestMode::Later));
        assert_eq!(AutotestMode::parse("report"), Some(AutotestMode::Report));
        assert_eq!(AutotestMode::parse("Update"), None);
        assert_eq!(AutotestMode::parse(""), None);
        assert!(AutotestMode::Update.restarts());
        assert!(!AutotestMode::Later.restarts() && !AutotestMode::Report.restarts());
    }

    #[test]
    fn a_log_line_is_one_line_with_the_prefix() {
        assert_eq!(
            step_line("check", "feed=http://127.0.0.1:1/x"),
            "sq-update-autotest: check feed=http://127.0.0.1:1/x"
        );
        assert_eq!(step_line("quit", ""), "sq-update-autotest: quit");
        assert_eq!(step_line("failed", "a\nb"), "sq-update-autotest: failed a b");
    }

    #[test]
    fn the_relaunched_app_is_told_to_report_and_stay_windowless() {
        let get = env_of(&[(MODE_VAR, "update"), (LOG_VAR, "/t/log.txt")]);
        assert_eq!(
            relaunch_env(&get),
            vec![
                (MODE_VAR.to_string(), "report".to_string()),
                (LOG_VAR.to_string(), "/t/log.txt".to_string()),
                ("SQ_NO_EXTERNAL_OPEN".to_string(), "1".to_string()),
            ]
        );
        assert!(relaunch_env(&env_of(&[(LOG_VAR, "/t/log.txt")])).is_empty(), "hook off: nothing carried");
        assert!(relaunch_env(&env_of(&[(MODE_VAR, "bogus")])).is_empty());
    }
}
