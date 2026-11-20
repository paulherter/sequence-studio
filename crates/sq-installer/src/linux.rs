//! The Linux first run: the machine and the services for adding Sequence Studio to the app menu (or updating the entry)
//! from an AppImage. The window is the same [`SetupSession`](crate::session::SetupSession) the Windows installer uses;
//! the file work is `sq_platform::desktop_integration`. Spec: `design/installer/spec.md` §6.7, §6.8, §10.3.

use crate::machine::{Event, Facts, InstallerScreen, JobRequest, LocationCheck, Machine, UpdateKind};
use crate::session::{EventTx, Services, external_open_allowed};
use crate::view::ErrorContext;
use sq_platform::desktop_integration::{self as di, AddEnd, DesktopEnv, DesktopState, SetupFailure};
use sq_setup_engine::{ErrorCode, Job, SetupError, Step, Version, update_kind};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The bar share of the move (`Job::steps`): the entry files follow after it.
const MOVE_SHARE: f64 = 0.85;

/// The setup error of a failed file operation: the code the lower layer chose (301, 302, 399) and its details.
pub fn setup_error(failure: &SetupFailure) -> SetupError {
    let code = ErrorCode::from_number(failure.code).unwrap_or(ErrorCode::LinuxOther);
    let error = SetupError::new(code, &failure.step, failure.system.clone());
    match &failure.path {
        Some(path) => error.with_path(path),
        None => error,
    }
}

/// The question to ask at start, when there is one: the add offer for a never-answered AppImage, the update question for an
/// older integrated one. `None` when the app should just start.
pub fn first_run(env: &DesktopEnv, state: &DesktopState, offers_allowed: bool) -> Option<Machine> {
    if !offers_allowed {
        return None;
    }
    let version = Version::parse(&env.version)?;
    let apps = di::default_apps_dir(env);
    let facts = Facts {
        version: version.clone(),
        app_exe_name: di::INTEGRATED_NAME,
        start_folder: env.home.clone(),
        payload_bytes: 0,
        appimage_dir: env.appimage.parent().map(Path::to_path_buf),
        home: Some(env.home.clone()),
        system_line: format!("Sequence Studio {version} ({}) on Linux", std::env::consts::ARCH),
    };
    let screen = match state {
        DesktopState::Offer => Machine::welcome(Job::LinuxAdd, apps, LocationCheck::Ok { free: u64::MAX }),
        DesktopState::Outdated { installed } => {
            let installed = Version::parse(installed)?;
            // The folder of the integrated file (the update replaces the file inside it), like the add screen shows.
            let location = di::integrated_file(env)?.parent()?.to_path_buf();
            InstallerScreen::Update {
                job: Job::LinuxUpdate { from: installed.clone() },
                kind: update_kind(&version, &installed),
                installed,
                location,
                app_running: false,
            }
        }
        _ => return None,
    };
    // An older AppImage than the integrated one just runs: no question.
    if matches!(&screen, InstallerScreen::Update { kind: UpdateKind::Older | UpdateKind::Same, .. }) {
        return None;
    }
    Some(Machine::new(screen, facts))
}

/// Where the user's home folder is hidden in `Copy details`.
pub fn error_context(env: &DesktopEnv) -> ErrorContext {
    ErrorContext { homes: vec![env.home.display().to_string()], token: "~".into() }
}

/// The services of the Linux window.
pub struct LinuxServices {
    env: DesktopEnv,
}

impl LinuxServices {
    pub fn new(env: DesktopEnv) -> LinuxServices {
        LinuxServices { env }
    }
}

/// Whether a file can be made in the folder, or in the nearest folder that exists above it.
fn writable(folder: &Path) -> bool {
    let Some(parent) = folder.ancestors().find(|p| !p.as_os_str().is_empty() && p.is_dir()) else { return false };
    let probe = parent.join(format!(".sq-setup-probe-{}", std::process::id()));
    let made = std::fs::write(&probe, b"x").is_ok();
    let _ = std::fs::remove_file(&probe);
    made
}

