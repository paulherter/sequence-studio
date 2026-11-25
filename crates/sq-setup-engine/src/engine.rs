//! Runs a Windows setup job (spec section 10): verify, copy beside the target, swap, shortcuts and registry from the plan,
//! finish; or the uninstall. A failure after a partial step rolls back what the job did. Linux jobs are not run here.
//!
//! Called from a worker thread: the UI polls [`Progress`] values and answers `canceled()`.

use crate::error::{ErrorCode, SetupError, describe_io};
use crate::host::Host;
use crate::identity::Identity;
use crate::job::{Job, Step};
use crate::log::Log;
use crate::payload::{self, UnpackEnd};
use crate::plan::{self, Action, EXE_NAME, Options, PlanEnv};
use crate::version::Version;
use crate::{SpaceFacts, format_size};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// What to run.
#[derive(Clone, Debug)]
pub struct JobSpec {
    pub job: Job,
    /// The install folder (where the app is or goes).
    pub location: PathBuf,
    pub desktop_shortcut: bool,
    /// Uninstall: also remove `data_dirs`.
    pub delete_data: bool,
    /// The version being installed (unused by an uninstall).
    pub version: Version,
    /// The exe that carries the payload; for an uninstall the stub (the copy of the uninstaller itself).
    pub payload_exe: PathBuf,
    /// The app's folders under the data and cache directories, given by the caller (`sq_os::Platform`).
    pub data_dirs: Vec<PathBuf>,
    /// The channel the job installs or removes.
    pub identity: Identity,
}

/// How a job ended without an error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobEnd {
    Done,
    /// Canceled before the point of no return; everything is back as it was.
    Canceled,
}

/// The UI's side: gets the progress, tells about a cancel request.
pub trait Progress {
    /// `fraction` is the overall bar 0..1 and never falls.
    fn update(&mut self, step: Step, fraction: f64, detail: &str);
    fn canceled(&self) -> bool;
}

struct Run<'a> {
    spec: &'a JobSpec,
    host: &'a dyn Host,
    progress: &'a mut dyn Progress,
    log: &'a mut Log,
    last: f64,
}

/// Runs `spec.job`. On `Err` the job has rolled back (an uninstall has nothing to roll back) and the error is in the log.
pub fn run_job(
    spec: &JobSpec,
    host: &dyn Host,
    progress: &mut dyn Progress,
    log: &mut Log,
) -> Result<JobEnd, SetupError> {
    let mut run = Run { spec, host, progress, log, last: 0.0 };
    run.log.line(&format!("Sequence Studio setup {} {:?} -> {}", spec.version, spec.job, spec.location.display()));
    run.log.line(&host.windows_version());
    let result = match spec.job {
        Job::Install | Job::Update { .. } => run.install(),
        Job::Uninstall => run.uninstall(),
        Job::LinuxAdd | Job::LinuxUpdate { .. } | Job::LinuxRemove => Err(SetupError::new(
            ErrorCode::Other,
            "starting the job",
            "this is a Linux job; the Windows engine does not run it",
        )),
    };
    match &result {
        Ok(end) => run.log.line(&format!("Ended: {end:?}")),
        Err(e) => run.log.line(&format!("FAILED {e}")),
    }
    result
}

fn sibling(location: &Path, suffix: &str) -> PathBuf {
    let name = location.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    location.with_file_name(format!("{name}{suffix}"))
}

/// How often a folder that survives a removal is removed again, and the pause between the tries.
const REMOVE_TRIES: u32 = 4;
const REMOVE_PAUSE: Duration = Duration::from_millis(150);

/// How often the swap of the old folder is tried again, and the pause between the tries (about 10 s in all).
const SWAP_TRIES: u32 = 50;
const SWAP_PAUSE: Duration = Duration::from_millis(200);

/// Renames `from` to `to`. Windows refuses a folder rename with os error 32/5 while a process that has just ended still
/// holds a file inside, or a scanner reads one of the new files; both pass within moments, so the rename is tried again.
/// `pause` sleeps between the tries.
pub(crate) fn rename_with_retry(
    mut rename: impl FnMut() -> io::Result<()>,
    tries: u32,
    mut pause: impl FnMut(),
) -> io::Result<()> {
    let mut attempt = 1;
    loop {
        match rename() {
            Ok(()) => return Ok(()),
            Err(e) if attempt >= tries || e.kind() == io::ErrorKind::NotFound => return Err(e),
            Err(_) => {
                attempt += 1;
                pause();
            }
        }
    }
}

