//! Fault injection for the start-failure paths: `SQ_FAULT_INJECT=<fault>` makes one start step fail on purpose, so the
//! error window, the log and the codes can be tested without breaking a real GPU or deleting a real library.
//!
//! It only works in debug builds, or in a release build that also has `SQ_FAULT_INJECT_ALLOW=1` (the Windows VM test of
//! the installed app); a normal release ignores the variable, so no user can trigger it by accident.
//!
//! [`failure`] is the one place that says what an injected fault looks like to the user; every injection site returns
//! that value, so the tests of the codes, the log and the screen cover exactly what the sites produce.

use crate::start_failure::{StartCode, StartFailure};
use sq_draw_shell::ErrorKey;
use sq_gpu::gpu::GpuError;

/// The start steps that can be made to fail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    /// No GPU adapter (`SQS-201`).
    Gpu,
    /// A video library is missing (`SQS-301`).
    Ffmpeg,
    /// A panic before the first frame (`SQS-901`).
    Panic,
    /// The settings file is damaged (`SQS-403`).
    Settings,
    /// The project on the command line cannot be opened (`SQS-404`).
    Project,
    /// The bundled fonts are missing (`SQS-303`).
    Fonts,
    /// The settings folder cannot be written (`SQS-401`).
    Support,
    /// No window system (`SQS-101`).
    Display,
}

