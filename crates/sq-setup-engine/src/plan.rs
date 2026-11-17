//! The install plan: every shortcut and registry value of spec section 10.1 step 3 as data, and its inverse. Pure; the
//! engine runs the actions through a [`Host`](crate::host::Host).

use crate::job::Job;
use crate::version::Version;
use std::path::{Path, PathBuf};

/// The app program inside the install folder.
pub const EXE_NAME: &str = "SequenceStudio.exe";
/// The icon beside it (shortcut, file type and Add/Remove Programs use it).
pub const ICO_NAME: &str = "SequenceStudio.ico";
/// The setup program copy that removes the app.
pub const UNINSTALLER_NAME: &str = "Uninstall Sequence Studio.exe";
/// The name of the Start menu and desktop shortcut files, and of the install folder.
pub const APP_NAME: &str = "Sequence Studio";
/// Taskbar and notification identity; the same text as `sq_platform_win::toast::APP_USER_MODEL_ID`.
pub const AUMID: &str = "SequenceStudio.App";
pub const PROJECT_CLASS: &str = "SequenceStudio.Project";
pub const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\SequenceStudio";
/// The key the old Inno installer wrote (its AppId plus `_is1`).
pub const INNO_UNINSTALL_KEY: &str =
    r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{6C1E2A57-3B0D-4F52-9A0E-5E51A7C0D2B4}_is1";
const AUMID_KEY: &str = r"Software\Classes\AppUserModelId\SequenceStudio.App";
const SQPROJ_KEY: &str = r"Software\Classes\.sqproj";
const CLASS_KEY: &str = r"Software\Classes\SequenceStudio.Project";

/// What the user chose.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Options {
    pub desktop_shortcut: bool,
    /// Uninstall only: also remove the app's data and cache folders.
    pub delete_data: bool,
}

/// The folders a plan needs, given by the caller (the host's known folders and the app's data folders).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PlanEnv {
    pub start_menu_programs: PathBuf,
    pub desktop: PathBuf,
    pub temp: PathBuf,
    /// The app's folders under the data and cache directories; removed only on request.
    pub data_dirs: Vec<PathBuf>,
}

/// A `.lnk` file to create.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShortcutSpec {
    pub link: PathBuf,
    pub target: PathBuf,
    pub working_dir: PathBuf,
    pub icon: PathBuf,
    /// AppUserModelID of the shortcut (the Start menu and the desktop one both carry it).
    pub aumid: String,
}

/// One change to the system.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Shortcut(ShortcutSpec),
    /// HKCU string; `name: None` is the key's default value.
    RegSetString {
        key: String,
        name: Option<String>,
        value: String,
    },
    RegSetDword {
        key: String,
        name: String,
        value: u32,
    },
    /// Deletes the key and everything under it; a missing key is fine.
    RegDeleteKey(String),
    /// Deletes the value only while it still holds `equals` (`.sqproj` pointing to another program stays).
    RegDeleteValueIfEquals {
        key: String,
        name: Option<String>,
        equals: String,
    },
    /// Deletes the key when it has no value and no sub key left (the `.sqproj` key after our value is gone).
    RegDeleteKeyIfEmpty(String),
    RemoveFile(PathBuf),
    RemoveDirAll(PathBuf),
    /// Tells Explorer that file associations changed.
    AssocChanged,
}

fn s(text: &str) -> String {
    text.to_string()
}

fn string(key: &str, name: Option<&str>, value: impl Into<String>) -> Action {
    Action::RegSetString { key: s(key), name: name.map(s), value: value.into() }
}

fn dword(key: &str, name: &str, value: u32) -> Action {
    Action::RegSetDword { key: s(key), name: s(name), value }
}

/// The shortcut paths of an install: Start menu, then the desktop one.
fn links(env: &PlanEnv) -> [PathBuf; 2] {
    let file = format!("{APP_NAME}.lnk");
    [env.start_menu_programs.join(&file), env.desktop.join(file)]
}

