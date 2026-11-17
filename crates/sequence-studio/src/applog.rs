//! The app log: a rolling text file in `Logs/` of the support folder, levels from `SQ_LOG`.
//! Std only: lines are `<unix seconds> <LEVEL> <text>`; `sq.log` rolls to `sq.1.log`, `sq.2.log` at 1 MB (the names
//! `CrashReport::log_tail` reads). The last lines are also kept in memory for the crash report.

use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const ROLL_BYTES: u64 = 1_000_000;
const FILES: usize = 3;
/// Lines kept for the crash report.
const RECENT: usize = 30;
/// Longest line written; a status line never carries more than a sentence.
const MAX_LINE: usize = 500;

/// Severity, most important first; a line is written when its level is at most the configured one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Error,
    Warn,
    Info,
    Debug,
}

impl Level {
    /// `SQ_LOG` values (`error`, `warn`, `info`, `debug`, any case); anything else is `Info`.
    pub fn parse(text: Option<&str>) -> Level {
        match text.map(str::to_ascii_lowercase).as_deref() {
            Some("error") => Level::Error,
            Some("warn") => Level::Warn,
            Some("debug") => Level::Debug,
            _ => Level::Info,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Level::Error => "ERROR",
            Level::Warn => "WARN",
            Level::Info => "INFO",
            Level::Debug => "DEBUG",
        }
    }
}

struct Logger {
    dir: PathBuf,
    level: Level,
    file: Option<File>,
    size: u64,
    recent: VecDeque<String>,
}

static LOGGER: OnceLock<Mutex<Logger>> = OnceLock::new();

fn logger() -> Option<MutexGuard<'static, Logger>> {
    // A panic while logging must not silence the crash report that follows.
    LOGGER.get().map(|m| m.lock().unwrap_or_else(std::sync::PoisonError::into_inner))
}

/// Opens `sq.log` in `dir` (created) for appending; `None` when the folder cannot be made or written.
fn open_log(dir: &Path) -> Option<File> {
    fs::create_dir_all(dir).ok()?;
    OpenOptions::new().create(true).append(true).open(dir.join("sq.log")).ok()
}

/// Where the log goes when its own folder cannot be written (a read-only profile, a full disk, a locked-down machine).
pub fn fallback_dir() -> PathBuf {
    std::env::temp_dir().join("Sequence Studio Logs")
}

/// Starts logging into `dir` (created); a second call keeps the first. When `dir` cannot be written the log goes to
/// [`fallback_dir`] instead, so a start failure always leaves a file the error window can open. Returns whether `dir`
/// itself was used.
pub fn init(dir: &Path, level: Level) -> bool {
    let (dir_used, file, primary) = match open_log(dir) {
        Some(file) => (dir.to_path_buf(), Some(file), true),
        None => (fallback_dir(), open_log(&fallback_dir()), false),
    };
    let size = fs::metadata(dir_used.join("sq.log")).map_or(0, |m| m.len());
    let _ = LOGGER.set(Mutex::new(Logger { dir: dir_used, level, file, size, recent: VecDeque::new() }));
    primary
}

/// The log folder once `init` ran.
pub fn directory() -> Option<PathBuf> {
    logger().map(|l| l.dir.clone())
}

/// The newest lines (oldest first), for the crash report.
pub fn recent_lines() -> Vec<String> {
    logger().map(|l| l.recent.iter().cloned().collect()).unwrap_or_default()
}

pub fn error(text: &str) {
    log(Level::Error, text);
}

/// Frames drawn per second, one debug line per second. It runs on loop turns, so an idle window (no turns) logs
/// nothing: a missing line means no frames.
pub struct FrameRate {
    since: std::time::Instant,
    frames: u32,
}

impl FrameRate {
    pub fn new() -> Self {
        FrameRate { since: std::time::Instant::now(), frames: 0 }
    }

    pub fn drawn(&mut self) {
        self.frames += 1;
    }

