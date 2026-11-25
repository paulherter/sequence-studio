//! The setup's one state machine: one enum for the screen, one function for every transition (`Machine::handle`), no
//! drawing and no I/O. The window host feeds it events (button presses, key presses, the worker's progress) and does the
//! effects it returns (open the folder chooser, start the job, close the window). Spec: `design/installer/spec.md` §7.

use sq_setup_engine::{ErrorCode, Job, SetupError, Step, Version};
pub use sq_setup_engine::{UpdateKind, resolve_location};
use std::path::{Path, PathBuf};

/// The bar stays full this long before the Done screen (spec §6.2).
pub const DONE_HOLD: f64 = 0.25;
/// Linux shows the progress screen only when the work takes longer than this (spec §6.2).
pub const PROGRESS_DELAY: f64 = 0.4;
/// `Checking free space…` shows only when the check takes longer than this (spec §6.1).
pub const CHECK_DELAY: f64 = 0.15;
/// `Open Sequence Studio` waits this long for the app's window before the setup closes anyway (spec §6.3).
pub const OPEN_TIMEOUT: f64 = 10.0;
/// The folder every Windows install ends in.
pub const APP_FOLDER: &str = "Sequence Studio";

/// What the Location row's check found (spec §6.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocationCheck {
    /// Running longer than [`CHECK_DELAY`]: the note says `Checking free space…`; Install stays enabled.
    Checking,
    Ok {
        free: u64,
    },
    NoSpace {
        need: u64,
        free: u64,
    },
    NotWritable,
}

impl From<sq_setup_engine::LocationCheck> for LocationCheck {
    fn from(check: sq_setup_engine::LocationCheck) -> LocationCheck {
        match check {
            sq_setup_engine::LocationCheck::Ok { free } => LocationCheck::Ok { free },
            sq_setup_engine::LocationCheck::NoSpace { need, free } => LocationCheck::NoSpace { need, free },
            sq_setup_engine::LocationCheck::NotWritable => LocationCheck::NotWritable,
        }
    }
}

impl LocationCheck {
    /// Install is disabled for a folder that cannot take the app.
    pub fn allows_install(self) -> bool {
        matches!(self, LocationCheck::Checking | LocationCheck::Ok { .. })
    }
}

/// The size of the settings and caches the uninstaller may delete.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Measure {
    Loading,
    /// Nothing there: the row is hidden.
    Empty,
    Bytes(u64),
    /// The measuring failed: the checkbox shows without a size.
    Failed,
}

/// Every screen of the setup.
#[derive(Clone, Debug, PartialEq)]
pub enum InstallerScreen {
    /// Windows install, Linux add (`job` says which).
    Welcome {
        job: Job,
        /// The folder the app ends up in (Windows: with `Sequence Studio` appended when the picked one is not called so).
        location: PathBuf,
        /// The picked folder was not called `Sequence Studio`: the app goes into a new folder inside it.
        nested: bool,
        check: LocationCheck,
        /// When a slow check started.
        checking_since: Option<f64>,
        desktop_shortcut: bool,
    },
    /// Already installed (`job` is `Update`/`LinuxUpdate`).
    Update {
        job: Job,
        installed: Version,
        location: PathBuf,
        app_running: bool,
        kind: UpdateKind,
    },
    UninstallConfirm {
        job: Job,
        location: PathBuf,
        delete_data: bool,
        data_size: Measure,
    },
    Progress {
        job: Job,
        step: Step,
        /// The real overall value 0..=1; it only rises.
        value: f64,
        detail: String,
        canceling: bool,
        /// The job reported success at this time; the bar holds, then Done.
        finished_at: Option<f64>,
    },
    Done {
        job: Job,
        opening: bool,
    },
    Uninstalled {
        job: Job,
        deleted_data: bool,
    },
    Error {
        job: Job,
        error: SetupError,
        log: Option<PathBuf>,
    },
}

/// A button of any screen. The label comes from the screen's content, not from here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Cancel,
    NotNow,
    Close,
    Install,
    AddToMenu,
    /// `Update to x`, `Reinstall` or `Replace with x`.
    Update,
    Uninstall,
    Open,
    Continue,
    License,
    Change,
}

/// A checkbox of the Welcome and Uninstall cards.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Check {
    DesktopShortcut,
    DeleteData,
}

/// What the work needs to start.
#[derive(Clone, Debug, PartialEq)]
pub struct JobRequest {
    pub job: Job,
    pub location: PathBuf,
    pub desktop_shortcut: bool,
    pub delete_data: bool,
}

/// How the setup ends. The Linux first run turns it into what happens next (`Declined` is remembered).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exit {
    /// Closed, nothing asked or already done.
    Closed,
    /// Linux: `Not Now`, Esc or the window's close button on the question: remembered, never asked again.
    Declined,
    /// Linux: the app menu entry exists now; go on to the Start window.
    Added,
}

/// Taskbar progress (Windows).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Taskbar {
    Off,
    Value(f64),
    Error,
}

/// What the host does next.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// The system's folder chooser, starting at this folder; the answer is `Event::LocationPicked`.
    ChooseFolder(PathBuf),
    /// Check the folder for space and rights; the answer is `Event::LocationChecked`.
    CheckLocation(PathBuf),
    StartJob(JobRequest),
    CancelJob,
    MeasureData,
    OpenLicense,
    /// Start the installed app, not elevated; the host sends `Event::AppUp` when its window exists.
    LaunchApp(PathBuf),
    Exit(Exit),
    Taskbar(Taskbar),
}