impl Fault {
    /// The names `SQ_FAULT_INJECT` takes.
    pub const NAMES: [(&'static str, Fault); 8] = [
        ("gpu", Fault::Gpu),
        ("ffmpeg", Fault::Ffmpeg),
        ("panic", Fault::Panic),
        ("settings", Fault::Settings),
        ("project", Fault::Project),
        ("fonts", Fault::Fonts),
        ("support", Fault::Support),
        ("display", Fault::Display),
    ];

    /// The fault a variable value names (any case); `None` for an unknown name.
    pub fn parse(value: &str) -> Option<Fault> {
        let value = value.trim().to_ascii_lowercase();
        Self::NAMES.iter().find(|(name, _)| *name == value).map(|(_, f)| *f)
    }
}

/// The fault asked for, given the variable values and whether this build allows injection.
fn requested(value: Option<&str>, allow_var: Option<&str>, debug_build: bool) -> Option<Fault> {
    let allowed = debug_build || allow_var == Some("1");
    value.filter(|_| allowed).and_then(Fault::parse)
}

/// The fault this process was asked to inject.
pub fn current() -> Option<Fault> {
    requested(
        std::env::var("SQ_FAULT_INJECT").ok().as_deref(),
        std::env::var("SQ_FAULT_INJECT_ALLOW").ok().as_deref(),
        cfg!(debug_assertions),
    )
}

/// The key the error window presses by itself once its first frame is on screen (`SQ_FAULT_INJECT_PRESS=close|primary`),
/// for runs that have no one to click: the harness checks that Close ends the run with a failure, that Try Again starts
/// again and that Continue goes on. Same gate as the faults themselves.
fn pressed(value: Option<&str>, allow_var: Option<&str>, debug_build: bool) -> Option<ErrorKey> {
    let allowed = debug_build || allow_var == Some("1");
    match value.filter(|_| allowed)?.trim().to_ascii_lowercase().as_str() {
        "close" => Some(ErrorKey::Escape),
        "primary" => Some(ErrorKey::Enter),
        _ => None,
    }
}

/// The key to press by itself, if the run asked for one.
pub fn auto_press() -> Option<ErrorKey> {
    pressed(
        std::env::var("SQ_FAULT_INJECT_PRESS").ok().as_deref(),
        std::env::var("SQ_FAULT_INJECT_ALLOW").ok().as_deref(),
        cfg!(debug_assertions),
    )
}

/// Whether `fault` is the injected one.
pub fn active(fault: Fault) -> bool {
    current() == Some(fault)
}

/// The message of the injected start panic.
pub const PANIC_MESSAGE: &str = "injected fault (SQ_FAULT_INJECT=panic)";

/// What `fault` looks like to the user: the same value the real failure of that step produces.
pub fn failure(fault: Fault) -> StartFailure {
    let tag = |name: &str| format!("injected fault (SQ_FAULT_INJECT={name})");
    match fault {
        Fault::Gpu => StartFailure::from_gpu(&GpuError::NoAdapter(tag("gpu"))),
        Fault::Ffmpeg => StartFailure::new(
            StartCode::FfmpegMissing,
            "loading the video libraries",
            format!("avcodec-injected.dll: {}", tag("ffmpeg")),
        ),
        Fault::Panic => StartFailure::from_panic(PANIC_MESSAGE, "fault injection"),
        Fault::Settings => StartFailure::new(StartCode::SettingsDamaged, "reading the settings", tag("settings")),
        Fault::Project => StartFailure::new(StartCode::ProjectOpen, "opening the project", tag("project")),
        Fault::Fonts => StartFailure::new(StartCode::FontsMissing, "loading the fonts", tag("fonts")),
        Fault::Support => StartFailure::new(StartCode::SupportFolder, "writing the settings folder", tag("support")),
        Fault::Display => StartFailure::new(StartCode::NoDisplay, "connecting to the window system", tag("display")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw_shell::ErrorPrimary;

    #[test]
    fn every_injected_fault_has_its_code_and_builds_a_screen_that_names_it() {
        let expected = [
            (Fault::Gpu, "SQS-201", true),
            (Fault::Ffmpeg, "SQS-301", true),
            (Fault::Panic, "SQS-901", true),
            (Fault::Settings, "SQS-403", false),
            (Fault::Project, "SQS-404", false),
            (Fault::Fonts, "SQS-303", true),
            (Fault::Support, "SQS-401", true),
            (Fault::Display, "SQS-101", true),
        ];
        assert_eq!(expected.len(), Fault::NAMES.len(), "a new fault needs a row here");
        for (fault, code, fatal) in expected {
            let failure = failure(fault);
            assert_eq!(failure.code.text(), code, "{fault:?}");
            assert_eq!(failure.is_fatal(), fatal, "{fault:?}");
            let screen = failure.screen(Some(std::path::PathBuf::from("/tmp/sq.log")));
            assert_eq!(screen.code, code);
            assert!(screen.system_line.contains("injected fault"), "{fault:?}: {}", screen.system_line);
            assert!(screen.copy_text.contains(&format!("Error {code}:")));
            let want = if fatal { ErrorPrimary::TryAgain } else { ErrorPrimary::Continue };
            assert_eq!(screen.primary, want, "{fault:?}");
        }
    }

    #[test]
    fn an_injected_failure_is_written_to_the_log_with_its_code() {
        let dir = std::env::temp_dir().join(format!("sq-fault-log-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        crate::applog::init(&dir, crate::applog::Level::Info);
        let screen = failure(Fault::Gpu).record();
        let logged = crate::applog::recent_lines().join("\n");
        assert!(logged.contains("start failed SQS-201"), "{logged}");
        assert!(logged.contains("injected fault (SQ_FAULT_INJECT=gpu)"), "{logged}");
        assert!(screen.log.is_some_and(|p| p.ends_with("sq.log")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn every_name_parses_in_any_case_and_unknown_names_do_not() {
        for (name, fault) in Fault::NAMES {
            assert_eq!(Fault::parse(name), Some(fault));
            assert_eq!(Fault::parse(&name.to_uppercase()), Some(fault));
        }
        assert_eq!(Fault::parse("gpuu"), None);
        assert_eq!(Fault::parse(""), None);
    }

    #[test]
    fn the_auto_press_names_a_key_and_follows_the_same_gate() {
        assert_eq!(pressed(Some("close"), None, true), Some(ErrorKey::Escape));
        assert_eq!(pressed(Some("PRIMARY"), None, true), Some(ErrorKey::Enter));
        assert_eq!(pressed(Some("primary"), None, false), None);
        assert_eq!(pressed(Some("primary"), Some("1"), false), Some(ErrorKey::Enter));
        assert_eq!(pressed(Some("copy"), None, true), None);
    }

    #[test]
    fn a_release_build_ignores_the_variable_unless_it_is_allowed() {
        assert_eq!(requested(Some("gpu"), None, false), None);
        assert_eq!(requested(Some("gpu"), Some("0"), false), None);
        assert_eq!(requested(Some("gpu"), Some("1"), false), Some(Fault::Gpu));
        assert_eq!(requested(Some("gpu"), None, true), Some(Fault::Gpu));
        assert_eq!(requested(None, Some("1"), true), None);
    }
}
