//! The Windows program: what the arguments and the registry decide, the services the window's effects use, and the
//! worker thread that runs the engine. Everything that touches Windows itself is in `sq-platform-win` and the engine's
//! `WindowsHost`; this file is glue.

use crate::app;
use crate::args::Args;
use crate::machine::{Event, Exit, Facts, InstallerScreen, JobRequest, LocationCheck, Machine, Measure};
use crate::session::{EventTx, Services, external_open_allowed};
use crate::view::{Chrome, ErrorContext};
use sq_core_time::{Timestamp, local_time::local_civil};
use sq_draw::GlyphAtlas;
use sq_setup_engine::plan::EXE_NAME;
use sq_setup_engine::{
    Host, Identity, Job, JobEnd, JobSpec, Log, Progress, SetupError, Step, Version, WindowsHost, check_location,
    default_location, describe_io, detect_installed, finish_uninstall_copy, log, measure_data, other_channel_installed,
    payload, quiet_location, run_job, uninstall_copy_name, update_kind,
};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

const APP_NAME: &str = "Sequence Studio";

/// The program's own version: the version the app has too (the packager's build version on a Nightly).
fn own_version() -> Version {
    crate::build_version()
}

fn env_dirs(host: &dyn Host) -> Vec<PathBuf> {
    let folders = host.folders();
    // The app's settings under %APPDATA% and its caches under %LOCALAPPDATA% (what `sq_os::Platform` resolves for it).
    vec![
        folders.app_data.join(APP_NAME),
        folders.local_app_data.join(APP_NAME),
        folders.local_app_data.join("SequenceStudio"),
    ]
}

fn stamp() -> String {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
    log::stamp(&local_civil(Timestamp::from_unix_seconds(now)))
}

/// The services of the Windows setup window.
struct WindowsServices {
    host: Arc<WindowsHost>,
    exe: PathBuf,
    version: Version,
    payload_bytes: u64,
}

impl Services for WindowsServices {
    fn choose_folder(&mut self, start: &Path) -> Option<PathBuf> {
        rfd::FileDialog::new().set_directory(start).set_title("Choose a folder").pick_folder()
    }

    fn check_location(&mut self, location: &Path) -> LocationCheck {
        check_location(&*self.host, location, self.payload_bytes).into()
    }

    fn start_job(&mut self, request: JobRequest, tx: EventTx, cancel: Arc<AtomicBool>) {
        let host = Arc::clone(&self.host);
        let spec = JobSpec {
            job: request.job,
            location: request.location,
            desktop_shortcut: request.desktop_shortcut,
            delete_data: request.delete_data,
            version: self.version.clone(),
            payload_exe: self.exe.clone(),
            data_dirs: env_dirs(&*host),
            identity: Identity::build(),
        };
        std::thread::spawn(move || {
            let mut log = Log::new(&host.folders().temp, &stamp());
            let _ = tx.send(Event::LogAt(log.path().to_path_buf()));
            let mut progress = Worker { tx: tx.clone(), cancel };
            let end = run_job(&spec, &*host, &mut progress, &mut log);
            let _ = tx.send(Event::JobEnded(end.map(|e| e == JobEnd::Done)));
        });
    }

    fn measure_data(&mut self, tx: EventTx) {
        let dirs = env_dirs(&*self.host);
        let shared = other_channel_installed(&*self.host, Identity::build()).is_some();
        std::thread::spawn(move || {
            // Nothing to offer for deletion while the other channel uses the folders.
            let measure =
                if shared { Measure::Empty } else { measure_data(&dirs).map_or(Measure::Empty, Measure::Bytes) };
            let _ = tx.send(Event::DataMeasured(measure));
        });
    }

    fn open_license(&mut self) {
        let Ok(Some(payload)) = payload::open(&self.exe) else { return };
        let Ok(text) = payload.read_file("LICENSE") else { return };
        let file = self.host.folders().temp.join("Sequence Studio License.txt");
        if std::fs::write(&file, text).is_ok() {
            self.open_file(&file);
        }
    }

    fn open_log(&mut self, path: &Path) -> bool {
        self.open_file(path)
    }