/// An input to the machine.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Press(Button),
    Toggle(Check),
    /// The screen's default key.
    Enter,
    /// Esc or the window's close button: the safe way out of every screen.
    Escape,
    LocationPicked(PathBuf),
    /// The answer to `CheckLocation(location)`; an answer for a folder that is no longer shown is dropped.
    LocationChecked {
        location: PathBuf,
        check: LocationCheck,
    },
    DataMeasured(Measure),
    AppRunning(bool),
    JobProgress {
        step: Step,
        value: f64,
        detail: String,
    },
    /// The worker is done: `Ok(true)` finished, `Ok(false)` canceled (and rolled back), `Err` failed (and rolled back).
    JobEnded(Result<bool, SetupError>),
    /// The installed app's window exists.
    AppUp,
    /// `Open` could not start the installed app; the text is the system's own words.
    AppNotStarted(String),
    /// `Try Again` on the error screen (the error view owns its other buttons).
    TryAgain,
    /// The job's log file exists.
    LogAt(PathBuf),
    /// Time passes (the host sends it while a frame is requested).
    Tick,
}

/// What stays the same during a run.
#[derive(Clone, Debug, PartialEq)]
pub struct Facts {
    /// The version this setup carries.
    pub version: Version,
    /// The installed app's file name inside the install folder, for the Open button.
    pub app_exe_name: &'static str,
    /// The folder the folder chooser starts at.
    pub start_folder: PathBuf,
    /// What the payload needs on disk once unpacked (the size in the sub line).
    pub payload_bytes: u64,
    /// Linux: the folder the running AppImage sits in now (named in the note; `None` when unknown).
    pub appimage_dir: Option<PathBuf>,
    /// The user's home folder, shown as `~` on Linux paths.
    pub home: Option<PathBuf>,
    /// The first line of `Copy details`: `Sequence Studio Setup 0.2.0 (x64) on Windows 11 26100`.
    pub system_line: String,
    /// Windows: the other channel's app name when it is installed too and so keeps the shared settings and caches.
    pub data_shared_with: Option<&'static str>,
}

/// The screen and everything the transitions need.
#[derive(Clone, Debug, PartialEq)]
pub struct Machine {
    pub screen: InstallerScreen,
    pub facts: Facts,
    /// The last time the host told us.
    pub now: f64,
    /// What the running or last job was asked to do.
    pub request: Option<JobRequest>,
    /// The log the running job writes; `Open log` on the error screen shows it.
    pub log: Option<PathBuf>,
    /// The Update screen to come back to when an update is canceled.
    return_to: Option<Box<InstallerScreen>>,
    /// Linux: the job started at this time and the progress screen is not shown yet.
    quiet_since: Option<f64>,
    /// `Open` was pressed at this time.
    opening_since: Option<f64>,
    /// What `Try Again` runs again: the last job, from the start.
    retry: Option<JobRequest>,
    /// Counts the changes of the screen, see [`Machine::revision`].
    revision: u64,
}

impl Machine {
    pub fn new(screen: InstallerScreen, facts: Facts) -> Machine {
        Machine {
            screen,
            facts,
            now: 0.0,
            request: None,
            log: None,
            return_to: None,
            quiet_since: None,
            opening_since: None,
            retry: None,
            revision: 0,
        }
    }

    /// How often the screen has changed. A tick can change it (the hold after a finished job ends) without any input, so a
    /// window that last drew an older number must draw again even when nothing else asks for a frame.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The Welcome screen of `job` at `location` (already resolved) with its check.
    pub fn welcome(job: Job, location: PathBuf, check: LocationCheck) -> InstallerScreen {
        InstallerScreen::Welcome { job, location, nested: false, check, checking_since: None, desktop_shortcut: false }
    }

    fn job(&self) -> Option<&Job> {
        match &self.screen {
            InstallerScreen::Welcome { job, .. }
            | InstallerScreen::Update { job, .. }
            | InstallerScreen::UninstallConfirm { job, .. }
            | InstallerScreen::Progress { job, .. }
            | InstallerScreen::Done { job, .. }
            | InstallerScreen::Uninstalled { job, .. }
            | InstallerScreen::Error { job, .. } => Some(job),
        }
    }

    fn linux(&self) -> bool {
        self.job().is_some_and(Job::is_linux)
    }

    /// What leaving the question without an answer means: Linux remembers `Not Now`.
    fn leave_question(&self) -> Exit {
        if self.linux() { Exit::Declined } else { Exit::Closed }
    }

    /// Whether Cancel is open: before the point of no return and not already canceling.
    pub fn can_cancel(&self) -> bool {
        match &self.screen {
            InstallerScreen::Progress { job, value, canceling, finished_at, .. } => {
                !canceling && finished_at.is_none() && *value < job.cancel_until()
            }
            _ => false,
        }
    }

    /// Whether `Install`/`Update` can be pressed now.
    pub fn can_install(&self) -> bool {
        match &self.screen {
            InstallerScreen::Welcome { check, .. } => check.allows_install(),
            _ => true,
        }
    }