/// Removes a folder; files that stay (locked) are scheduled for the next restart. Returns what could not even be
/// scheduled. A program that is still shutting down can write into the folder while it goes (and Windows keeps a folder
/// with an open handle as "delete pending"), so a folder that is still there after a removal is removed again.
fn remove_tree(host: &dyn Host, log: &mut Log, path: &Path) -> Vec<PathBuf> {
    if !path.exists() {
        return Vec::new();
    }
    for attempt in 1..=REMOVE_TRIES {
        match std::fs::remove_dir_all(path) {
            Ok(()) if !path.exists() => return Vec::new(),
            Ok(()) => log.line(&format!("remove {}: it is still there (try {attempt})", path.display())),
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Vec::new(),
            Err(e) => log.line(&format!("remove {}: {} (try {attempt})", path.display(), describe_io(&e))),
        }
        if attempt < REMOVE_TRIES {
            std::thread::sleep(REMOVE_PAUSE);
        }
    }
    log.line(&format!("going file by file in {}", path.display()));
    let mut left = Vec::new();
    remove_walk(host, log, path, &mut left);
    left
}

fn remove_walk(host: &dyn Host, log: &mut Log, dir: &Path, left: &mut Vec<PathBuf>) {
    let entries: Vec<_> = std::fs::read_dir(dir).map(|r| r.flatten().collect()).unwrap_or_default();
    for entry in entries {
        let path = entry.path();
        if entry.file_type().is_ok_and(|t| t.is_dir()) {
            remove_walk(host, log, &path, left);
        } else if let Err(e) = std::fs::remove_file(&path) {
            schedule(host, log, &path, &e, left);
        }
    }
    if let Err(e) = std::fs::remove_dir(dir) {
        schedule(host, log, dir, &e, left);
    }
}

fn schedule(host: &dyn Host, log: &mut Log, path: &Path, why: &io::Error, left: &mut Vec<PathBuf>) {
    log.line(&format!("cannot remove {}: {}", path.display(), describe_io(why)));
    match host.delete_at_reboot(path) {
        Ok(()) => log.line("  scheduled for the next restart"),
        Err(e) => {
            log.line(&format!("  not even schedulable: {}", describe_io(&e)));
            left.push(path.to_path_buf());
        }
    }
}

/// The uninstaller runs from a copy of itself in the temp folder, named `Sequence Studio Uninstall <pid>.exe`.
pub fn uninstall_copy_name(pid: u32) -> String {
    format!("{UNINSTALL_COPY_PREFIX}{pid}.exe")
}

const UNINSTALL_COPY_PREFIX: &str = "Sequence Studio Uninstall ";

fn is_uninstall_copy(name: &std::ffi::OsStr) -> bool {
    let name = name.to_string_lossy();
    name.starts_with(UNINSTALL_COPY_PREFIX) && name.ends_with(".exe")
}