    /// Logs the rate once a second passed since the last line, and only when frames were drawn in it.
    pub fn report(&mut self) -> Option<String> {
        let secs = self.since.elapsed().as_secs_f64();
        if secs < 1.0 {
            return None;
        }
        let line = format!("frames drawn: {:.1}/s", f64::from(self.frames) / secs);
        let n = std::mem::take(&mut self.frames);
        self.since = std::time::Instant::now();
        (n > 0).then(|| {
            debug(&line);
            line
        })
    }
}

pub fn debug(text: &str) {
    log(Level::Debug, text);
}

/// The variant name of a debug-printable value (the text up to the first bracket), for short log lines.
pub fn variant(v: &impl std::fmt::Debug) -> String {
    format!("{v:?}").chars().take_while(|c| c.is_alphanumeric()).collect()
}

pub fn info(text: &str) {
    log(Level::Info, text);
}

fn log(level: Level, text: &str) {
    let Some(mut l) = logger() else { return };
    if level > l.level {
        return;
    }
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let text: String = text.chars().take(MAX_LINE).map(|c| if c.is_control() { ' ' } else { c }).collect();
    let line = format!("{secs} {} {text}", level.name());
    l.write(&line);
    if l.recent.len() == RECENT {
        l.recent.pop_front();
    }
    l.recent.push_back(line);
}

impl Logger {
    fn write(&mut self, line: &str) {
        if self.size >= ROLL_BYTES {
            self.roll();
        }
        if let Some(f) = self.file.as_mut()
            && writeln!(f, "{line}").is_ok()
        {
            self.size += line.len() as u64 + 1;
        }
    }

    /// `sq.log` becomes `sq.1.log`, older ones move up, the oldest goes.
    fn roll(&mut self) {
        self.file = None;
        let name = |n: usize| self.dir.join(if n == 0 { "sq.log".to_string() } else { format!("sq.{n}.log") });
        for n in (0..FILES - 1).rev() {
            let _ = fs::rename(name(n), name(n + 1));
        }
        self.file = OpenOptions::new().create(true).append(true).open(name(0)).ok();
        self.size = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_parse_and_default_to_info() {
        assert_eq!(Level::parse(Some("DEBUG")), Level::Debug);
        assert_eq!(Level::parse(Some("error")), Level::Error);
        assert_eq!(Level::parse(Some("nonsense")), Level::Info);
        assert_eq!(Level::parse(None), Level::Info);
        assert!(Level::Error < Level::Debug);
    }

    #[test]
    fn a_log_folder_that_cannot_be_written_has_a_fallback_in_the_temp_folder() {
        let dir = std::env::temp_dir().join(format!("sq-applog-blocked-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap_or_default();
        let blocker = dir.join("file");
        fs::write(&blocker, b"x").unwrap_or_default();
        assert!(open_log(&blocker.join("Logs")).is_none(), "a folder under a file cannot be made");
        assert!(open_log(&dir.join("Logs")).is_some());
        assert!(fallback_dir().starts_with(std::env::temp_dir()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rolling_keeps_three_files() {
        let dir = std::env::temp_dir().join(format!("sq-applog-roll-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap_or_default();
        let mut l =
            Logger { dir: dir.clone(), level: Level::Info, file: None, size: ROLL_BYTES, recent: VecDeque::new() };
        for round in 0..4 {
            l.write(&format!("line {round}"));
            l.size = ROLL_BYTES;
        }
        let names: Vec<_> = (0..4)
            .map(|n| dir.join(if n == 0 { "sq.log".to_string() } else { format!("sq.{n}.log") }).exists())
            .collect();
        assert_eq!(names, [true, true, true, false]);
        assert_eq!(fs::read_to_string(dir.join("sq.log")).unwrap_or_default().trim(), "line 3");
        let _ = fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod rate_tests {
    use super::FrameRate;

    #[test]
    fn an_idle_window_logs_no_rate_line_and_a_busy_one_logs_once_a_second() {
        let mut r = FrameRate::new();
        assert!(r.report().is_none(), "less than a second");
        r.since -= std::time::Duration::from_secs(2);
        assert!(r.report().is_none(), "no frames: no line");
        r.drawn();
        r.since -= std::time::Duration::from_secs(2);
        assert!(r.report().is_some_and(|l| l.starts_with("frames drawn: 0.5")));
        assert!(r.report().is_none(), "the counter restarted");
    }
}