    /// The one transition function. A call that changes the screen raises [`Machine::revision`].
    pub fn handle(&mut self, event: Event, now: f64) -> Vec<Effect> {
        let before = self.screen.clone();
        let effects = self.transition(event, now);
        if self.screen != before {
            self.revision += 1;
        }
        effects
    }

    fn transition(&mut self, event: Event, now: f64) -> Vec<Effect> {
        self.now = now;
        let busy = self.quiet_since.is_some();
        match event {
            Event::Tick => self.tick(),
            Event::AppRunning(running) => {
                if let InstallerScreen::Update { app_running, .. } = &mut self.screen {
                    *app_running = running;
                }
                Vec::new()
            }
            Event::DataMeasured(measure) => {
                if let InstallerScreen::UninstallConfirm { data_size, .. } = &mut self.screen {
                    *data_size = measure;
                }
                Vec::new()
            }
            Event::LocationPicked(picked) => self.location_picked(picked),
            Event::LocationChecked { location, check } => {
                if let InstallerScreen::Welcome { location: shown, check: c, checking_since, .. } = &mut self.screen
                    && *shown == location
                {
                    *c = check;
                    *checking_since = None;
                }
                Vec::new()
            }
            Event::JobProgress { step, value, detail } => self.progress(step, value, detail),
            Event::JobEnded(result) => self.job_ended(result),
            Event::TryAgain => self.try_again(),
            Event::LogAt(path) => {
                self.log = Some(path);
                Vec::new()
            }
            Event::AppUp => {
                if self.opening_since.take().is_some() {
                    vec![Effect::Exit(Exit::Closed)]
                } else {
                    Vec::new()
                }
            }
            Event::AppNotStarted(system) => self.app_not_started(system),
            _ if busy => Vec::new(),
            Event::Toggle(check) => {
                match (&mut self.screen, check) {
                    (InstallerScreen::Welcome { desktop_shortcut, .. }, Check::DesktopShortcut) => {
                        *desktop_shortcut = !*desktop_shortcut;
                    }
                    (InstallerScreen::UninstallConfirm { delete_data, .. }, Check::DeleteData) => {
                        *delete_data = !*delete_data;
                    }
                    _ => {}
                }
                Vec::new()
            }
            Event::Enter => match self.default_button() {
                Some(button) => self.press(button),
                None => Vec::new(),
            },
            Event::Escape => match self.escape_button() {
                Some(button) => self.press(button),
                None => Vec::new(),
            },
            Event::Press(button) => self.press(button),
        }
    }

    /// The button Enter presses (spec §6, per screen).
    pub fn default_button(&self) -> Option<Button> {
        match &self.screen {
            InstallerScreen::Welcome { job, .. } => {
                if !self.can_install() {
                    None
                } else if job.is_linux() {
                    Some(Button::AddToMenu)
                } else {
                    Some(Button::Install)
                }
            }
            InstallerScreen::Update { .. } => Some(Button::Update),
            InstallerScreen::UninstallConfirm { .. } => Some(Button::Cancel),
            InstallerScreen::Progress { .. } => None,
            InstallerScreen::Done { job, .. } => Some(if job.is_linux() { Button::Continue } else { Button::Open }),
            InstallerScreen::Uninstalled { .. } => Some(Button::Close),
            InstallerScreen::Error { .. } => Some(Button::Close),
        }
    }

    /// The button Esc and the window's close button press.
    pub fn escape_button(&self) -> Option<Button> {
        match &self.screen {
            InstallerScreen::Welcome { job, .. } | InstallerScreen::Update { job, .. } => {
                Some(if job.is_linux() { Button::NotNow } else { Button::Cancel })
            }
            InstallerScreen::UninstallConfirm { .. } => Some(Button::Cancel),
            InstallerScreen::Progress { .. } => self.can_cancel().then_some(Button::Cancel),
            InstallerScreen::Done { job, .. } => Some(if job.is_linux() { Button::Continue } else { Button::Close }),
            InstallerScreen::Uninstalled { .. } | InstallerScreen::Error { .. } => Some(Button::Close),
        }
    }