    fn launch_app(&mut self, exe: &Path, tx: EventTx) {
        let mut command = Command::new(exe);
        if let Some(dir) = exe.parent() {
            command.current_dir(dir);
        }
        let child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                let _ = tx.send(Event::AppNotStarted(describe_io(&error)));
                return;
            }
        };
        let pid = child.id();
        std::thread::spawn(move || {
            // The app's window exists, or the machine's own timeout closes the setup after ten seconds.
            for _ in 0..100 {
                if sq_platform_win::has_visible_window(pid) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            let _ = tx.send(Event::AppUp);
        });
    }
}

impl WindowsServices {
    /// Whether the system took the file (a test run never raises another program on the desktop, and counts as opened).
    fn open_file(&self, path: &Path) -> bool {
        !external_open_allowed() || sq_platform_win::open_with_default(path)
    }
}

/// The worker's side of the progress: events to the window, the cancel flag from it.
struct Worker {
    tx: EventTx,
    cancel: Arc<AtomicBool>,
}

impl Progress for Worker {
    fn update(&mut self, step: Step, fraction: f64, detail: &str) {
        let _ = self.tx.send(Event::JobProgress { step, value: fraction, detail: detail.to_string() });
    }

    fn canceled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }
}

/// No window: the job runs on this thread and the exit code is the error number.
struct Silent;

impl Progress for Silent {
    fn update(&mut self, _: Step, _: f64, _: &str) {}
    fn canceled(&self) -> bool {
        false
    }
}

fn quiet(spec: &JobSpec, host: &WindowsHost) -> ExitCode {
    quiet_result(spec, host).map_or_else(|code| code, |()| ExitCode::SUCCESS)
}

fn quiet_result(spec: &JobSpec, host: &WindowsHost) -> Result<(), ExitCode> {
    let mut log = Log::new(&host.folders().temp, &stamp());
    match run_job(spec, host, &mut Silent, &mut log) {
        Ok(_) => Ok(()),
        Err(e) => {
            sq_os::errln!("{e}");
            Err(ExitCode::from(u8::try_from(e.code.number() % 256).unwrap_or(1)))
        }
    }
}

/// The uninstaller starts a copy of itself from the temp folder (`--from <install folder>`): its own file can then be
/// deleted with the rest.
fn start_uninstall_copy(host: &WindowsHost, exe: &Path, args: &Args) -> Result<(), SetupError> {
    let copy = host.folders().temp.join(uninstall_copy_name(std::process::id()));
    payload::copy_stub(exe, &copy)?;
    let from = exe.parent().map(Path::to_path_buf).unwrap_or_default();
    let mut command = Command::new(&copy);
    command.arg("--uninstall").arg("--from").arg(from);
    for (on, flag) in [(args.quiet, "--quiet"), (args.delete_data, "--delete-data")] {
        if on {
            command.arg(flag);
        }
    }
    command.spawn().map(|_| ()).map_err(|e| SetupError::from_io(&Job::Uninstall, "starting the uninstaller", &copy, &e))
}

fn error_context() -> ErrorContext {
    let homes = ["USERPROFILE", "HOME"].iter().filter_map(|k| std::env::var(k).ok()).collect();
    ErrorContext { homes, token: "%USERPROFILE%".into() }
}

