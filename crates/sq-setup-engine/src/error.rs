//! The `SQI-` codes (`SQI` = Sequence Studio Installer): what failed, the sentence the screen shows and whether Try Again
//! makes sense. The error screen itself is `sq_draw_shell::ErrorView`, shared with the app's start failures (`SQS-`).
//! Design: `design/installer/spec.md` section 11.

use crate::job::Job;
use std::path::{Path, PathBuf};

/// One way a setup job can fail. The number is what the user reads out to support.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    /// The payload's hash does not match: a damaged download.
    PayloadDamaged,
    /// Access denied (os 5).
    AccessDenied,
    /// The running app did not close in time.
    AppStillOpen,
    /// No space left (os 112).
    NoSpace,
    /// A file is in use (os 32).
    FileInUse,
    /// The registry refused a value.
    Registry,
    /// The Start menu or desktop shortcut could not be made.
    Shortcut,
    /// The path is too long (os 206).
    PathTooLong,
    /// The installed app could not be started by the Open button (the files are installed).
    AppNotStarted,
    /// Anything else on install or update: the OS message.
    Other,
    /// Uninstall: files in use.
    UninstallInUse,
    /// Uninstall: some files stay.
    UninstallLeftovers,
    /// Linux: the data folder is not writable.
    LinuxNotWritable,
    /// Linux: the AppImage could not be moved.
    LinuxMoveFailed,
    /// Linux: anything else.
    LinuxOther,
}

impl ErrorCode {
    pub const ALL: [ErrorCode; 15] = [
        ErrorCode::PayloadDamaged,
        ErrorCode::AccessDenied,
        ErrorCode::AppStillOpen,
        ErrorCode::NoSpace,
        ErrorCode::FileInUse,
        ErrorCode::Registry,
        ErrorCode::Shortcut,
        ErrorCode::PathTooLong,
        ErrorCode::AppNotStarted,
        ErrorCode::Other,
        ErrorCode::UninstallInUse,
        ErrorCode::UninstallLeftovers,
        ErrorCode::LinuxNotWritable,
        ErrorCode::LinuxMoveFailed,
        ErrorCode::LinuxOther,
    ];

    pub fn number(self) -> u16 {
        match self {
            ErrorCode::PayloadDamaged => 101,
            ErrorCode::AccessDenied => 102,
            ErrorCode::AppStillOpen => 103,
            ErrorCode::NoSpace => 104,
            ErrorCode::FileInUse => 105,
            ErrorCode::Registry => 106,
            ErrorCode::Shortcut => 107,
            ErrorCode::PathTooLong => 108,
            ErrorCode::AppNotStarted => 109,
            ErrorCode::Other => 199,
            ErrorCode::UninstallInUse => 201,
            ErrorCode::UninstallLeftovers => 202,
            ErrorCode::LinuxNotWritable => 301,
            ErrorCode::LinuxMoveFailed => 302,
            ErrorCode::LinuxOther => 399,
        }
    }

    /// `SQI-104`.
    pub fn text(self) -> String {
        format!("SQI-{}", self.number())
    }

    /// The code for a number a lower layer reports (the Linux file work lives in `sq-platform`).
    pub fn from_number(number: u16) -> Option<ErrorCode> {
        ErrorCode::ALL.into_iter().find(|c| c.number() == number)
    }

    /// Whether Try Again is offered. A damaged download needs a new download, and a failed start has no job to run again.
    pub fn retryable(self) -> bool {
        !matches!(self, ErrorCode::PayloadDamaged | ErrorCode::AppNotStarted)
    }

    /// The code for an I/O error met while `job` ran: the OS numbers the spec names, else the job's catch-all.
    pub fn from_io(job: &Job, error: &std::io::Error) -> ErrorCode {
        if job.is_linux() {
            let denied = error.kind() == std::io::ErrorKind::PermissionDenied;
            return if job.removes() || denied { ErrorCode::LinuxNotWritable } else { ErrorCode::LinuxOther };
        }
        match (error.raw_os_error(), job.removes()) {
            (Some(5), _) => ErrorCode::AccessDenied,
            (Some(32), true) => ErrorCode::UninstallInUse,
            (Some(32), false) => ErrorCode::FileInUse,
            (Some(112), _) => ErrorCode::NoSpace,
            (Some(206), _) => ErrorCode::PathTooLong,
            _ => ErrorCode::Other,
        }
    }