    fn press(&mut self, button: Button) -> Vec<Effect> {
        match (button, self.screen.clone()) {
            (Button::Change, InstallerScreen::Welcome { location, nested, .. }) => {
                let start =
                    if nested { location.parent().map(Path::to_path_buf).unwrap_or(location) } else { location };
                vec![Effect::ChooseFolder(start)]
            }
            (Button::License, _) => vec![Effect::OpenLicense],
            (
                Button::Install | Button::AddToMenu,
                InstallerScreen::Welcome { job, location, desktop_shortcut, check, .. },
            ) if check.allows_install() => {
                self.start(JobRequest { job, location, desktop_shortcut, delete_data: false })
            }
            (Button::Update, InstallerScreen::Update { job, location, .. }) => {
                self.return_to = Some(Box::new(self.screen.clone()));
                self.start(JobRequest { job, location, desktop_shortcut: false, delete_data: false })
            }
            (Button::Uninstall, InstallerScreen::UninstallConfirm { job, location, delete_data, .. }) => {
                // The engine keeps shared settings and caches; the end screen must say the same.
                let delete_data = delete_data && self.facts.data_shared_with.is_none();
                self.start(JobRequest { job, location, desktop_shortcut: false, delete_data })
            }
            (Button::Cancel, InstallerScreen::Progress { .. }) => {
                if !self.can_cancel() {
                    return Vec::new();
                }
                if let InstallerScreen::Progress { canceling, .. } = &mut self.screen {
                    *canceling = true;
                }
                vec![Effect::CancelJob]
            }
            (Button::Close | Button::NotNow, InstallerScreen::Progress { .. }) => Vec::new(),
            (Button::NotNow, InstallerScreen::Welcome { .. } | InstallerScreen::Update { .. }) => {
                vec![Effect::Exit(Exit::Declined)]
            }
            (Button::Cancel | Button::Close, InstallerScreen::Welcome { .. } | InstallerScreen::Update { .. }) => {
                vec![Effect::Exit(self.leave_question())]
            }
            (Button::Cancel | Button::Close, InstallerScreen::UninstallConfirm { .. }) => {
                vec![Effect::Exit(Exit::Closed)]
            }
            (Button::Open, InstallerScreen::Done { opening: false, .. }) => {
                if let InstallerScreen::Done { opening, .. } = &mut self.screen {
                    *opening = true;
                }
                self.opening_since = Some(self.now);
                let exe = self.request.as_ref().map(|r| r.location.join(self.facts.app_exe_name)).unwrap_or_default();
                vec![Effect::LaunchApp(exe)]
            }
            (Button::Continue, InstallerScreen::Done { .. }) => vec![Effect::Exit(Exit::Added)],
            (Button::Close, InstallerScreen::Done { .. } | InstallerScreen::Uninstalled { .. }) => {
                vec![Effect::Exit(Exit::Closed)]
            }
            (Button::Close, InstallerScreen::Error { .. }) => vec![Effect::Exit(Exit::Closed)],
            _ => Vec::new(),
        }
    }

    /// Try Again on the error screen: the same job from the start.
    fn try_again(&mut self) -> Vec<Effect> {
        match (&self.screen, self.retry.clone()) {
            (InstallerScreen::Error { error, .. }, Some(request)) if error.code.retryable() => self.start(request),
            _ => Vec::new(),
        }
    }

    fn start(&mut self, request: JobRequest) -> Vec<Effect> {
        self.request = Some(request.clone());
        self.retry = Some(request.clone());
        let job = request.job.clone();
        let mut effects = vec![Effect::StartJob(request)];
        if job.is_linux() {
            self.quiet_since = Some(self.now);
        } else {
            self.screen = InstallerScreen::Progress {
                job,
                step: Step::Preparing,
                value: 0.0,
                detail: Step::Preparing.detail().to_string(),
                canceling: false,
                finished_at: None,
            };
            effects.push(Effect::Taskbar(Taskbar::Value(0.0)));
        }
        effects
    }

    fn location_picked(&mut self, picked: PathBuf) -> Vec<Effect> {
        let InstallerScreen::Welcome { job, location, nested, check, checking_since, .. } = &mut self.screen else {
            return Vec::new();
        };
        let (final_location, inside) = if job.is_linux() {
            (picked.clone(), false)
        } else {
            (resolve_location(&picked), resolve_location(&picked) != picked)
        };
        *location = final_location.clone();
        *nested = inside;
        *check = LocationCheck::Checking;
        *checking_since = Some(self.now);
        vec![Effect::CheckLocation(final_location)]
    }

    fn progress(&mut self, new_step: Step, new_value: f64, new_detail: String) -> Vec<Effect> {
        if let Some(since) = self.quiet_since
            && self.now - since >= PROGRESS_DELAY
        {
            self.enter_progress();
        }
        let InstallerScreen::Progress { step, value, detail, finished_at, .. } = &mut self.screen else {
            return Vec::new();
        };
        if finished_at.is_some() {
            return Vec::new();
        }
        *step = new_step;
        *value = value.max(new_value.clamp(0.0, 1.0));
        *detail = new_detail;
        vec![Effect::Taskbar(Taskbar::Value(*value))]
    }

    /// Linux: the work is slow enough to deserve its screen.
    fn enter_progress(&mut self) {
        let Some(job) = self.job().cloned() else { return };
        self.quiet_since = None;
        self.screen = InstallerScreen::Progress {
            job: job.clone(),
            step: job.steps().first().map_or(Step::Preparing, |s| s.0),
            value: 0.0,
            detail: String::new(),
            canceling: false,
            finished_at: None,
        };
    }

    fn job_ended(&mut self, result: Result<bool, SetupError>) -> Vec<Effect> {
        let was_quiet = self.quiet_since.take().is_some();
        let Some(request) = self.request.clone() else { return Vec::new() };
        match result {
            Ok(true) => {
                if was_quiet {
                    self.finish(&request.job, request.delete_data);
                    return Vec::new();
                }
                if let InstallerScreen::Progress { value, finished_at, step, .. } = &mut self.screen {
                    *value = 1.0;
                    *step = request.job.steps().last().map_or(*step, |s| s.0);
                    *finished_at = Some(self.now);
                }
                vec![Effect::Taskbar(Taskbar::Value(1.0))]
            }
            Ok(false) => match self.return_to.take() {
                Some(back) if matches!(request.job, Job::Update { .. } | Job::LinuxUpdate { .. }) => {
                    self.screen = *back;
                    vec![Effect::Taskbar(Taskbar::Off)]
                }
                _ => vec![Effect::Exit(Exit::Closed), Effect::Taskbar(Taskbar::Off)],
            },
            Err(error) => {
                self.screen = InstallerScreen::Error { job: request.job, error, log: self.log.clone() };
                vec![Effect::Taskbar(Taskbar::Error)]
            }
        }
    }