/// The end of an uninstaller copy `own`: copies of earlier runs that were killed before they could clean up go now (a
/// copy that still runs cannot be deleted, so it stays), and this one is deleted once its process has ended. A file that
/// is not a copy in the temp folder is never touched.
pub fn finish_uninstall_copy(host: &dyn Host, own: &Path) {
    let temp = host.folders().temp;
    if let Ok(entries) = std::fs::read_dir(&temp) {
        for entry in entries.flatten() {
            if is_uninstall_copy(&entry.file_name()) && entry.path() != own {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    if own.parent() == Some(temp.as_path()) && own.file_name().is_some_and(is_uninstall_copy) {
        let _ = host.delete_after_exit(own);
    }
}

impl Run<'_> {
    fn report(&mut self, step: Step, fraction: f64, detail: &str) {
        self.last = self.last.max(fraction.clamp(0.0, 1.0));
        self.progress.update(step, self.last, detail);
    }

    /// A cancel counts only before the point where the UI disables the button.
    fn cancel_requested(&self) -> bool {
        self.last < self.spec.job.cancel_until() && self.progress.canceled()
    }

    fn io(&mut self, step: &str, path: &Path, e: &io::Error) -> SetupError {
        let err = SetupError::from_io(&self.spec.job, step, path, e);
        self.log.line(&format!("{err}"));
        err
    }

    /// Asks a running app to close and waits; `Ok(false)` = the user canceled while waiting.
    fn close_running(&mut self, exe: &Path) -> Result<bool, SetupError> {
        if self.host.running_instances(exe).is_empty() {
            return Ok(true);
        }
        self.log.line(&format!("{} is running; asking it to close", exe.display()));
        self.host.request_close(exe);
        let deadline = Instant::now() + self.host.close_timeout();
        while !self.host.running_instances(exe).is_empty() {
            if self.cancel_requested() {
                return Ok(false);
            }
            if Instant::now() >= deadline {
                let code = if self.spec.job.removes() { ErrorCode::UninstallInUse } else { ErrorCode::AppStillOpen };
                return Err(
                    SetupError::new(code, "closing Sequence Studio", "the app did not close in time").with_path(exe)
                );
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        Ok(true)
    }

    fn apply(&mut self, action: &Action) -> Result<(), SetupError> {
        let host = self.host;
        let fail = |code, step: &str, path: Option<&Path>, e: &io::Error| {
            let err = SetupError::new(code, step, describe_io(e));
            match path {
                Some(p) => err.with_path(p),
                None => err,
            }
        };
        let result = match action {
            Action::Shortcut(s) => {
                self.log.line(&format!("shortcut {}", s.link.display()));
                host.create_shortcut(s).map_err(|e| fail(ErrorCode::Shortcut, "creating a shortcut", Some(&s.link), &e))
            }
            Action::RegSetString { key, name, value } => {
                self.log.line(&format!("set HKCU\\{key} {} = {value}", name.as_deref().unwrap_or("(default)")));
                host.reg_set_string(key, name.as_deref(), value)
                    .map_err(|e| fail(ErrorCode::Registry, "writing the registry", None, &e))
            }
            Action::RegSetStringIfUnset { key, name, value } => {
                let current = host.reg_get_string(key, name.as_deref());
                if current.as_deref().is_none_or(|c| c.is_empty() || c == value) {
                    self.log.line(&format!("set HKCU\\{key} {} = {value}", name.as_deref().unwrap_or("(default)")));
                    host.reg_set_string(key, name.as_deref(), value)
                        .map_err(|e| fail(ErrorCode::Registry, "writing the registry", None, &e))
                } else {
                    self.log.line(&format!("keep HKCU\\{key}: another program owns it"));
                    Ok(())
                }
            }
            Action::RegDeleteValue { key, name } => {
                self.log.line(&format!("delete value HKCU\\{key} {}", name.as_deref().unwrap_or("(default)")));
                host.reg_delete_value(key, name.as_deref())
                    .map_err(|e| fail(ErrorCode::Registry, "cleaning the registry", None, &e))
            }
            Action::RegSetDword { key, name, value } => {
                self.log.line(&format!("set HKCU\\{key} {name} = {value}"));
                host.reg_set_dword(key, name, *value)
                    .map_err(|e| fail(ErrorCode::Registry, "writing the registry", None, &e))
            }
            Action::RegDeleteKey(key) => {
                self.log.line(&format!("delete HKCU\\{key}"));
                host.reg_delete_key(key).map_err(|e| fail(ErrorCode::Registry, "cleaning the registry", None, &e))
            }
            Action::RegDeleteKeyIfEmpty(key) => {
                self.log.line(&format!("delete HKCU\\{key} if it is empty"));
                host.reg_delete_key_if_empty(key)
                    .map_err(|e| fail(ErrorCode::Registry, "cleaning the registry", None, &e))
            }
            Action::RegDeleteValueIfEquals { key, name, equals } => {
                if host.reg_get_string(key, name.as_deref()).as_deref() == Some(equals.as_str()) {
                    self.log.line(&format!("delete value HKCU\\{key} {}", name.as_deref().unwrap_or("(default)")));
                    host.reg_delete_value(key, name.as_deref())
                        .map_err(|e| fail(ErrorCode::Registry, "cleaning the registry", None, &e))
                } else {
                    self.log.line(&format!("keep HKCU\\{key}: it points elsewhere"));
                    Ok(())
                }
            }
            Action::RemoveFile(path) => match std::fs::remove_file(path) {
                Ok(()) => {
                    self.log.line(&format!("removed {}", path.display()));
                    Ok(())
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(SetupError::from_io(&self.spec.job, "removing a file", path, &e)),
            },
            Action::RemoveDirAll(path) => {
                self.log.line(&format!("remove folder {}", path.display()));
                let left = remove_tree(host, self.log, path);
                match left.first() {
                    None => Ok(()),
                    Some(first) => Err(SetupError::new(
                        ErrorCode::UninstallLeftovers,
                        "removing files",
                        format!("{} files stay", left.len()),
                    )
                    .with_path(first)),
                }
            }
            Action::AssocChanged => {
                host.notify_assoc_changed();
                Ok(())
            }
        };
        if let Err(e) = &result {
            self.log.line(&format!("{e}"));
        }
        result
    }

    fn install(&mut self) -> Result<JobEnd, SetupError> {
        let spec = self.spec;
        let location = spec.location.as_path();
        let exe = location.join(EXE_NAME);

        // 1. Preparing
        self.report(Step::Preparing, 0.0, Step::Preparing.detail());
        let payload = payload::open(&spec.payload_exe)?.ok_or_else(|| {
            SetupError::new(
                ErrorCode::PayloadDamaged,
                "opening the package",
                "this program carries no files to install",
            )
        })?;
        let (progress, mut last) = (&mut *self.progress, self.last);
        payload.verify(&mut |f| {
            last = last.max(0.03 * f);
            progress.update(Step::Preparing, last, "Checking the package");
        })?;
        self.last = last;
        self.log.line(&format!(
            "package {} verified, {} files, {} bytes",
            payload.version,
            payload.files.len(),
            payload.total_bytes()
        ));
        let need = payload.total_bytes();
        if let Some(free) = self.host.free_bytes(location)
            && free < need
        {
            let facts = SpaceFacts { drive: self.host.drive_label(location), free, need };
            let err =
                SetupError::new(ErrorCode::NoSpace, "checking the space", format!("{free} bytes free, {need} needed"))
                    .with_path(location)
                    .with_space(facts);
            self.log.line(&format!("{err}"));
            return Err(err);
        }
        self.report(Step::Preparing, 0.035, Step::Preparing.detail());
        if self.cancel_requested() || !self.close_running(&exe)? {
            return Ok(JobEnd::Canceled);
        }
        let (new, old) = (sibling(location, ".new"), sibling(location, ".old"));
        if let Some(parent) = location.parent() {
            std::fs::create_dir_all(parent).map_err(|e| self.io("creating the folder", parent, &e))?;
        }
        for stale in [&new, &old] {
            let _ = std::fs::remove_dir_all(stale);
        }
        self.report(Step::Preparing, 0.04, Step::Preparing.detail());

        // 2. Copying into `<location>.new`, then the swap.
        let total = need.max(1);
        let ended = {
            let (progress, mut last, until) = (&mut *self.progress, self.last, spec.job.cancel_until());
            payload.unpack_to(&new, &mut |bytes| {
                last = last.max(0.04 + 0.86 * (bytes as f64 / total as f64));
                progress.update(Step::Copying, last, &format!("{} of {}", format_size(bytes), format_size(need)));
                !(last < until && progress.canceled())
            })
        };
        match ended {
            Ok(UnpackEnd::Done) => {}
            Ok(UnpackEnd::Canceled) => {
                self.log.line("canceled while copying; the new folder is removed");
                let _ = std::fs::remove_dir_all(&new);
                return Ok(JobEnd::Canceled);
            }
            Err(e) => {
                self.log.line(&format!("{e}"));
                let _ = std::fs::remove_dir_all(&new);
                return Err(e);
            }
        }
        // The uninstaller copy goes in before the swap, so a failure here still only deletes `.new`.
        if let Err(e) = payload::copy_stub(&spec.payload_exe, &new.join(spec.identity.uninstaller_name())) {
            self.log.line(&format!("{e}"));
            let _ = std::fs::remove_dir_all(&new);
            return Err(e);
        }
        self.report(Step::Copying, 0.90, "");
        let had_old = location.exists();
        if had_old
            && let Err(e) =
                rename_with_retry(|| std::fs::rename(location, &old), SWAP_TRIES, || std::thread::sleep(SWAP_PAUSE))
        {
            let _ = std::fs::remove_dir_all(&new);
            return Err(self.io("replacing the old version", location, &e));
        }
        if let Err(e) = std::fs::rename(&new, location) {
            if had_old {
                let _ = std::fs::rename(&old, location);
            }
            let _ = std::fs::remove_dir_all(&new);
            return Err(self.io("moving the new version into place", location, &e));
        }
        self.log.line("swapped the new folder into place");

        // 3. Start menu and registry.
        self.report(Step::StartMenu, 0.90, Step::StartMenu.detail());
        let folders = self.host.folders();
        let env = PlanEnv {
            start_menu_programs: folders.start_menu_programs,
            desktop: folders.desktop,
            temp: folders.temp,
            data_dirs: spec.data_dirs.clone(),
            identity: spec.identity,
        };
        let opts = Options { desktop_shortcut: spec.desktop_shortcut, delete_data: false };
        let size_kb = u32::try_from(need / 1024).unwrap_or(u32::MAX);
        let actions = plan::plan(&spec.job, location, &opts, &env, &spec.version, size_kb);
        for (i, action) in actions.iter().enumerate() {
            self.report(Step::StartMenu, 0.90 + 0.07 * (i as f64 / actions.len() as f64), Step::StartMenu.detail());
            if let Err(e) = self.apply(action) {
                self.roll_back(&actions[..=i], location, &old, had_old);
                return Err(e);
            }
        }
        self.report(Step::StartMenu, 0.97, "");

        // 4. Finishing.
        self.report(Step::Finishing, 0.97, Step::Finishing.detail());
        let _ = self.host.reg_delete_key(spec.identity.inno_uninstall_key());
        for leftover in ["unins000.exe", "unins000.dat"] {
            let _ = std::fs::remove_file(location.join(leftover));
        }
        let left = remove_tree(self.host, self.log, &old);
        if !left.is_empty() {
            self.log.line(&format!("{} files of the old version stay and are not schedulable", left.len()));
        }
        self.report(Step::Finishing, 1.0, "");
        Ok(JobEnd::Done)
    }

    /// Undoes a failure after the swap: a first install removes what the plan added; an update keeps its shortcuts and
    /// registry (same paths as before). Either way the old folder comes back.
    fn roll_back(&mut self, done: &[Action], location: &Path, old: &Path, had_old: bool) {
        self.log.line("rolling back");
        if matches!(self.spec.job, Job::Install) {
            for undo in plan::inverse(done, self.spec.identity) {
                let _ = self.apply(&undo);
            }
        }
        let _ = std::fs::remove_dir_all(location);
        if had_old && let Err(e) = std::fs::rename(old, location) {
            self.log.line(&format!("could not restore the old folder: {}", describe_io(&e)));
        }
    }

    fn uninstall(&mut self) -> Result<JobEnd, SetupError> {
        let spec = self.spec;
        let exe = spec.location.join(EXE_NAME);
        self.report(Step::RemovingFiles, 0.0, "");
        // An uninstall is never canceled (`cancel_until` is 0), so the wait cannot end early.
        self.close_running(&exe)?;
        let folders = self.host.folders();
        let env = PlanEnv {
            start_menu_programs: folders.start_menu_programs,
            desktop: folders.desktop,
            temp: folders.temp,
            data_dirs: spec.data_dirs.clone(),
            identity: spec.identity,
        };
        // The data folders are shared by both channels: while the other one is installed they stay.
        let shared_with = crate::detect::other_channel_installed(self.host, spec.identity);
        if let (true, Some(name)) = (spec.delete_data, shared_with) {
            self.log.line(&format!("settings and caches stay: {name} is installed and uses them"));
        }
        let opts = Options { desktop_shortcut: false, delete_data: spec.delete_data && shared_with.is_none() };
        let actions = plan::plan(&Job::Uninstall, &spec.location, &opts, &env, &spec.version, 0);
        let files = actions.iter().take_while(|a| matches!(a, Action::RemoveDirAll(_))).count();
        for (i, action) in actions.iter().enumerate() {
            let (step, fraction) = if i < files {
                (Step::RemovingFiles, 0.92 * i as f64 / files as f64)
            } else {
                (Step::RemovingStartMenu, 0.92 + 0.08 * (i - files) as f64 / (actions.len() - files).max(1) as f64)
            };
            self.report(step, fraction, "");
            self.apply(action)?;
        }
        self.report(Step::RemovingStartMenu, 1.0, "");
        Ok(JobEnd::Done)
    }
}