    /// The error screen's title when the code has its own: the job did not fail, something after it did.
    fn title(self) -> Option<&'static str> {
        (self == ErrorCode::AppNotStarted).then_some("Sequence Studio could not start")
    }

    /// The reason sentence, without the closing state sentence. `space` fills `SQI-104`.
    fn reason(self, space: Option<&SpaceFacts>) -> String {
        match self {
            ErrorCode::PayloadDamaged => {
                "The setup file is damaged. Download it again from getsequencestudio.com.".into()
            }
            ErrorCode::AccessDenied => {
                "Windows didn't allow writing to this folder. Pick a folder in your user folder.".into()
            }
            ErrorCode::AppStillOpen | ErrorCode::UninstallInUse => {
                "Sequence Studio is still open. Close it and try again.".into()
            }
            ErrorCode::NoSpace => match space {
                Some(s) => format!(
                    "Drive {} has {} free; Sequence Studio needs {}.",
                    s.drive,
                    crate::format_size(s.free),
                    crate::format_size(s.need)
                ),
                None => "There is not enough free space for Sequence Studio.".into(),
            },
            ErrorCode::FileInUse => "Another program is using a Sequence Studio file. Close it and try again.".into(),
            ErrorCode::Registry => "Windows refused to save the Start menu entry or the .sqproj link.".into(),
            ErrorCode::Shortcut => "The Start menu shortcut couldn't be created.".into(),
            ErrorCode::PathTooLong => "The folder path is too long. Pick a shorter one.".into(),
            ErrorCode::AppNotStarted => "Windows couldn't start Sequence Studio.".into(),
            ErrorCode::Other => "Windows reported a problem while writing the files.".into(),
            ErrorCode::UninstallLeftovers => "Some files couldn't be removed. They are listed in the log.".into(),
            ErrorCode::LinuxNotWritable => "Your user folder didn't allow adding the menu entry.".into(),
            ErrorCode::LinuxMoveFailed => "The AppImage couldn't be moved to this folder.".into(),
            ErrorCode::LinuxOther => "Something went wrong while adding the menu entry.".into(),
        }
    }
}

/// The numbers `SQI-104` names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpaceFacts {
    /// The drive letter or mount point.
    pub drive: String,
    pub free: u64,
    pub need: u64,
}

/// A failed setup step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SetupError {
    pub code: ErrorCode,
    /// What was being done: `copying files`.
    pub step: String,
    /// The file or folder concerned.
    pub path: Option<PathBuf>,
    /// The system's own words: `os error 112 \u{b7} There is not enough space on the disk.`
    pub system: String,
    /// Boxed so a `Result<_, SetupError>` stays small.
    pub space: Option<Box<SpaceFacts>>,
}

impl SetupError {
    pub fn new(code: ErrorCode, step: &str, system: impl Into<String>) -> SetupError {
        SetupError { code, step: step.to_string(), path: None, system: system.into(), space: None }
    }

    pub fn with_path(mut self, path: &Path) -> SetupError {
        self.path = Some(path.to_path_buf());
        self
    }

    pub fn with_space(mut self, space: SpaceFacts) -> SetupError {
        self.space = Some(Box::new(space));
        self
    }

    /// A failed file operation, its code chosen by the OS error and the job.
    pub fn from_io(job: &Job, step: &str, path: &Path, error: &std::io::Error) -> SetupError {
        SetupError::new(ErrorCode::from_io(job, error), step, describe_io(error)).with_path(path)
    }

    /// The sentence the error screen shows: the reason, then what state the computer is in.
    pub fn sentence(&self, job: &Job) -> String {
        let state = match self.code {
            ErrorCode::AppNotStarted => "It is installed; open it from the Start menu.",
            _ => job.state_after_failure(),
        };
        format!("{} {state}", self.code.reason(self.space.as_deref()))
    }

    /// The title of the error screen: the job's, unless the code names what went wrong itself.
    pub fn title(&self, job: &Job) -> &'static str {
        self.code.title().unwrap_or_else(|| job.failure_title())
    }

    /// `SQI-104 \u{b7} copying files C:\\...`, the first line of the details well.
    pub fn step_line(&self) -> String {
        let path = self.path.as_ref().map(|p| format!(" {}", p.display())).unwrap_or_default();
        format!("{} \u{b7} {}{path}", self.code.text(), self.step)
    }
}

impl std::fmt::Display for SetupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} {}: {}", self.code.text(), self.step, self.system)
    }
}