/// The whole Windows program.
pub fn run(args: &Args, atlas: GlyphAtlas) -> ExitCode {
    let host = Arc::new(WindowsHost);
    let Ok(exe) = std::env::current_exe() else {
        sq_os::errln!("sq-installer: the program's own path is unknown");
        return ExitCode::FAILURE;
    };
    let folders = host.folders();
    let version = own_version();
    let system_line = |v: &Version| format!("Sequence Studio Setup {v} (x64) on {}", host.windows_version());
    let identity = Identity::build();
    let installed = detect_installed(&*host, identity);
    let mut services =
        WindowsServices { host: Arc::clone(&host), exe: exe.clone(), version: version.clone(), payload_bytes: 0 };
    let machine = if args.uninstall {
        let Some(from) = args.from.clone() else {
            // The installed uninstaller: hand over to the copy in the temp folder.
            return match start_uninstall_copy(&host, &exe, args) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    sq_os::errln!("{e}");
                    ExitCode::FAILURE
                }
            };
        };
        let spec = JobSpec {
            job: Job::Uninstall,
            location: from.clone(),
            desktop_shortcut: false,
            delete_data: args.delete_data,
            version: version.clone(),
            payload_exe: exe.clone(),
            data_dirs: env_dirs(&*host),
            identity: Identity::build(),
        };
        if args.quiet {
            let code = quiet(&spec, &host);
            finish_uninstall_copy(&*host, &exe);
            return code;
        }
        let shared = other_channel_installed(&*host, identity);
        let facts = Facts {
            version: installed.as_ref().map_or_else(|| version.clone(), |i| i.version.clone()),
            app_exe_name: EXE_NAME,
            start_folder: folders.local_app_data.clone(),
            payload_bytes: 0,
            appimage_dir: None,
            home: None,
            system_line: system_line(&version),
            data_shared_with: shared,
        };
        Machine::new(
            InstallerScreen::UninstallConfirm {
                job: Job::Uninstall,
                location: from,
                delete_data: args.delete_data,
                // No "delete settings" choice while the other channel needs them.
                data_size: if shared.is_some() { Measure::Empty } else { Measure::Loading },
            },
            facts,
        )
    } else {
        let payload = match payload::open(&exe) {
            Ok(Some(p)) => p,
            Ok(None) => {
                sq_os::errln!("sq-installer: this program carries no payload; use `--pack` to make a setup program");
                return ExitCode::FAILURE;
            }
            Err(e) => {
                sq_os::errln!("{e}");
                return ExitCode::from(u8::try_from(e.code.number() % 256).unwrap_or(1));
            }
        };
        services.version = payload.version.clone();
        services.payload_bytes = payload.total_bytes();
        let facts = Facts {
            version: payload.version.clone(),
            app_exe_name: EXE_NAME,
            start_folder: folders.local_app_data.clone(),
            payload_bytes: payload.total_bytes(),
            appimage_dir: None,
            home: None,
            system_line: system_line(&payload.version),
            data_shared_with: None,
        };
        let (job, location) = match &installed {
            Some(i) => (Job::Update { from: i.version.clone() }, i.location.clone()),
            None => (
                Job::Install,
                args.dir.as_deref().map_or_else(|| default_location(&folders.local_app_data), quiet_location),
            ),
        };
        if args.quiet {
            if let Some(pid) = args.wait_pid {
                let exe = location.join(EXE_NAME);
                let gone = crate::wait::wait_until_gone(
                    pid,
                    || host.running_instances(&exe),
                    crate::wait::TRIES,
                    || std::thread::sleep(crate::wait::POLL),
                );
                if !gone {
                    sq_os::errln!("sq-installer: the app did not end in time");
                    return ExitCode::FAILURE;
                }
            }
            let spec = JobSpec {
                job,
                location,
                desktop_shortcut: args.desktop,
                delete_data: false,
                version: payload.version.clone(),
                payload_exe: exe.clone(),
                data_dirs: env_dirs(&*host),
                identity: Identity::build(),
            };
            if let Err(code) = quiet_result(&spec, &host) {
                return code;
            }
            if args.cleanup {
                // The updater's downloaded copy: the file is locked while this program runs, so it goes once it has ended.
                let _ = host.delete_after_exit(&exe);
            }
            if args.launch {
                let app = spec.location.join(EXE_NAME);
                if let Err(error) = Command::new(&app).current_dir(&spec.location).spawn() {
                    sq_os::errln!("sq-installer: the app could not start: {}", describe_io(&error));
                    return ExitCode::FAILURE;
                }
            }
            return ExitCode::SUCCESS;
        }
        match &installed {
            Some(i) => {
                let running = !host.running_instances(&i.location.join(EXE_NAME)).is_empty();
                let screen = InstallerScreen::Update {
                    job,
                    installed: i.version.clone(),
                    location: i.location.clone(),
                    app_running: running,
                    kind: update_kind(&payload.version, &i.version),
                };
                Machine::new(screen, facts)
            }
            None => {
                let check = check_location(&*host, &location, payload.total_bytes()).into();
                Machine::new(Machine::welcome(Job::Install, location, check), facts)
            }
        }
    };
    let chrome = Chrome::OwnClose;
    let result = app::run("Sequence Studio Setup", chrome, error_context(), atlas, machine, Box::new(services));
    if args.uninstall {
        finish_uninstall_copy(&*host, &exe);
    }
    match result {
        Ok(Exit::Closed | Exit::Declined | Exit::Added) => ExitCode::SUCCESS,
        Err(why) => {
            sq_os::errln!("sq-installer: {why}");
            ExitCode::FAILURE
        }
    }
}