    /// `Open` could not start the app: the error card says why, so the setup does not close as if it had worked.
    fn app_not_started(&mut self, system: String) -> Vec<Effect> {
        let InstallerScreen::Done { job, .. } = self.screen.clone() else { return Vec::new() };
        if self.opening_since.take().is_none() {
            return Vec::new();
        }
        let mut error = SetupError::new(ErrorCode::AppNotStarted, "starting Sequence Studio", system);
        if let Some(request) = &self.request {
            error = error.with_path(&request.location.join(self.facts.app_exe_name));
        }
        self.screen = InstallerScreen::Error { job, error, log: self.log.clone() };
        vec![Effect::Taskbar(Taskbar::Error)]
    }

    /// The screen after a finished job.
    fn finish(&mut self, job: &Job, deleted_data: bool) {
        self.screen = if job.removes() {
            InstallerScreen::Uninstalled { job: job.clone(), deleted_data }
        } else {
            InstallerScreen::Done { job: job.clone(), opening: false }
        };
    }

    fn tick(&mut self) -> Vec<Effect> {
        let mut effects = Vec::new();
        if let Some(since) = self.quiet_since
            && self.now - since >= PROGRESS_DELAY
        {
            self.enter_progress();
        }
        if let InstallerScreen::Progress { job, finished_at: Some(at), .. } = &self.screen
            && self.now - at >= DONE_HOLD
        {
            let (job, deleted) = (job.clone(), self.request.as_ref().is_some_and(|r| r.delete_data));
            self.finish(&job, deleted);
            effects.push(Effect::Taskbar(Taskbar::Off));
        }
        if let Some(since) = self.opening_since
            && self.now - since >= OPEN_TIMEOUT
        {
            self.opening_since = None;
            effects.push(Effect::Exit(Exit::Closed));
        }
        effects
    }

    /// Whether the host must keep asking for frames: a job runs, a hold or a slow check waits.
    pub fn needs_ticks(&self) -> bool {
        self.quiet_since.is_some()
            || self.opening_since.is_some()
            || matches!(
                &self.screen,
                InstallerScreen::Progress { .. } | InstallerScreen::Welcome { checking_since: Some(_), .. }
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts() -> Facts {
        Facts {
            version: Version::new(0, 2, 0),
            app_exe_name: "SequenceStudio.exe",
            start_folder: PathBuf::from("/home/paul"),
            payload_bytes: 412 << 20,
            appimage_dir: Some(PathBuf::from("/home/paul/Downloads")),
            home: Some(PathBuf::from("/home/paul")),
            system_line: "Sequence Studio Setup 0.2.0 (x64) on Windows 11".into(),
            data_shared_with: None,
        }
    }

    fn welcome(job: Job) -> Machine {
        let location = PathBuf::from("/home/paul/Programs/Sequence Studio");
        Machine::new(Machine::welcome(job, location, LocationCheck::Ok { free: 50 << 30 }), facts())
    }

    fn update(job: Job, kind: UpdateKind) -> Machine {
        let screen = InstallerScreen::Update {
            job,
            installed: Version::new(0, 1, 2),
            location: PathBuf::from("/app"),
            app_running: false,
            kind,
        };
        Machine::new(screen, facts())
    }

    fn uninstall() -> Machine {
        let screen = InstallerScreen::UninstallConfirm {
            job: Job::Uninstall,
            location: PathBuf::from("/app"),
            delete_data: false,
            data_size: Measure::Loading,
        };
        Machine::new(screen, facts())
    }

    fn err() -> SetupError {
        SetupError::new(sq_setup_engine::ErrorCode::NoSpace, "copying files", "os error 112")
    }

    fn progress_event(value: f64) -> Event {
        Event::JobProgress { step: Step::Copying, value, detail: "198 of 412 MB".into() }
    }

    fn is_progress(m: &Machine) -> bool {
        matches!(m.screen, InstallerScreen::Progress { .. })
    }

    #[test]
    fn install_starts_the_job_with_the_welcome_choices_and_shows_progress() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Toggle(Check::DesktopShortcut), 0.0);
        let effects = m.handle(Event::Press(Button::Install), 1.0);
        let request = JobRequest {
            job: Job::Install,
            location: PathBuf::from("/home/paul/Programs/Sequence Studio"),
            desktop_shortcut: true,
            delete_data: false,
        };
        assert_eq!(effects, vec![Effect::StartJob(request), Effect::Taskbar(Taskbar::Value(0.0))]);
        assert!(is_progress(&m));
    }

    #[test]
    fn enter_installs_only_when_the_folder_takes_the_app() {
        let mut m = welcome(Job::Install);
        assert_eq!(m.default_button(), Some(Button::Install));
        m.handle(Event::LocationPicked(PathBuf::from("/apps")), 0.0);
        m.handle(
            Event::LocationChecked {
                location: PathBuf::from("/apps/Sequence Studio"),
                check: LocationCheck::NoSpace { need: 412 << 20, free: 120 << 20 },
            },
            0.1,
        );
        assert_eq!(m.default_button(), None);
        assert!(m.handle(Event::Enter, 0.2).is_empty(), "Enter does nothing while Install is disabled");
        assert!(m.handle(Event::Press(Button::Install), 0.2).is_empty());
        m.handle(
            Event::LocationChecked {
                location: PathBuf::from("/apps/Sequence Studio"),
                check: LocationCheck::NotWritable,
            },
            0.3,
        );
        assert!(!m.can_install());
    }

