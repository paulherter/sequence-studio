//! Every way the app can fail to start, as one value: a code (`SQS-` = Sequence Studio Start), a step, a path and the
//! system's own words. The window that shows it is `error_window.rs` (the screen itself is `sq_draw_shell::ErrorView`,
//! shared with the installer); this file owns the codes, the sentences, the `Copy details` text and the log lines.
//!
//! Code ranges: 1xx window system, 2xx graphics, 3xx files and libraries, 4xx the user's own data, 9xx anything else.

use crate::applog;
use sq_draw_shell::{ErrorPrimary, ErrorScreen};
use sq_gpu::gpu::GpuError;
use sq_uikit::app_version::AppVersion;
use std::path::{Path, PathBuf};

/// One way the start can fail. The number is what the user reads out to support.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartCode {
    /// Linux: neither Wayland nor X11 answered.
    NoDisplay,
    /// The window system's event loop did not start.
    EventLoop,
    /// The window could not be created.
    WindowCreate,
    GpuNoAdapter,
    /// The adapter lacks a feature the renderer needs.
    GpuTooOld,
    GpuDevice,
    /// The window's surface cannot show GPU frames.
    GpuPresent,
    /// A shader or pipeline did not build.
    GpuShaders,
    FfmpegMissing,
    FfmpegVersion,
    FontsMissing,
    /// The settings folder cannot be written.
    SupportFolder,
    /// The log folder cannot be written; the log moves to the temp folder and the start goes on.
    LogFolder,
    /// The settings file was damaged and was put aside.
    SettingsDamaged,
    /// The project given on the command line could not be opened.
    ProjectOpen,
    Panic,
    /// The last start never reached its first frame (a crash or a kill while starting).
    StartInterrupted,
    Other,
}

impl StartCode {
    #[cfg(test)]
    pub const ALL: [StartCode; 18] = [
        StartCode::NoDisplay,
        StartCode::EventLoop,
        StartCode::WindowCreate,
        StartCode::GpuNoAdapter,
        StartCode::GpuTooOld,
        StartCode::GpuDevice,
        StartCode::GpuPresent,
        StartCode::GpuShaders,
        StartCode::FfmpegMissing,
        StartCode::FfmpegVersion,
        StartCode::FontsMissing,
        StartCode::SupportFolder,
        StartCode::LogFolder,
        StartCode::SettingsDamaged,
        StartCode::ProjectOpen,
        StartCode::Panic,
        StartCode::StartInterrupted,
        StartCode::Other,
    ];

    pub fn number(self) -> u16 {
        match self {
            StartCode::NoDisplay => 101,
            StartCode::EventLoop => 102,
            StartCode::WindowCreate => 103,
            StartCode::GpuNoAdapter => 201,
            StartCode::GpuTooOld => 202,
            StartCode::GpuDevice => 203,
            StartCode::GpuPresent => 204,
            StartCode::GpuShaders => 205,
            StartCode::FfmpegMissing => 301,
            StartCode::FfmpegVersion => 302,
            StartCode::FontsMissing => 303,
            StartCode::SupportFolder => 401,
            StartCode::LogFolder => 402,
            StartCode::SettingsDamaged => 403,
            StartCode::ProjectOpen => 404,
            StartCode::Panic => 901,
            StartCode::StartInterrupted => 902,
            StartCode::Other => 999,
        }
    }

    /// `SQS-201`.
    pub fn text(self) -> String {
        format!("SQS-{}", self.number())
    }

