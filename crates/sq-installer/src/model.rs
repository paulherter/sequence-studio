//! What each screen says, as data: slot, title, sub line, card rows or progress, note and buttons. `Model::of` is a pure
//! function of the machine's state, so every text of the design is tested without drawing. Spec: `design/installer/spec.md`
//! §6; the error screen is `sq_draw_shell::ErrorView` and is not modeled here.

use crate::machine::{Button, CHECK_DELAY, Check, InstallerScreen, LocationCheck, Machine, Measure, UpdateKind};
use sq_draw::stone::ButtonKind;
use sq_setup_engine::{Job, Step, format_size};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmascot_model::SQMascotAnim;
use std::path::Path;

/// The 40 pt slot left of the title.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Slot {
    AppIcon,
    Pip(SQMascotAnim),
    /// `SlotIcon::Warn`: a newer version is installed.
    Warn,
}

/// The line under the title.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Sub {
    Text(String),
    /// `0.1.2 → 0.2.0`: the old one quiet, an arrow, the new one.
    Versions {
        old: String,
        new: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    Text(String),
    /// A path in the middle-ellipsized style.
    Path(String),
    Checkbox {
        check: Check,
        on: bool,
        label: &'static str,
        suffix: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub label: &'static str,
    pub value: Value,
    /// `Change…`.
    pub button: Option<Btn>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteTone {
    Plain,
    /// `RED_TEXT`: the Install button is dead.
    Error,
    /// A caution icon in `EXP_TEXT`, text in `TEXT2`.
    Caution,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Note {
    pub text: String,
    pub tone: NoteTone,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Look {
    Accent,
    Raised,
    Destructive,
    Quiet,
}

impl Look {
    pub fn kind(self) -> ButtonKind {
        match self {
            Look::Accent => ButtonKind::Accent,
            Look::Raised => ButtonKind::Raised,
            Look::Destructive => ButtonKind::Destructive,
            Look::Quiet => ButtonKind::Quiet,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Btn {
    pub id: Button,
    pub label: String,
    pub look: Look,
    pub enabled: bool,
    /// The button shows `Loading` (the app is opening): no input, the label stays.
    pub loading: bool,
    pub icon: Option<SQIcon>,
}

impl Btn {
    fn new(id: Button, label: impl Into<String>, look: Look) -> Btn {
        Btn { id, label: label.into(), look, enabled: true, loading: false, icon: None }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Body {
    Card(Vec<Row>),
    Progress {
        label: String,
        /// The real value 0..=1; the view draws its own smoothed one and prints the floor of that.
        fraction: f64,
        detail: String,
    },
}

/// Something Tab can focus.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Button(Button),
    Check(Check),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Model {
    pub slot: Slot,
    pub title: String,
    pub sub: Sub,
    pub body: Body,
    pub note: Option<Note>,
    /// Quiet or destructive buttons on the left of the footer.
    pub footer_left: Vec<Btn>,
    /// Raised then accent buttons, right aligned.
    pub footer_right: Vec<Btn>,
}

/// `C:\Users\Anna\...` as the card shows it; Linux paths under the home folder start with `~`.
pub fn display_path(path: &Path, home: Option<&Path>) -> String {
    if let Some(home) = home
        && let Ok(rest) = path.strip_prefix(home)
    {
        return if rest.as_os_str().is_empty() { "~".to_string() } else { format!("~/{}", rest.display()) };
    }
    path.display().to_string()
}

/// The path cut in the middle at its separators, keeping the first folders and the last one: `C:\Users\Anna\\u{2026}\Sequence Studio`.
/// `fits` says whether a candidate is narrow enough. A path that fits is returned as it is; when even `first\\u{2026}\last` does
/// not fit, the last folder alone is shortened at its end by the caller's own ellipsis.
pub fn ellipsize_path(path: &str, fits: impl Fn(&str) -> bool) -> String {
    if fits(path) {
        return path.to_string();
    }
    let sep = if path.contains('\\') { '\\' } else { '/' };
    let parts: Vec<&str> = path.split(sep).collect();
    let last = parts.last().copied().unwrap_or_default();
    for keep in (0..parts.len().saturating_sub(1)).rev() {
        let head = parts[..keep].join(&sep.to_string());
        let candidate =
            if keep == 0 { format!("\u{2026}{sep}{last}") } else { format!("{head}{sep}\u{2026}{sep}{last}") };
        if fits(&candidate) {
            return candidate;
        }
    }
    format!("\u{2026}{sep}{last}")
}

/// `D:` from `D:\Apps`, for `Not enough space on D:.`
fn drive_of(path: &Path) -> String {
    let text = path.to_string_lossy();
    match text.as_bytes() {
        [letter, b':', ..] if letter.is_ascii_alphabetic() => format!("{}:", *letter as char),
        _ => "this drive".to_string(),
    }
}

/// `198 of 412 MB`: the bytes done, in the unit of the total.
pub fn bytes_of_total(done: u64, total: u64) -> String {
    const GB: u64 = 1 << 30;
    const MB: u64 = 1 << 20;
    if total >= GB {
        let tenths = (done.min(total) * 10 + GB / 2) / GB;
        format!("{}.{} of {}", tenths / 10, tenths % 10, format_size(total))
    } else {
        format!("{} of {}", (done.min(total) + MB / 2) / MB, format_size(total))
    }
}

fn row(label: &'static str, value: Value) -> Row {
    Row { label, value, button: None }
}

impl Model {
    pub fn of(machine: &Machine) -> Model {
        let f = &machine.facts;
        let new = f.version.to_string();
        let home = f.home.as_deref();
        match &machine.screen {
            InstallerScreen::Welcome { job, location, nested, check, checking_since, desktop_shortcut } => {
                let linux = job.is_linux();
                let change = Btn::new(Button::Change, "Change\u{2026}", Look::Raised);
                let place =
                    Row { label: "Location", value: Value::Path(display_path(location, home)), button: Some(change) };
                let second = if linux {
                    row("Adds", Value::Text("Menu entry \u{b7} opens .sqproj projects".into()))
                } else {
                    row(
                        "Shortcut",
                        Value::Checkbox {
                            check: Check::DesktopShortcut,
                            on: *desktop_shortcut,
                            label: "Add to desktop",
                            suffix: None,
                        },
                    )
                };
                let slow = checking_since.is_some_and(|t| machine.now - t >= CHECK_DELAY);
                let note = match check {
                    LocationCheck::NoSpace { need, free } => Note {
                        text: format!(
                            "Not enough space on {}. Needs {}, {} free.",
                            drive_of(location),
                            format_size(*need),
                            format_size(*free)
                        ),
                        tone: NoteTone::Error,
                    },
                    LocationCheck::NotWritable => Note {
                        text: "This folder needs admin rights. Pick a folder in your user folder.".into(),
                        tone: NoteTone::Error,
                    },
                    LocationCheck::Checking if slow => Note { text: "Checking free space\u{2026}".into(), tone: NoteTone::Plain },
                    _ if *nested => Note {
                        text: "Sequence Studio goes into a new \u{201c}Sequence Studio\u{201d} folder inside the one you pick.".into(),
                        tone: NoteTone::Plain,
                    },
                    _ if linux => Note { text: linux_note(location, f.appimage_dir.as_deref(), home), tone: NoteTone::Plain },
                    _ => Note {
                        text: "Adds Sequence Studio to the Start menu and opens .sqproj projects with it. No admin rights needed.".into(),
                        tone: NoteTone::Plain,
                    },
                };
                let mut right = Vec::new();
                let mut left = Vec::new();
                if linux {
                    right.push(Btn::new(Button::NotNow, "Not Now", Look::Raised));
                    let mut add = Btn::new(Button::AddToMenu, "Add to App Menu", Look::Accent);
                    add.enabled = check.allows_install();
                    right.push(add);
                } else {
                    left.push(Btn::new(Button::License, "License", Look::Quiet));
                    right.push(Btn::new(Button::Cancel, "Cancel", Look::Raised));
                    let mut install = Btn::new(Button::Install, "Install", Look::Accent);
                    install.enabled = check.allows_install();
                    right.push(install);
                }
                Model {
                    slot: Slot::AppIcon,
                    title: if linux { "Add Sequence Studio to your apps" } else { "Install Sequence Studio" }.into(),
                    sub: Sub::Text(if linux {
                        format!("Version {new} \u{b7} AppImage")
                    } else {
                        format!("Version {new} \u{b7} {}", format_size(f.payload_bytes))
                    }),
                    body: Body::Card(vec![place, second]),
                    note: Some(note),
                    footer_left: left,
                    footer_right: right,
                }
            }
            InstallerScreen::Update { job, installed, location, app_running, kind } => {
                let linux = job.is_linux();
                let (title, sub, primary, slot) = match kind {
                    UpdateKind::Newer => (
                        "Update Sequence Studio".to_string(),
                        Sub::Versions { old: installed.to_string(), new: new.clone() },
                        format!("Update to {new}"),
                        Slot::AppIcon,
                    ),
                    UpdateKind::Same => (
                        "Reinstall Sequence Studio".to_string(),
                        Sub::Text(format!("{new} is installed")),
                        "Reinstall".to_string(),
                        Slot::AppIcon,
                    ),
                    UpdateKind::Older => (
                        "A newer version is installed".to_string(),
                        Sub::Text(format!("{installed} installed \u{b7} this is {new}")),
                        format!("Replace with {new}"),
                        Slot::Warn,
                    ),
                };
                let note = if *app_running {
                    Some(Note {
                        text: "Sequence Studio is open. Save your work first; it closes when the update starts.".into(),
                        tone: NoteTone::Caution,
                    })
                } else if linux {
                    Some(Note { text: "The old app file goes to the Trash.".into(), tone: NoteTone::Plain })
                } else {
                    None
                };
                let secondary = if linux {
                    Btn::new(Button::NotNow, "Not Now", Look::Raised)
                } else {
                    Btn::new(Button::Cancel, "Cancel", Look::Raised)
                };
                Model {
                    slot,
                    title,
                    sub,
                    body: Body::Card(vec![
                        row("Location", Value::Path(display_path(location, home))),
                        row("Keeps", Value::Text("Projects, settings, shortcuts and presets".into())),
                    ]),
                    note,
                    footer_left: Vec::new(),
                    footer_right: vec![secondary, Btn::new(Button::Update, primary, Look::Accent)],
                }
            }
            InstallerScreen::UninstallConfirm { delete_data, data_size, .. } => {
                let mut rows = vec![
                    row("Removes", Value::Text("The app, its Start menu entry and the .sqproj link".into())),
                    row("Keeps", Value::Text("Your projects and media".into())),
                ];
                let suffix = match data_size {
                    Measure::Empty => None,
                    Measure::Loading => Some(Some("\u{2026}".to_string())),
                    Measure::Failed => Some(None),
                    Measure::Bytes(n) => Some(Some(format_size(*n))),
                };
                if let Some(suffix) = suffix {
                    rows.push(row(
                        "Also",
                        Value::Checkbox {
                            check: Check::DeleteData,
                            on: *delete_data,
                            label: "Delete settings and caches",
                            suffix,
                        },
                    ));
                }
                Model {
                    slot: Slot::AppIcon,
                    title: "Uninstall Sequence Studio?".into(),
                    sub: Sub::Text(format!("Version {new}")),
                    body: Body::Card(rows),
                    note: None,
                    footer_left: vec![Btn::new(Button::Uninstall, "Uninstall", Look::Destructive)],
                    footer_right: vec![Btn::new(Button::Cancel, "Cancel", Look::Raised)],
                }
            }
            InstallerScreen::Progress { job, step, value, detail, canceling, .. } => {
                let (label, sub_line) = if *canceling {
                    ("Canceling\u{2026}".to_string(), "Removing the copied files".to_string())
                } else if *step == Step::Copying {
                    (
                        step.label().to_string(),
                        bytes_of_total(copied_bytes(job, *value, f.payload_bytes), f.payload_bytes),
                    )
                } else {
                    (
                        step.label().to_string(),
                        if detail.is_empty() { step.detail().to_string() } else { detail.clone() },
                    )
                };
                let mut cancel = Btn::new(Button::Cancel, "Cancel", Look::Raised);
                cancel.enabled = machine.can_cancel();
                Model {
                    slot: Slot::AppIcon,
                    title: job.progress_title(&f.version),
                    sub: Sub::Text(format!("Version {new}")),
                    body: Body::Progress { label, fraction: *value, detail: sub_line },
                    note: None,
                    footer_left: Vec::new(),
                    footer_right: vec![cancel],
                }
            }
            InstallerScreen::Done { job, opening } => {
                let linux = job.is_linux();
                let location = machine.request.as_ref().map(|r| display_path(&r.location, home)).unwrap_or_default();
                let desktop = machine.request.as_ref().is_some_and(|r| r.desktop_shortcut);
                let (title, sub) = match job {
                    Job::Update { from } | Job::LinuxUpdate { from } => {
                        (format!("Sequence Studio {new} is ready"), format!("Updated from {from}"))
                    }
                    _ if linux => ("Sequence Studio is in your app menu".to_string(), format!("Version {new}")),
                    _ => ("Sequence Studio is installed".to_string(), format!("Version {new}")),
                };
                let added = if linux {
                    "Menu entry \u{b7} .sqproj projects".to_string()
                } else if desktop {
                    "Start menu \u{b7} .sqproj projects \u{b7} Desktop shortcut".to_string()
                } else {
                    "Start menu \u{b7} .sqproj projects".to_string()
                };
                let footer_right = if linux {
                    vec![Btn::new(Button::Continue, "Continue", Look::Accent)]
                } else {
                    let mut open = Btn::new(
                        Button::Open,
                        if *opening { "Opening\u{2026}" } else { "Open Sequence Studio" },
                        Look::Accent,
                    );
                    open.loading = *opening;
                    open.enabled = !*opening;
                    vec![Btn::new(Button::Close, "Close", Look::Raised), open]
                };
                Model {
                    slot: Slot::Pip(SQMascotAnim::Wink),
                    title,
                    sub: Sub::Text(sub),
                    body: Body::Card(vec![row("Location", Value::Path(location)), row("Added", Value::Text(added))]),
                    note: None,
                    footer_left: Vec::new(),
                    footer_right,
                }
            }
            InstallerScreen::Uninstalled { deleted_data, .. } => {
                let removed = if *deleted_data {
                    "App, Start menu entry, .sqproj link, settings and caches"
                } else {
                    "App, Start menu entry, .sqproj link"
                };
                let kept = if *deleted_data { "Projects, media" } else { "Projects, media, settings and caches" };
                Model {
                    slot: Slot::Pip(SQMascotAnim::Sleep),
                    title: "Sequence Studio is uninstalled".into(),
                    sub: Sub::Text(format!("Version {new}")),
                    body: Body::Card(vec![
                        row("Removed", Value::Text(removed.into())),
                        row("Kept", Value::Text(kept.into())),
                    ]),
                    note: None,
                    footer_left: Vec::new(),
                    footer_right: vec![Btn::new(Button::Close, "Close", Look::Accent)],
                }
            }
            InstallerScreen::Error { job, error, .. } => Model {
                slot: Slot::AppIcon,
                title: error.title(job).into(),
                sub: Sub::Text(String::new()),
                body: Body::Card(Vec::new()),
                note: None,
                footer_left: Vec::new(),
                footer_right: Vec::new(),
            },
        }
    }

    /// Tab order: card controls, footer left, footer right (spec §9).
    pub fn tab_order(&self) -> Vec<Target> {
        let mut order = Vec::new();
        if let Body::Card(rows) = &self.body {
            for r in rows {
                if let Some(b) = r.button.as_ref().filter(|b| b.enabled) {
                    order.push(Target::Button(b.id));
                }
                if let Value::Checkbox { check, .. } = &r.value {
                    order.push(Target::Check(*check));
                }
            }
        }
        for b in self.footer_left.iter().chain(&self.footer_right) {
            if b.enabled {
                order.push(Target::Button(b.id));
            }
        }
        order
    }
}

/// How many bytes the copy step has written at the overall `value` of the bar.
fn copied_bytes(job: &Job, value: f64, total: u64) -> u64 {
    let Some((_, start, end)) = job.steps().iter().find(|s| s.0 == Step::Copying).copied() else { return 0 };
    let share = ((value - start) / (end - start)).clamp(0.0, 1.0);
    (share * total as f64) as u64
}

/// The note under the Linux card: where the AppImage comes from (dropped when it already sits in the chosen folder).
fn linux_note(location: &Path, from: Option<&Path>, home: Option<&Path>) -> String {
    let tail = "Remove it any time in Settings \u{203a} General.";
    match from {
        Some(dir) if dir != location => {
            format!("The AppImage moves here from {}, so the menu entry keeps working. {tail}", display_path(dir, home))
        }
        _ => tail.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machine::{Facts, JobRequest};
    use sq_setup_engine::Version;
    use std::path::PathBuf;

    fn facts() -> Facts {
        Facts {
            version: Version::new(0, 2, 0),
            app_exe_name: "SequenceStudio.exe",
            start_folder: PathBuf::from("/home/paul"),
            payload_bytes: 412 << 20,
            appimage_dir: Some(PathBuf::from("/home/paul/Downloads")),
            home: Some(PathBuf::from("/home/paul")),
            system_line: String::new(),
        }
    }

    fn machine(screen: InstallerScreen) -> Machine {
        Machine::new(screen, facts())
    }

    fn welcome(job: Job, check: LocationCheck) -> Machine {
        machine(Machine::welcome(job, PathBuf::from("/home/paul/Programs/Sequence Studio"), check))
    }

    fn labels(buttons: &[Btn]) -> Vec<&str> {
        buttons.iter().map(|b| b.label.as_str()).collect()
    }

    fn rows(m: &Model) -> Vec<(&'static str, String)> {
        let Body::Card(rows) = &m.body else { return Vec::new() };
        rows.iter()
            .map(|r| {
                let v = match &r.value {
                    Value::Text(t) | Value::Path(t) => t.clone(),
                    Value::Checkbox { label, suffix, .. } => match suffix {
                        Some(s) => format!("[ ] {label} {s}"),
                        None => format!("[ ] {label}"),
                    },
                };
                (r.label, v)
            })
            .collect()
    }

    #[test]
    fn windows_welcome_says_what_the_design_says() {
        let m = Model::of(&welcome(Job::Install, LocationCheck::Ok { free: 1 << 40 }));
        assert_eq!(m.title, "Install Sequence Studio");
        assert_eq!(m.sub, Sub::Text("Version 0.2.0 \u{b7} 412 MB".into()));
        assert_eq!(rows(&m)[0].0, "Location");
        assert_eq!(rows(&m)[1], ("Shortcut", "[ ] Add to desktop".into()));
        assert_eq!(
            m.note.map(|n| n.text),
            Some(
                "Adds Sequence Studio to the Start menu and opens .sqproj projects with it. No admin rights needed."
                    .into()
            )
        );
        assert_eq!(labels(&m.footer_left), ["License"]);
        assert_eq!(labels(&m.footer_right), ["Cancel", "Install"]);
        assert_eq!(m.footer_right[1].look, Look::Accent);
    }

    #[test]
    fn the_location_states_change_the_note_and_the_install_button() {
        let no_space = Model::of(&welcome(Job::Install, LocationCheck::NoSpace { need: 412 << 20, free: 120 << 20 }));
        let note = no_space.note.clone().map(|n| (n.text, n.tone));
        assert_eq!(note, Some(("Not enough space on this drive. Needs 412 MB, 120 MB free.".into(), NoteTone::Error)));
        assert!(!no_space.footer_right[1].enabled);
        let denied = Model::of(&welcome(Job::Install, LocationCheck::NotWritable));
        assert_eq!(
            denied.note.map(|n| n.text),
            Some("This folder needs admin rights. Pick a folder in your user folder.".into())
        );
        assert!(!denied.footer_right[1].enabled);
        let mut checking = welcome(Job::Install, LocationCheck::Checking);
        if let InstallerScreen::Welcome { checking_since, .. } = &mut checking.screen {
            *checking_since = Some(1.0);
        }
        checking.now = 1.1;
        assert_ne!(
            Model::of(&checking).note.map(|n| n.text),
            Some("Checking free space\u{2026}".into()),
            "not before 150 ms"
        );
        checking.now = 1.2;
        let m = Model::of(&checking);
        assert_eq!(m.note.map(|n| n.text), Some("Checking free space\u{2026}".into()));
        assert!(m.footer_right[1].enabled, "Install stays enabled while checking");
    }

    #[test]
    fn a_picked_folder_that_is_not_named_so_says_where_the_app_goes() {
        let mut m = welcome(Job::Install, LocationCheck::Ok { free: 1 << 40 });
        if let InstallerScreen::Welcome { nested, .. } = &mut m.screen {
            *nested = true;
        }
        assert_eq!(
            Model::of(&m).note.map(|n| n.text),
            Some(
                "Sequence Studio goes into a new \u{201c}Sequence Studio\u{201d} folder inside the one you pick."
                    .into()
            )
        );
    }

    #[test]
    fn a_long_path_loses_its_middle_folders_and_keeps_the_last_one() {
        let path = "C:\\Users\\Anna\\AppData\\Local\\Programs\\Sequence Studio";
        let fits = |max: usize| move |s: &str| s.chars().count() <= max;
        assert_eq!(ellipsize_path(path, fits(100)), path);
        assert_eq!(ellipsize_path(path, fits(46)), "C:\\Users\\Anna\\AppData\\Local\\\u{2026}\\Sequence Studio");
        assert_eq!(ellipsize_path(path, fits(30)), "C:\\Users\\\u{2026}\\Sequence Studio");
        assert_eq!(ellipsize_path(path, fits(10)), "\u{2026}\\Sequence Studio", "nothing fits: the last folder stays");
        assert_eq!(ellipsize_path("~/a/b/c/d", fits(6)), "~/\u{2026}/d");
    }

    #[test]
    fn the_drive_comes_from_the_path() {
        assert_eq!(drive_of(Path::new("D:\\Apps")), "D:");
        assert_eq!(drive_of(Path::new("/mnt/data")), "this drive");
    }

    #[test]
    fn linux_welcome_names_the_folder_the_appimage_comes_from() {
        let mut m = machine(Machine::welcome(
            Job::LinuxAdd,
            PathBuf::from("/home/paul/Applications"),
            LocationCheck::Ok { free: 1 << 40 },
        ));
        let model = Model::of(&m);
        assert_eq!(model.title, "Add Sequence Studio to your apps");
        assert_eq!(model.sub, Sub::Text("Version 0.2.0 \u{b7} AppImage".into()));
        assert_eq!(
            rows(&model),
            vec![("Location", "~/Applications".into()), ("Adds", "Menu entry \u{b7} opens .sqproj projects".into())]
        );
        assert_eq!(
            model.note.map(|n| n.text),
            Some("The AppImage moves here from ~/Downloads, so the menu entry keeps working. Remove it any time in Settings \u{203a} General.".into())
        );
        assert_eq!(labels(&model.footer_right), ["Not Now", "Add to App Menu"]);
        assert!(model.footer_left.is_empty());
        m.facts.appimage_dir = Some(PathBuf::from("/home/paul/Applications"));
        assert_eq!(
            Model::of(&m).note.map(|n| n.text),
            Some("Remove it any time in Settings \u{203a} General.".into()),
            "nothing moves when the file already sits there"
        );
    }

    #[test]
    fn the_update_screen_and_its_two_variants() {
        let installed = Version::new(0, 1, 2);
        let mk = |kind, installed: Version, running| {
            Model::of(&machine(InstallerScreen::Update {
                job: Job::Update { from: installed.clone() },
                installed,
                location: PathBuf::from("/app"),
                app_running: running,
                kind,
            }))
        };
        let up = mk(UpdateKind::Newer, installed.clone(), true);
        assert_eq!(up.title, "Update Sequence Studio");
        assert_eq!(up.sub, Sub::Versions { old: "0.1.2".into(), new: "0.2.0".into() });
        assert_eq!(rows(&up)[1], ("Keeps", "Projects, settings, shortcuts and presets".into()));
        let note = up.note.clone().map(|n| (n.text, n.tone));
        assert_eq!(
            note,
            Some((
                "Sequence Studio is open. Save your work first; it closes when the update starts.".into(),
                NoteTone::Caution
            ))
        );
        assert_eq!(labels(&up.footer_right), ["Cancel", "Update to 0.2.0"]);
        assert_eq!(mk(UpdateKind::Newer, installed.clone(), false).note, None);
        let same = mk(UpdateKind::Same, Version::new(0, 2, 0), false);
        assert_eq!(
            (same.title.as_str(), labels(&same.footer_right)),
            ("Reinstall Sequence Studio", vec!["Cancel", "Reinstall"])
        );
        assert_eq!(same.sub, Sub::Text("0.2.0 is installed".into()));
        let newer = mk(UpdateKind::Older, Version::new(0, 3, 0), false);
        assert_eq!(newer.slot, Slot::Warn);
        assert_eq!(newer.title, "A newer version is installed");
        assert_eq!(newer.sub, Sub::Text("0.3.0 installed \u{b7} this is 0.2.0".into()));
        assert_eq!(labels(&newer.footer_right), ["Cancel", "Replace with 0.2.0"]);
    }

    #[test]
    fn the_linux_update_has_a_trash_note_and_not_now() {
        let m = Model::of(&machine(InstallerScreen::Update {
            job: Job::LinuxUpdate { from: Version::new(0, 1, 2) },
            installed: Version::new(0, 1, 2),
            location: PathBuf::from("/home/paul/Applications/SequenceStudio.AppImage"),
            app_running: false,
            kind: UpdateKind::Newer,
        }));
        assert_eq!(m.note.map(|n| n.text), Some("The old app file goes to the Trash.".into()));
        assert_eq!(labels(&m.footer_right), ["Not Now", "Update to 0.2.0"]);
    }

    #[test]
    fn the_uninstall_confirm_hides_an_empty_row_and_shows_the_size() {
        let mk = |size| {
            Model::of(&machine(InstallerScreen::UninstallConfirm {
                job: Job::Uninstall,
                location: PathBuf::from("/app"),
                delete_data: false,
                data_size: size,
            }))
        };
        let m = mk(Measure::Bytes(2254857830));
        assert_eq!(m.title, "Uninstall Sequence Studio?");
        assert_eq!(rows(&m)[0], ("Removes", "The app, its Start menu entry and the .sqproj link".into()));
        assert_eq!(rows(&m)[1], ("Keeps", "Your projects and media".into()));
        assert_eq!(rows(&m)[2], ("Also", "[ ] Delete settings and caches 2.1 GB".into()));
        assert_eq!(labels(&m.footer_left), ["Uninstall"]);
        assert_eq!(m.footer_left[0].look, Look::Destructive);
        assert_eq!(labels(&m.footer_right), ["Cancel"]);
        assert_eq!(rows(&mk(Measure::Loading))[2].1, "[ ] Delete settings and caches \u{2026}");
        assert_eq!(rows(&mk(Measure::Failed))[2].1, "[ ] Delete settings and caches");
        assert_eq!(rows(&mk(Measure::Empty)).len(), 2, "no caches: the card has two rows");
    }

    #[test]
    fn progress_prints_the_step_the_bytes_and_a_cancel_that_dies_at_ninety_percent() {
        let mut m = welcome(Job::Install, LocationCheck::Ok { free: 1 << 40 });
        m.handle(crate::machine::Event::Enter, 0.0);
        m.handle(
            crate::machine::Event::JobProgress {
                step: Step::Copying,
                value: 0.04 + 0.86 * 0.48,
                detail: String::new(),
            },
            0.1,
        );
        let model = Model::of(&m);
        assert_eq!(model.title, "Installing Sequence Studio");
        let Body::Progress { label, detail, .. } = &model.body else { panic!("not progress") };
        assert_eq!((label.as_str(), detail.as_str()), ("Copying files", "198 of 412 MB"));
        assert!(model.footer_right[0].enabled);
        m.handle(crate::machine::Event::JobProgress { step: Step::StartMenu, value: 0.91, detail: String::new() }, 0.2);
        let model = Model::of(&m);
        assert!(!model.footer_right[0].enabled);
        let Body::Progress { label, detail, .. } = &model.body else { panic!("not progress") };
        assert_eq!((label.as_str(), detail.as_str()), ("Adding to the Start menu", "Registering the app"));
    }

    #[test]
    fn canceling_says_so_and_the_job_names_the_title() {
        let mut m = welcome(Job::Install, LocationCheck::Ok { free: 1 << 40 });
        m.handle(crate::machine::Event::Enter, 0.0);
        m.handle(crate::machine::Event::Press(Button::Cancel), 0.1);
        let model = Model::of(&m);
        let Body::Progress { label, detail, .. } = &model.body else { panic!("not progress") };
        assert_eq!((label.as_str(), detail.as_str()), ("Canceling\u{2026}", "Removing the copied files"));
        assert!(!model.footer_right[0].enabled);
        let mut up = machine(InstallerScreen::Progress {
            job: Job::Update { from: Version::new(0, 1, 2) },
            step: Step::Preparing,
            value: 0.0,
            detail: String::new(),
            canceling: false,
            finished_at: None,
        });
        up.request = Some(JobRequest {
            job: Job::Install,
            location: PathBuf::new(),
            desktop_shortcut: false,
            delete_data: false,
        });
        assert_eq!(Model::of(&up).title, "Updating to 0.2.0");
    }

    #[test]
    fn the_done_screens_name_where_and_what_was_added() {
        let mut m = machine(InstallerScreen::Done { job: Job::Install, opening: false });
        m.request = Some(JobRequest {
            job: Job::Install,
            location: PathBuf::from("/home/paul/Programs/Sequence Studio"),
            desktop_shortcut: true,
            delete_data: false,
        });
        let model = Model::of(&m);
        assert_eq!(model.slot, Slot::Pip(SQMascotAnim::Wink));
        assert_eq!(model.title, "Sequence Studio is installed");
        assert_eq!(rows(&model)[1], ("Added", "Start menu \u{b7} .sqproj projects \u{b7} Desktop shortcut".into()));
        assert_eq!(labels(&model.footer_right), ["Close", "Open Sequence Studio"]);
        m.screen = InstallerScreen::Done { job: Job::Install, opening: true };
        let model = Model::of(&m);
        assert!(model.footer_right[1].loading && !model.footer_right[1].enabled);
        assert_eq!(model.footer_right[1].label, "Opening\u{2026}");
        m.screen = InstallerScreen::Done { job: Job::Update { from: Version::new(0, 1, 2) }, opening: false };
        let model = Model::of(&m);
        assert_eq!(
            (model.title.as_str(), model.sub),
            ("Sequence Studio 0.2.0 is ready", Sub::Text("Updated from 0.1.2".into()))
        );
        m.screen = InstallerScreen::Done { job: Job::LinuxAdd, opening: false };
        let model = Model::of(&m);
        assert_eq!(model.title, "Sequence Studio is in your app menu");
        assert_eq!(labels(&model.footer_right), ["Continue"]);
    }

    #[test]
    fn uninstalled_lists_what_went_and_what_stays() {
        let mk =
            |deleted| Model::of(&machine(InstallerScreen::Uninstalled { job: Job::Uninstall, deleted_data: deleted }));
        let kept = mk(false);
        assert_eq!(kept.slot, Slot::Pip(SQMascotAnim::Sleep));
        assert_eq!(
            rows(&kept),
            vec![
                ("Removed", "App, Start menu entry, .sqproj link".into()),
                ("Kept", "Projects, media, settings and caches".into())
            ]
        );
        let wiped = mk(true);
        assert_eq!(
            rows(&wiped),
            vec![
                ("Removed", "App, Start menu entry, .sqproj link, settings and caches".into()),
                ("Kept", "Projects, media".into())
            ]
        );
        assert_eq!(wiped.footer_right[0].look, Look::Accent);
    }

    #[test]
    fn tab_walks_card_controls_then_footer_left_then_footer_right() {
        let m = Model::of(&welcome(Job::Install, LocationCheck::Ok { free: 1 << 40 }));
        assert_eq!(
            m.tab_order(),
            vec![
                Target::Button(Button::Change),
                Target::Check(Check::DesktopShortcut),
                Target::Button(Button::License),
                Target::Button(Button::Cancel),
                Target::Button(Button::Install)
            ]
        );
        let dead = Model::of(&welcome(Job::Install, LocationCheck::NotWritable));
        assert!(!dead.tab_order().contains(&Target::Button(Button::Install)), "Tab skips a disabled button");
    }

    #[test]
    fn sizes_in_the_progress_line_use_the_unit_of_the_total() {
        assert_eq!(bytes_of_total(198 << 20, 412 << 20), "198 of 412 MB");
        assert_eq!(bytes_of_total(1 << 30, 2 << 30), "1.0 of 2.0 GB");
        assert_eq!(bytes_of_total(5 << 30, 2 << 30), "2.0 of 2.0 GB", "never past the total");
    }

    #[test]
    fn paths_show_the_home_folder_as_a_tilde() {
        let home = Path::new("/home/paul");
        assert_eq!(display_path(Path::new("/home/paul/Applications"), Some(home)), "~/Applications");
        assert_eq!(display_path(Path::new("/home/paul"), Some(home)), "~");
        assert_eq!(display_path(Path::new("/opt/x"), Some(home)), "/opt/x");
        assert_eq!(display_path(Path::new("/home/paul/x"), None), "/home/paul/x");
    }
}