    #[test]
    fn picking_a_folder_appends_the_app_folder_and_checks_again() {
        let mut m = welcome(Job::Install);
        let effects = m.handle(Event::LocationPicked(PathBuf::from("/apps")), 2.0);
        assert_eq!(effects, vec![Effect::CheckLocation(PathBuf::from("/apps/Sequence Studio"))]);
        let InstallerScreen::Welcome { location, nested, check, checking_since, .. } = &m.screen else {
            panic!("not welcome")
        };
        assert_eq!(
            (location.as_path(), *nested, *check, *checking_since),
            (Path::new("/apps/Sequence Studio"), true, LocationCheck::Checking, Some(2.0))
        );
        m.handle(Event::LocationPicked(PathBuf::from("/apps/sequence studio")), 3.0);
        let InstallerScreen::Welcome { nested, .. } = &m.screen else { panic!("not welcome") };
        assert!(!nested, "a folder already called Sequence Studio is used as it is");
    }

    #[test]
    fn a_late_answer_for_another_folder_is_dropped() {
        let mut m = welcome(Job::Install);
        m.handle(Event::LocationPicked(PathBuf::from("/one")), 0.0);
        m.handle(Event::LocationPicked(PathBuf::from("/two")), 0.1);
        m.handle(
            Event::LocationChecked {
                location: PathBuf::from("/one/Sequence Studio"),
                check: LocationCheck::NotWritable,
            },
            0.2,
        );
        let InstallerScreen::Welcome { check, .. } = &m.screen else { panic!("not welcome") };
        assert_eq!(*check, LocationCheck::Checking, "the answer for D: is stale");
    }

    #[test]
    fn change_opens_the_chooser_at_the_folder_the_app_would_sit_in() {
        let mut m = welcome(Job::Install);
        let effects = m.handle(Event::Press(Button::Change), 0.0);
        assert!(matches!(&effects[..], [Effect::ChooseFolder(_)]));
        m.handle(Event::LocationPicked(PathBuf::from("/apps")), 0.0);
        let effects = m.handle(Event::Press(Button::Change), 0.0);
        assert_eq!(
            effects,
            vec![Effect::ChooseFolder(PathBuf::from("/apps"))],
            "the picked folder, not the one made from it"
        );
    }

    #[test]
    fn cancel_escape_and_the_close_button_leave_without_writing_anything() {
        for event in [Event::Press(Button::Cancel), Event::Escape] {
            let mut m = welcome(Job::Install);
            assert_eq!(m.handle(event, 0.0), vec![Effect::Exit(Exit::Closed)]);
        }
        let mut m = update(Job::Update { from: Version::new(0, 1, 2) }, UpdateKind::Newer);
        assert_eq!(m.handle(Event::Escape, 0.0), vec![Effect::Exit(Exit::Closed)]);
        let mut m = uninstall();
        assert_eq!(m.handle(Event::Press(Button::Cancel), 0.0), vec![Effect::Exit(Exit::Closed)]);
    }

    #[test]
    fn linux_not_now_escape_and_close_are_the_remembered_decline() {
        for event in [Event::Press(Button::NotNow), Event::Escape] {
            let mut m = welcome(Job::LinuxAdd);
            assert_eq!(m.handle(event, 0.0), vec![Effect::Exit(Exit::Declined)]);
        }
        let m = welcome(Job::LinuxAdd);
        assert_eq!(m.default_button(), Some(Button::AddToMenu));
    }

    #[test]
    fn update_starts_the_update_and_a_canceled_update_comes_back_to_the_update_screen() {
        let job = Job::Update { from: Version::new(0, 1, 2) };
        let mut m = update(job.clone(), UpdateKind::Newer);
        let before = m.screen.clone();
        let effects = m.handle(Event::Enter, 0.0);
        assert!(matches!(&effects[0], Effect::StartJob(r) if r.job == job));
        m.handle(progress_event(0.3), 0.1);
        assert_eq!(m.handle(Event::Escape, 0.2), vec![Effect::CancelJob]);
        let InstallerScreen::Progress { canceling, .. } = &m.screen else { panic!("not progress") };
        assert!(canceling);
        m.handle(Event::JobEnded(Ok(false)), 0.3);
        assert_eq!(m.screen, before, "the old version is untouched, the question is shown again");
    }