    /// The sentence the screen shows (before the state sentence).
    fn reason(self) -> &'static str {
        match self {
            StartCode::NoDisplay => "No window system answered. Start Sequence Studio from a desktop session.",
            StartCode::EventLoop => "The window system didn't start. Log out and in again, then try again.",
            StartCode::WindowCreate => "Sequence Studio couldn't open its window. Try again, or restart the computer.",
            StartCode::GpuNoAdapter => "No graphics adapter was found. Install or update your graphics driver.",
            StartCode::GpuTooOld => {
                "This graphics card is too old for Sequence Studio. Update its driver or use a newer card."
            }
            StartCode::GpuDevice => "The graphics driver refused to start. Update the driver and try again.",
            StartCode::GpuPresent => {
                "This display can't show Sequence Studio's picture. Start it on a desktop with graphics support."
            }
            StartCode::GpuShaders => {
                "The graphics driver couldn't build Sequence Studio's drawing programs. Update it and try again."
            }
            StartCode::FfmpegMissing => {
                "A video library is missing or damaged. Install Sequence Studio again to restore it."
            }
            StartCode::FfmpegVersion => {
                "The video libraries don't match this version of Sequence Studio. Install it again."
            }
            StartCode::FontsMissing => "Sequence Studio's font files are missing. Install it again to restore them.",
            StartCode::SupportFolder => {
                "Sequence Studio can't write to its settings folder. Free up space or fix its permissions."
            }
            StartCode::LogFolder => {
                "Sequence Studio can't write its log file here, so it writes it to the temp folder."
            }
            StartCode::SettingsDamaged => {
                "Your settings file was damaged, so Sequence Studio starts with the default settings."
            }
            StartCode::ProjectOpen => "The project couldn't be opened, so Sequence Studio starts without it.",
            StartCode::Panic => "Sequence Studio ran into an unexpected error while starting.",
            StartCode::StartInterrupted => {
                "Sequence Studio stopped while it was starting last time. The log and a crash report may say why."
            }
            StartCode::Other => "Sequence Studio couldn't start.",
        }
    }

    /// What state things are in, closing the sentence.
    fn state(self) -> &'static str {
        match self {
            StartCode::SettingsDamaged => "The damaged file was kept beside the new one.",
            StartCode::ProjectOpen => "The project file was not changed.",
            StartCode::LogFolder => "Nothing else was changed.",
            _ => "Nothing was changed.",
        }
    }

    /// `Continue` when the app can go on after the problem was worked around, else `Try Again`.
    pub fn primary(self) -> ErrorPrimary {
        match self {
            StartCode::SettingsDamaged
            | StartCode::ProjectOpen
            | StartCode::LogFolder
            | StartCode::StartInterrupted => ErrorPrimary::Continue,
            _ => ErrorPrimary::TryAgain,
        }
    }

    /// Whether the app cannot start (the window offers `Try Again` and the start stops).
    pub fn is_fatal(self) -> bool {
        self.primary() == ErrorPrimary::TryAgain
    }
}

/// One failed start step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartFailure {
    pub code: StartCode,
    /// What was being done: `creating the window`.
    pub step: String,
    /// The file or folder concerned.
    pub path: Option<PathBuf>,
    /// The system's own words: `os error 5 · Access is denied.` or the library's message.
    pub system: String,
}

impl std::fmt::Display for StartFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} {}: {}", self.code.text(), self.step, self.system)
    }
}

impl StartFailure {
    pub fn new(code: StartCode, step: &str, system: impl Into<String>) -> StartFailure {
        StartFailure { code, step: step.to_string(), path: None, system: system.into() }
    }

    pub fn with_path(mut self, path: &Path) -> StartFailure {
        self.path = Some(path.to_path_buf());
        self
    }

    /// A failed file operation.
    pub fn from_io(code: StartCode, step: &str, path: &Path, error: &std::io::Error) -> StartFailure {
        StartFailure::new(code, step, describe_io(error)).with_path(path)
    }

    /// The GPU layer's error, sorted by what failed.
    pub fn from_gpu(error: &GpuError) -> StartFailure {
        let code = match error {
            GpuError::NoAdapter(_) => StartCode::GpuNoAdapter,
            GpuError::MissingFeature(_) => StartCode::GpuTooOld,
            GpuError::Device(_) | GpuError::Binding(_) | GpuError::Readback(_) => StartCode::GpuDevice,
            GpuError::Pipeline(_) => StartCode::GpuShaders,
        };
        StartFailure::new(code, "starting the graphics", error.to_string())
    }

    /// A panic caught while starting, with the place the panic hook named.
    pub fn from_panic(message: &str, place: &str) -> StartFailure {
        StartFailure::new(StartCode::Panic, "starting", format!("panic at {place}: {message}"))
    }

    pub fn is_fatal(&self) -> bool {
        self.code.is_fatal()
    }