impl Services for LinuxServices {
    fn choose_folder(&mut self, start: &Path) -> Option<PathBuf> {
        rfd::FileDialog::new().set_directory(start).set_title("Choose a folder").pick_folder()
    }

    fn check_location(&mut self, location: &Path) -> LocationCheck {
        if writable(location) { LocationCheck::Ok { free: u64::MAX } } else { LocationCheck::NotWritable }
    }

    fn start_job(&mut self, request: JobRequest, tx: EventTx, cancel: Arc<AtomicBool>) {
        let env = self.env.clone();
        std::thread::spawn(move || {
            let mut progress = |done: u64, total: u64| {
                let share = if total == 0 { 1.0 } else { done as f64 / total as f64 };
                let _ = tx.send(Event::JobProgress {
                    step: Step::MovingAppFile,
                    value: MOVE_SHARE * share,
                    detail: String::new(),
                });
                !cancel.load(Ordering::SeqCst)
            };
            let result = match request.job {
                Job::LinuxUpdate { .. } => di::update(&env, &request.location, &mut progress),
                _ => di::add(&env, &request.location, &mut progress),
            };
            let end = match result {
                Ok(AddEnd::Done { .. }) => Ok(true),
                Ok(AddEnd::Canceled) => Ok(false),
                Err(failure) => Err(setup_error(&failure)),
            };
            let _ = tx.send(Event::JobEnded(end));
        });
    }

    fn measure_data(&mut self, _tx: EventTx) {}
    fn open_license(&mut self) {}
    fn open_log(&mut self, path: &Path) -> bool {
        !external_open_allowed() || std::process::Command::new("xdg-open").arg(path).spawn().is_ok()
    }
    fn launch_app(&mut self, _exe: &Path, _tx: EventTx) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> DesktopEnv {
        DesktopEnv {
            appimage: PathBuf::from("/home/paul/Downloads/SequenceStudio-0.2.0.AppImage"),
            appdir: PathBuf::from("/tmp/.mount_x"),
            data_home: PathBuf::from("/home/paul/.local/share"),
            home: PathBuf::from("/home/paul"),
            version: "0.2.0".into(),
        }
    }

    #[test]
    fn a_never_answered_appimage_asks_to_be_added_and_nothing_else_asks() {
        let m = first_run(&env(), &DesktopState::Offer, true);
        let Some(Machine { screen: InstallerScreen::Welcome { job, location, .. }, facts, .. }) = m else {
            panic!("no question")
        };
        assert_eq!(job, Job::LinuxAdd);
        assert_eq!(location, PathBuf::from("/home/paul/Applications"));
        assert_eq!(facts.appimage_dir, Some(PathBuf::from("/home/paul/Downloads")));
        for state in [DesktopState::Unavailable, DesktopState::Declined, DesktopState::Installed, DesktopState::Stale] {
            assert!(first_run(&env(), &state, true).is_none(), "{state:?}");
        }
    }

    #[test]
    fn headless_runs_never_ask() {
        assert!(first_run(&env(), &DesktopState::Offer, false).is_none());
    }

    #[test]
    fn a_failure_keeps_its_code_and_details() {
        let failure = SetupFailure {
            code: 302,
            step: "moving the AppImage".into(),
            path: Some(PathBuf::from("/x")),
            system: "os error 18".into(),
        };
        let error = setup_error(&failure);
        assert_eq!(error.code, ErrorCode::LinuxMoveFailed);
        assert_eq!(error.step, "moving the AppImage");
        assert_eq!(error.path, Some(PathBuf::from("/x")));
        let odd = SetupFailure { code: 7, step: "s".into(), path: None, system: "x".into() };
        assert_eq!(setup_error(&odd).code, ErrorCode::LinuxOther, "an unknown number is the catch-all");
    }

    #[test]
    fn a_folder_is_writable_when_a_parent_is() {
        let root = std::env::temp_dir().join(format!("sq-installer-linux-{}", std::process::id()));
        assert!(std::fs::create_dir_all(&root).is_ok());
        assert!(writable(&root.join("not/yet/there")));
        assert!(!writable(Path::new("/proc/definitely/not")));
        let _ = std::fs::remove_dir_all(root);
    }
}