    #[test]
    fn a_canceled_install_closes_the_window() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(Event::Press(Button::Cancel), 0.1);
        let effects = m.handle(Event::JobEnded(Ok(false)), 0.2);
        assert!(effects.contains(&Effect::Exit(Exit::Closed)));
    }

    #[test]
    fn the_bar_only_rises_and_cancel_closes_at_ninety_percent() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(progress_event(0.5), 0.1);
        m.handle(progress_event(0.4), 0.2);
        let InstallerScreen::Progress { value, .. } = &m.screen else { panic!("not progress") };
        assert_eq!(*value, 0.5);
        assert!(m.can_cancel());
        m.handle(progress_event(0.9), 0.3);
        assert!(!m.can_cancel(), "from 90 % on the registry step is not cut in half");
        assert!(m.handle(Event::Escape, 0.4).is_empty());
        assert!(m.handle(Event::Enter, 0.4).is_empty(), "Enter does nothing on the progress screen");
    }

    #[test]
    fn a_finished_job_holds_the_full_bar_then_shows_done() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(progress_event(0.95), 0.1);
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        let InstallerScreen::Progress { value, .. } = &m.screen else { panic!("not progress") };
        assert_eq!(*value, 1.0);
        m.handle(Event::Tick, 1.2);
        assert!(is_progress(&m), "the hold is 250 ms");
        m.handle(Event::Tick, 1.0 + DONE_HOLD);
        assert_eq!(m.screen, InstallerScreen::Done { job: Job::Install, opening: false });
    }

    #[test]
    fn a_failure_shows_the_error_and_try_again_runs_the_same_job_from_the_start() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Toggle(Check::DesktopShortcut), 0.0);
        m.handle(Event::Enter, 0.0);
        m.handle(progress_event(0.6), 0.1);
        let effects = m.handle(Event::JobEnded(Err(err())), 0.2);
        assert_eq!(effects, vec![Effect::Taskbar(Taskbar::Error)]);
        assert!(matches!(m.screen, InstallerScreen::Error { .. }));
        let effects = m.handle(Event::TryAgain, 0.3);
        assert!(matches!(&effects[0], Effect::StartJob(r) if r.desktop_shortcut && r.job == Job::Install));
        let InstallerScreen::Progress { value, .. } = &m.screen else { panic!("not progress") };
        assert_eq!(*value, 0.0);
    }

    #[test]
    fn a_damaged_download_cannot_be_retried() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(
            Event::JobEnded(Err(SetupError::new(sq_setup_engine::ErrorCode::PayloadDamaged, "checking", "hash"))),
            0.1,
        );
        assert!(m.handle(Event::TryAgain, 0.2).is_empty());
    }

    #[test]
    fn done_opens_the_app_and_closes_when_its_window_is_up_or_after_ten_seconds() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        m.handle(Event::Tick, 2.0);
        assert_eq!(m.default_button(), Some(Button::Open));
        let effects = m.handle(Event::Enter, 3.0);
        assert!(matches!(&effects[..], [Effect::LaunchApp(p)] if p.ends_with("SequenceStudio.exe")));
        assert_eq!(m.screen, InstallerScreen::Done { job: Job::Install, opening: true });
        assert!(m.handle(Event::Press(Button::Open), 3.1).is_empty(), "no input while it opens");
        assert_eq!(m.handle(Event::AppUp, 4.0), vec![Effect::Exit(Exit::Closed)]);

        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        m.handle(Event::Tick, 2.0);
        m.handle(Event::Enter, 3.0);
        assert!(m.handle(Event::Tick, 12.0).is_empty());
        assert_eq!(m.handle(Event::Tick, 3.0 + OPEN_TIMEOUT), vec![Effect::Exit(Exit::Closed)]);
    }

    #[test]
    fn an_app_that_cannot_start_shows_the_error_card_instead_of_closing_the_setup() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        m.handle(Event::LogAt(PathBuf::from("/tmp/setup.log")), 0.0);
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        m.handle(Event::Tick, 2.0);
        m.handle(Event::Enter, 3.0);
        let effects = m.handle(Event::AppNotStarted("os error 5 \u{b7} Access is denied.".into()), 3.1);
        assert_eq!(effects, vec![Effect::Taskbar(Taskbar::Error)]);
        let InstallerScreen::Error { job, error, log } = &m.screen else { panic!("not the error card") };
        assert_eq!(*job, Job::Install);
        assert_eq!(error.code, ErrorCode::AppNotStarted);
        assert_eq!(error.system, "os error 5 \u{b7} Access is denied.");
        assert!(error.path.as_ref().is_some_and(|p| p.ends_with("SequenceStudio.exe")));
        assert_eq!(log.as_deref(), Some(Path::new("/tmp/setup.log")), "Open log shows the install log");
        assert!(m.handle(Event::Tick, 20.0).is_empty(), "the ten-second wait no longer closes the setup");
        assert!(m.handle(Event::TryAgain, 20.1).is_empty(), "there is no job to run again");
        assert_eq!(m.handle(Event::Press(Button::Close), 21.0), vec![Effect::Exit(Exit::Closed)]);

        let mut m = Machine::new(InstallerScreen::Done { job: Job::Install, opening: false }, facts());
        assert!(m.handle(Event::AppNotStarted("late".into()), 0.0).is_empty(), "no Open was pressed");
        assert_eq!(m.screen, InstallerScreen::Done { job: Job::Install, opening: false });
    }

    #[test]
    fn done_closes_with_escape_and_close() {
        let mut m = Machine::new(InstallerScreen::Done { job: Job::Install, opening: false }, facts());
        assert_eq!(m.handle(Event::Escape, 0.0), vec![Effect::Exit(Exit::Closed)]);
        assert_eq!(m.handle(Event::Press(Button::Close), 0.0), vec![Effect::Exit(Exit::Closed)]);
    }

    #[test]
    fn uninstall_never_takes_enter_and_runs_with_the_chosen_data_option() {
        let mut m = uninstall();
        assert!(m.handle(Event::Enter, 0.0) == vec![Effect::Exit(Exit::Closed)], "Enter is Cancel here");
        let mut m = uninstall();
        m.handle(Event::DataMeasured(Measure::Bytes(2 << 30)), 0.0);
        m.handle(Event::Toggle(Check::DeleteData), 0.1);
        let effects = m.handle(Event::Press(Button::Uninstall), 0.2);
        assert!(matches!(&effects[0], Effect::StartJob(r) if r.job == Job::Uninstall && r.delete_data));
        assert!(!m.can_cancel(), "a removal cannot be rolled back");
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        m.handle(Event::Tick, 1.3);
        assert_eq!(m.screen, InstallerScreen::Uninstalled { job: Job::Uninstall, deleted_data: true });
        assert_eq!(m.handle(Event::Enter, 2.0), vec![Effect::Exit(Exit::Closed)]);
    }

    #[test]
    fn uninstall_with_the_other_channel_installed_never_reports_deleted_data() {
        let mut m = uninstall();
        m.facts.data_shared_with = Some("Sequence Studio Nightly");
        m.handle(Event::Toggle(Check::DeleteData), 0.1);
        let effects = m.handle(Event::Press(Button::Uninstall), 0.2);
        assert!(matches!(&effects[0], Effect::StartJob(r) if !r.delete_data));
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        m.handle(Event::Tick, 1.3);
        assert_eq!(m.screen, InstallerScreen::Uninstalled { job: Job::Uninstall, deleted_data: false });
    }

    #[test]
    fn uninstall_runs_while_the_size_is_still_measured() {
        let mut m = uninstall();
        let effects = m.handle(Event::Press(Button::Uninstall), 0.0);
        assert!(matches!(&effects[0], Effect::StartJob(r) if !r.delete_data));
    }

    #[test]
    fn linux_goes_straight_to_done_when_the_work_is_quick() {
        let mut m = welcome(Job::LinuxAdd);
        let effects = m.handle(Event::Enter, 0.0);
        assert_eq!(effects.len(), 1, "no taskbar on Linux");
        assert!(matches!(m.screen, InstallerScreen::Welcome { .. }), "no progress screen yet");
        assert!(m.handle(Event::Press(Button::NotNow), 0.05).is_empty(), "no second answer while it works");
        m.handle(Event::JobEnded(Ok(true)), 0.1);
        assert_eq!(m.screen, InstallerScreen::Done { job: Job::LinuxAdd, opening: false });
        assert_eq!(m.default_button(), Some(Button::Continue));
        assert_eq!(m.handle(Event::Escape, 0.5), vec![Effect::Exit(Exit::Added)]);
    }

    /// The "Finishing 99 %" bug: the tick that ends the hold turns Progress into Done without any input, and the window,
    /// asleep once nothing animates, only drew the new screen after the next key press.
    #[test]
    fn the_tick_that_ends_the_hold_changes_the_screen_and_says_so() {
        let mut m = welcome(Job::Install);
        m.handle(Event::Enter, 0.0);
        let started = m.revision();
        m.handle(Event::JobProgress { step: Step::Finishing, value: 0.99, detail: String::new() }, 0.5);
        assert!(m.revision() > started, "a progress message changes the screen");
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        let held = m.revision();
        m.handle(Event::Tick, 1.0 + DONE_HOLD / 2.0);
        assert_eq!(m.revision(), held, "a tick that changes nothing does not count");
        m.handle(Event::Tick, 1.0 + DONE_HOLD);
        assert!(matches!(m.screen, InstallerScreen::Done { .. }));
        assert!(m.revision() > held, "the tick that ends the hold counts: the window must draw the Done screen");
        let done = m.revision();
        m.handle(Event::Tick, 5.0);
        assert_eq!(m.revision(), done);
    }

    #[test]
    fn linux_shows_progress_only_after_four_hundred_milliseconds() {
        let mut m = welcome(Job::LinuxAdd);
        m.handle(Event::Enter, 0.0);
        m.handle(Event::Tick, 0.3);
        assert!(matches!(m.screen, InstallerScreen::Welcome { .. }));
        m.handle(Event::Tick, PROGRESS_DELAY);
        assert!(is_progress(&m));
        assert!(m.needs_ticks());
    }

    #[test]
    fn the_slow_check_note_waits_for_its_delay_and_ticks_run_while_it_waits() {
        let mut m = welcome(Job::Install);
        assert!(!m.needs_ticks());
        m.handle(Event::LocationPicked(PathBuf::from("/nas/share")), 0.0);
        assert!(m.needs_ticks());
        assert!(m.can_install(), "Install stays enabled while checking");
    }

    #[test]
    fn the_update_screen_follows_the_running_app_and_names_the_kind() {
        let installed = Version::new(0, 1, 2);
        let mut m = update(Job::Update { from: installed }, UpdateKind::Newer);
        m.handle(Event::AppRunning(true), 0.0);
        let InstallerScreen::Update { app_running, .. } = &m.screen else { panic!("not update") };
        assert!(app_running);
    }

    #[test]
    fn license_and_unrelated_presses_do_nothing_surprising() {
        let mut m = welcome(Job::Install);
        assert_eq!(m.handle(Event::Press(Button::License), 0.0), vec![Effect::OpenLicense]);
        assert!(m.handle(Event::Press(Button::Open), 0.0).is_empty());
        assert!(m.handle(Event::Press(Button::Uninstall), 0.0).is_empty());
    }
}