    /// The sentence: the reason, then the state.
    pub fn sentence(&self) -> String {
        format!("{} {}", self.code.reason(), self.code.state())
    }

    fn title(&self) -> &'static str {
        if self.is_fatal() { "Sequence Studio couldn't start" } else { "Sequence Studio hit a problem" }
    }

    fn step_line(&self) -> String {
        let path = self.path.as_ref().map(|p| format!(" {}", p.display())).unwrap_or_default();
        format!("{} \u{b7} {}{path}", self.code.text(), self.step)
    }

    /// The text `Copy details` puts on the clipboard; the user folder is replaced by `home_token` so it can be shared.
    pub fn copy_text(&self, log: Option<&Path>, system: &str, homes: &[String], home_token: &str) -> String {
        let mut lines = vec![
            format!("{} ({}) on {system}", AppVersion::full_name(), std::env::consts::ARCH),
            format!("Error {}: {}", self.code.text(), self.sentence()),
            format!("Step: {}", self.step),
        ];
        if let Some(path) = &self.path {
            lines.push(format!("Path: {}", path.display()));
        }
        lines.push(format!("System: {}", self.system));
        if let Some(log) = log {
            lines.push(format!("Log: {}", log.display()));
        }
        scrub(&lines.join("\n"), homes, home_token) + "\n"
    }

    /// The screen for this failure. `log` is the file `Open log` shows.
    pub fn screen(&self, log: Option<PathBuf>) -> ErrorScreen {
        let homes = home_folders();
        let token = if cfg!(windows) { "%USERPROFILE%" } else { "~" };
        let system = format!("{} {}", std::env::consts::OS, std::env::consts::ARCH);
        ErrorScreen {
            title: self.title().to_string(),
            code: self.code.text(),
            sentence: self.sentence(),
            step_line: scrub(&self.step_line(), &homes, token),
            system_line: scrub(&self.system, &homes, token),
            copy_text: self.copy_text(log.as_deref(), &system, &homes, token),
            log,
            primary: self.code.primary(),
        }
    }

    /// Writes the failure into the app log (one error line and its details) and returns the screen for it. The log is
    /// `sq.log` of the log folder, or the temp folder's when that one could not be written (`applog::init`).
    pub fn record(&self) -> ErrorScreen {
        applog::error(&format!("start failed {}: {}", self.code.text(), self.code.reason()));
        applog::error(&format!("  {}", self.step_line()));
        applog::error(&format!("  system: {}", self.system));
        self.screen(log_file())
    }
}

/// The log file `Open log` shows: `sq.log` of the folder `applog` writes to.
pub fn log_file() -> Option<PathBuf> {
    applog::directory().map(|d| d.join("sq.log"))
}

/// The user's home folders as the system spells them, longest first.
fn home_folders() -> Vec<String> {
    let mut homes: Vec<String> = ["HOME", "USERPROFILE"].iter().filter_map(|k| std::env::var(k).ok()).collect();
    homes.sort_by_key(|h| std::cmp::Reverse(h.len()));
    homes
}

/// `text` with every home folder replaced by `token` (a home of one character, such as `/`, is left alone).
fn scrub(text: &str, homes: &[String], token: &str) -> String {
    homes.iter().filter(|h| h.chars().count() > 1).fold(text.to_string(), |t, h| t.replace(h.as_str(), token))
}