fn install_actions(location: &Path, opts: &Options, env: &PlanEnv, version: &Version, size_kb: u32) -> Vec<Action> {
    let exe = location.join(EXE_NAME);
    let ico = location.join(ICO_NAME);
    let shortcut = |link: PathBuf| {
        Action::Shortcut(ShortcutSpec {
            link,
            target: exe.clone(),
            working_dir: location.to_path_buf(),
            icon: ico.clone(),
            aumid: s(AUMID),
        })
    };
    let [menu, desktop] = links(env);
    let mut out = vec![shortcut(menu)];
    if opts.desktop_shortcut {
        out.push(shortcut(desktop));
    }
    let uninstaller = location.join(UNINSTALLER_NAME);
    let uninstall = format!("\"{}\" --uninstall", uninstaller.display());
    out.extend([
        string(AUMID_KEY, Some("DisplayName"), APP_NAME),
        string(SQPROJ_KEY, None, PROJECT_CLASS),
        string(CLASS_KEY, None, "Sequence Studio project"),
        string(&format!(r"{CLASS_KEY}\DefaultIcon"), None, ico.display().to_string()),
        string(&format!(r"{CLASS_KEY}\shell\open\command"), None, format!("\"{}\" \"%1\"", exe.display())),
        string(UNINSTALL_KEY, Some("DisplayName"), APP_NAME),
        string(UNINSTALL_KEY, Some("DisplayVersion"), version.to_string()),
        string(UNINSTALL_KEY, Some("Publisher"), "Paul Herter"),
        string(UNINSTALL_KEY, Some("DisplayIcon"), format!("{},0", exe.display())),
        string(UNINSTALL_KEY, Some("InstallLocation"), location.display().to_string()),
        dword(UNINSTALL_KEY, "EstimatedSize", size_kb),
        string(UNINSTALL_KEY, Some("URLInfoAbout"), "https://getsequencestudio.com"),
        string(UNINSTALL_KEY, Some("HelpLink"), "https://github.com/paulherter/sequence-studio/issues"),
        dword(UNINSTALL_KEY, "NoModify", 1),
        dword(UNINSTALL_KEY, "NoRepair", 1),
        string(UNINSTALL_KEY, Some("UninstallString"), uninstall.clone()),
        string(UNINSTALL_KEY, Some("QuietUninstallString"), format!("{uninstall} --quiet")),
        Action::AssocChanged,
    ]);
    out
}

/// What `job` does to the system, in order. Install and update list the shortcuts and registry values (the files
/// themselves are the engine's own swap); uninstall lists their removal, then the data folders (only with
/// `delete_data`) and the install folder last. Linux jobs have no Windows plan: empty.
pub fn plan(job: &Job, location: &Path, opts: &Options, env: &PlanEnv, version: &Version, size_kb: u32) -> Vec<Action> {
    match job {
        Job::Install | Job::Update { .. } => install_actions(location, opts, env, version, size_kb),
        Job::Uninstall => {
            // Files first: when some stay, the engine stops before the registry, so the Uninstall entry is still there to
            // try again. The desktop shortcut is removed whether or not it exists: the plan cannot know what the user did.
            let all = Options { desktop_shortcut: true, ..*opts };
            let mut out: Vec<Action> = Vec::new();
            if opts.delete_data {
                out.extend(env.data_dirs.iter().cloned().map(Action::RemoveDirAll));
            }
            out.push(Action::RemoveDirAll(location.to_path_buf()));
            out.extend(inverse(&install_actions(location, &all, env, version, size_kb)));
            out
        }
        Job::LinuxAdd | Job::LinuxUpdate { .. } | Job::LinuxRemove => Vec::new(),
    }
}