/// `os error 5 \u{b7} Access is denied.` from an I/O error: the number when the OS gave one, then its message.
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
    use crate::version::Version;

    #[test]
    fn every_code_has_its_own_number_and_a_sentence_that_fits_two_lines_with_the_state() {
        let mut seen = std::collections::BTreeSet::new();
        for code in ErrorCode::ALL {
            assert!(seen.insert(code.number()), "{code:?} repeats a number");
            assert_eq!(ErrorCode::from_number(code.number()), Some(code));
            for job in [Job::Install, Job::Update { from: Version::new(0, 1, 2) }, Job::Uninstall, Job::LinuxAdd] {
                let space = SpaceFacts { drive: "C:".into(), free: 120 << 20, need: 412 << 20 };
                let sentence = SetupError::new(code, "step", "system").with_space(space).sentence(&job);
                assert!(sentence.chars().count() <= 150, "{code:?} needs more than two lines: {sentence}");
                assert!(sentence.ends_with('.'), "{sentence}");
            }
        }
        assert_eq!(ErrorCode::NoSpace.text(), "SQI-104");
        assert_eq!(ErrorCode::from_number(7), None);
    }

    #[test]
    fn the_no_space_sentence_names_drive_free_and_needed_space() {
        let space = SpaceFacts { drive: "C:".into(), free: 120 * 1024 * 1024, need: 412 * 1024 * 1024 };
        let sentence = SetupError::new(ErrorCode::NoSpace, "copying files", "os error 112")
            .with_space(space)
            .sentence(&Job::Install);
        assert_eq!(sentence, "Drive C: has 120 MB free; Sequence Studio needs 412 MB. Nothing was installed.");
    }

    #[test]
    fn only_a_damaged_download_and_a_failed_start_cannot_be_retried() {
        for code in ErrorCode::ALL {
            assert_eq!(
                code.retryable(),
                !matches!(code, ErrorCode::PayloadDamaged | ErrorCode::AppNotStarted),
                "{code:?}"
            );
        }
    }

    #[test]
    fn a_failed_start_says_the_app_is_installed_and_has_its_own_title() {
        let error = SetupError::new(
            ErrorCode::AppNotStarted,
            "starting Sequence Studio",
            "os error 5 \u{b7} Access is denied.",
        );
        assert_eq!(error.code.text(), "SQI-109");
        assert_eq!(
            error.sentence(&Job::Install),
            "Windows couldn't start Sequence Studio. It is installed; open it from the Start menu."
        );
        assert_eq!(error.title(&Job::Install), "Sequence Studio could not start");
        let other = SetupError::new(ErrorCode::NoSpace, "copying files", "os error 112");
        assert_eq!(other.title(&Job::Install), "Installation failed");
    }

    #[test]
    fn os_errors_are_sorted_into_the_codes_of_the_spec() {
        let io = |n: i32| std::io::Error::from_raw_os_error(n);
        let code = |job: &Job, n: i32| ErrorCode::from_io(job, &io(n));
        assert_eq!(code(&Job::Install, 5), ErrorCode::AccessDenied);
        assert_eq!(code(&Job::Install, 32), ErrorCode::FileInUse);
        assert_eq!(code(&Job::Uninstall, 32), ErrorCode::UninstallInUse);
        assert_eq!(code(&Job::Install, 112), ErrorCode::NoSpace);
        assert_eq!(code(&Job::Install, 206), ErrorCode::PathTooLong);
        assert_eq!(code(&Job::Install, 1), ErrorCode::Other);
        assert_eq!(code(&Job::LinuxAdd, 13), ErrorCode::LinuxNotWritable);
        assert_eq!(code(&Job::LinuxAdd, 28), ErrorCode::LinuxOther);
    }

    #[test]
    fn the_step_line_and_the_io_text_read_like_the_design() {
        let e = SetupError::from_io(
            &Job::Install,
            "Copying files (198 of 412 MB)",
            Path::new("C:\\Programs\\sq_media.dll"),
            &std::io::Error::from_raw_os_error(112),
        );
        assert!(e.step_line().starts_with("SQI-104 \u{b7} Copying files (198 of 412 MB) C:"), "{}", e.step_line());
        assert!(e.system.starts_with("os error 112 \u{b7} "), "{}", e.system);
        assert!(!e.system.contains("(os error"), "{}", e.system);
        assert_eq!(describe_io(&std::io::Error::other("boom")), "boom");
    }
}