/// `os error 5 · Access is denied.` from an I/O error (the number when the OS gave one, then its message).
pub fn describe_io(error: &std::io::Error) -> String {
    let text = error.to_string();
    match error.raw_os_error() {
        Some(n) => {
            let message = text.strip_suffix(&format!(" (os error {n})")).unwrap_or(&text);
            format!("os error {n} \u{b7} {message}")
        }
        None => text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_code_has_its_own_number_in_its_range_and_a_short_sentence() {
        let mut seen = std::collections::BTreeSet::new();
        for code in StartCode::ALL {
            assert!(seen.insert(code.number()), "{code:?} repeats a number");
            assert!((101..=999).contains(&code.number()));
            let sentence = StartFailure::new(code, "step", "system").sentence();
            assert!(sentence.chars().count() <= 150, "{code:?} needs more than two lines: {sentence}");
            assert!(sentence.ends_with('.'), "{sentence}");
        }
        assert_eq!(StartCode::GpuNoAdapter.text(), "SQS-201");
    }

    #[test]
    fn a_gpu_error_is_sorted_into_the_gpu_codes() {
        let code = |e: GpuError| StartFailure::from_gpu(&e).code;
        assert_eq!(code(GpuError::NoAdapter("none".into())), StartCode::GpuNoAdapter);
        assert_eq!(code(GpuError::MissingFeature("f".into())), StartCode::GpuTooOld);
        assert_eq!(code(GpuError::Device("d".into())), StartCode::GpuDevice);
        assert_eq!(code(GpuError::Pipeline("p".into())), StartCode::GpuShaders);
        let text = StartFailure::from_gpu(&GpuError::NoAdapter("none".into())).system;
        assert_eq!(text, "no GPU adapter: none");
    }

    #[test]
    fn only_the_notices_offer_continue() {
        for code in StartCode::ALL {
            let notice = matches!(
                code,
                StartCode::SettingsDamaged
                    | StartCode::ProjectOpen
                    | StartCode::LogFolder
                    | StartCode::StartInterrupted
            );
            assert_eq!(code.primary() == ErrorPrimary::Continue, notice, "{code:?}");
            assert_eq!(code.is_fatal(), !notice);
        }
    }

    #[test]
    fn an_io_error_reads_as_os_error_and_message() {
        let e = std::io::Error::from_raw_os_error(2);
        let text = describe_io(&e);
        assert!(text.starts_with("os error 2 \u{b7} "), "{text}");
        assert!(!text.contains("(os error"), "the number is not said twice: {text}");
        assert_eq!(describe_io(&std::io::Error::other("boom")), "boom");
    }

    #[test]
    fn the_copy_text_names_version_code_step_path_system_and_log_without_the_home_folder() {
        let f = StartFailure::from_io(
            StartCode::SupportFolder,
            "writing the settings folder",
            Path::new("/home/zoe/.local/share/Sequence Studio"),
            &std::io::Error::from_raw_os_error(13),
        );
        let homes = vec!["/home/zoe".to_string()];
        let log = Path::new("/home/zoe/.local/share/Sequence Studio/Logs/sq.log");
        let text = f.copy_text(Some(log), "linux x86_64", &homes, "~");
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 6, "{text}");
        assert!(lines[0].starts_with("Sequence Studio ") && lines[0].ends_with("on linux x86_64"));
        assert!(lines[1].starts_with("Error SQS-401: Sequence Studio can't write to its settings folder."));
        assert_eq!(lines[2], "Step: writing the settings folder");
        assert_eq!(lines[3], "Path: ~/.local/share/Sequence Studio");
        assert!(lines[4].starts_with("System: os error 13"));
        assert_eq!(lines[5], "Log: ~/.local/share/Sequence Studio/Logs/sq.log");
        assert!(!text.contains("zoe"));
    }

    #[test]
    fn the_screen_carries_the_code_the_two_detail_lines_and_the_log() {
        let f = StartFailure::new(StartCode::GpuNoAdapter, "starting the graphics", "no GPU adapter: none");
        let screen = f.screen(Some(PathBuf::from("/tmp/sq.log")));
        assert_eq!(screen.title, "Sequence Studio couldn't start");
        assert_eq!(screen.code, "SQS-201");
        assert_eq!(screen.step_line, "SQS-201 \u{b7} starting the graphics");
        assert_eq!(screen.system_line, "no GPU adapter: none");
        assert_eq!(screen.primary, ErrorPrimary::TryAgain);
        assert!(screen.copy_text.contains("Log: /tmp/sq.log"));
        let notice = StartFailure::new(StartCode::ProjectOpen, "opening the project", "bad").screen(None);
        assert_eq!(notice.title, "Sequence Studio hit a problem");
        assert_eq!(notice.primary, ErrorPrimary::Continue);
    }

    #[test]
    fn a_panic_failure_names_the_place_and_the_message() {
        let f = StartFailure::from_panic("boom", "src/main.rs:12");
        assert_eq!(f.code, StartCode::Panic);
        assert_eq!(f.system, "panic at src/main.rs:12: boom");
    }
}