/// What undoes `actions`: reversed, each action replaced by its opposite. Only what the actions add is removed; a
/// `RegDelete*`, `Remove*` or `AssocChanged` has no opposite beyond the notification.
pub fn inverse(actions: &[Action]) -> Vec<Action> {
    let mut out: Vec<Action> = Vec::new();
    let mut assoc = false;
    for action in actions.iter().rev() {
        match action {
            Action::Shortcut(spec) => out.push(Action::RemoveFile(spec.link.clone())),
            Action::RegSetString { key, name, value } if key == SQPROJ_KEY => {
                out.push(Action::RegDeleteValueIfEquals {
                    key: key.clone(),
                    name: name.clone(),
                    equals: value.clone(),
                });
                // Other programs' values keep the key; when ours was the only one, the empty key goes too.
                out.push(Action::RegDeleteKeyIfEmpty(key.clone()));
            }
            Action::RegSetString { key, .. } | Action::RegSetDword { key, .. } => {
                // One key-delete per top-level key of ours: the sub keys (DefaultIcon, shell) go with their class.
                let top = [UNINSTALL_KEY, AUMID_KEY, CLASS_KEY]
                    .into_iter()
                    .find(|t| key == t || key.starts_with(&format!("{t}\\")));
                if let Some(top) = top {
                    let del = Action::RegDeleteKey(s(top));
                    if !out.contains(&del) {
                        out.push(del);
                    }
                }
            }
            Action::AssocChanged => assoc = true,
            Action::RegDeleteKey(_)
            | Action::RegDeleteValueIfEquals { .. }
            | Action::RegDeleteKeyIfEmpty(_)
            | Action::RemoveFile(_)
            | Action::RemoveDirAll(_) => {}
        }
    }
    if assoc {
        out.push(Action::AssocChanged);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> PlanEnv {
        PlanEnv {
            start_menu_programs: PathBuf::from("/menu"),
            desktop: PathBuf::from("/desk"),
            temp: PathBuf::from("/tmp"),
            data_dirs: vec![PathBuf::from("/data/SequenceStudio"), PathBuf::from("/cache/SequenceStudio")],
        }
    }

    fn make(job: &Job, desktop: bool, delete_data: bool) -> Vec<Action> {
        let opts = Options { desktop_shortcut: desktop, delete_data };
        plan(job, Path::new("/apps/Sequence Studio"), &opts, &env(), &Version::new(0, 3, 0), 412_000)
    }

    fn value(actions: &[Action], key: &str, name: Option<&str>) -> Option<String> {
        actions.iter().find_map(|a| match a {
            Action::RegSetString { key: k, name: n, value } if k == key && n.as_deref() == name => Some(value.clone()),
            _ => None,
        })
    }

    #[test]
    fn the_install_plan_lists_the_shortcuts_and_values_of_the_spec() {
        let actions = make(&Job::Install, true, false);
        let shortcuts: Vec<_> =
            actions.iter().filter_map(|a| if let Action::Shortcut(x) = a { Some(x) } else { None }).collect();
        assert_eq!(shortcuts.len(), 2);
        assert_eq!(shortcuts[0].link, Path::new("/menu/Sequence Studio.lnk"));
        assert_eq!(shortcuts[1].link, Path::new("/desk/Sequence Studio.lnk"));
        assert_eq!(shortcuts[0].target, Path::new("/apps/Sequence Studio/SequenceStudio.exe"));
        assert_eq!(shortcuts[0].aumid, "SequenceStudio.App");
        assert_eq!(make(&Job::Install, false, false).iter().filter(|a| matches!(a, Action::Shortcut(_))).count(), 1);

        assert_eq!(value(&actions, SQPROJ_KEY, None).as_deref(), Some("SequenceStudio.Project"));
        assert_eq!(
            value(&actions, &format!(r"{CLASS_KEY}\shell\open\command"), None).as_deref(),
            Some("\"/apps/Sequence Studio/SequenceStudio.exe\" \"%1\"")
        );
        assert_eq!(
            value(&actions, &format!(r"{CLASS_KEY}\DefaultIcon"), None).as_deref(),
            Some("/apps/Sequence Studio/SequenceStudio.ico")
        );
        assert_eq!(value(&actions, AUMID_KEY, Some("DisplayName")).as_deref(), Some("Sequence Studio"));
        let u = |n| value(&actions, UNINSTALL_KEY, Some(n));
        assert_eq!(u("DisplayVersion").as_deref(), Some("0.3.0"));
        assert_eq!(u("Publisher").as_deref(), Some("Paul Herter"));
        assert_eq!(u("DisplayIcon").as_deref(), Some("/apps/Sequence Studio/SequenceStudio.exe,0"));
        assert_eq!(u("InstallLocation").as_deref(), Some("/apps/Sequence Studio"));
        assert_eq!(u("URLInfoAbout").as_deref(), Some("https://getsequencestudio.com"));
        assert_eq!(u("HelpLink").as_deref(), Some("https://github.com/paulherter/sequence-studio/issues"));
        assert_eq!(
            u("UninstallString").as_deref(),
            Some("\"/apps/Sequence Studio/Uninstall Sequence Studio.exe\" --uninstall")
        );
        assert_eq!(
            u("QuietUninstallString").as_deref(),
            Some("\"/apps/Sequence Studio/Uninstall Sequence Studio.exe\" --uninstall --quiet")
        );
        for (name, want) in [("EstimatedSize", 412_000), ("NoModify", 1), ("NoRepair", 1)] {
            assert!(actions.contains(&dword(UNINSTALL_KEY, name, want)), "{name}");
        }
        assert_eq!(actions.last(), Some(&Action::AssocChanged));
    }

    #[test]
    fn the_inverse_removes_only_what_the_plan_adds() {
        let actions = make(&Job::Install, true, false);
        let undo = inverse(&actions);
        assert!(undo.contains(&Action::RemoveFile(PathBuf::from("/menu/Sequence Studio.lnk"))));
        assert!(undo.contains(&Action::RemoveFile(PathBuf::from("/desk/Sequence Studio.lnk"))));
        assert!(undo.contains(&Action::RegDeleteKey(s(UNINSTALL_KEY))));
        assert!(undo.contains(&Action::RegDeleteKey(s(CLASS_KEY))));
        assert!(undo.contains(&Action::RegDeleteKey(s(AUMID_KEY))));
        assert!(undo.contains(&Action::RegDeleteValueIfEquals {
            key: s(SQPROJ_KEY),
            name: None,
            equals: s(PROJECT_CLASS)
        }));
        assert!(
            !undo.contains(&Action::RegDeleteKey(s(SQPROJ_KEY))),
            "the .sqproj key may hold other programs' values"
        );
        // Nothing but removals and the notification, and every key touched is one of ours.
        for a in &undo {
            match a {
                Action::RegDeleteKey(k)
                | Action::RegDeleteKeyIfEmpty(k)
                | Action::RegDeleteValueIfEquals { key: k, .. } => {
                    assert!(
                        k.starts_with("Software\\") && (k.contains("SequenceStudio") || k.ends_with(".sqproj")),
                        "{k}"
                    );
                }
                Action::RemoveFile(p) => assert!(p.to_string_lossy().ends_with("Sequence Studio.lnk")),
                Action::AssocChanged => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        let value_at = undo.iter().position(|a| matches!(a, Action::RegDeleteValueIfEquals { .. }));
        assert_eq!(
            value_at.and_then(|i| undo.get(i + 1)),
            Some(&Action::RegDeleteKeyIfEmpty(s(SQPROJ_KEY))),
            "the empty .sqproj key goes right after our value"
        );
        assert_eq!(undo.len(), 8, "2 links, 3 keys, the .sqproj value and its empty key, the notification");
    }

    #[test]
    fn the_uninstall_plan_removes_data_only_on_request_and_the_files_before_the_registry() {
        let keep = make(&Job::Uninstall, false, false);
        let all = make(&Job::Uninstall, false, true);
        assert!(!keep.contains(&Action::RemoveDirAll(PathBuf::from("/data/SequenceStudio"))));
        assert!(all.contains(&Action::RemoveDirAll(PathBuf::from("/data/SequenceStudio"))));
        assert!(all.contains(&Action::RemoveDirAll(PathBuf::from("/cache/SequenceStudio"))));
        assert_eq!(keep.first(), Some(&Action::RemoveDirAll(PathBuf::from("/apps/Sequence Studio"))));
        assert_eq!(
            all.iter().position(|a| *a == Action::RemoveDirAll(PathBuf::from("/apps/Sequence Studio"))),
            Some(2)
        );
        assert!(keep.contains(&Action::RemoveFile(PathBuf::from("/desk/Sequence Studio.lnk"))));
        assert!(make(&Job::LinuxAdd, false, false).is_empty());
    }
}
