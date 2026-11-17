//! The system the app runs on and what differs between systems, as pure values (see README).

pub mod app_folders;
pub mod appearance;
pub mod keyboard;
pub mod paths;

use std::ffi::OsString;
use std::path::PathBuf;

/// The systems the app knows. Linux is a build and test host that behaves like Windows for keys and menus (Ctrl is the
/// Command key) and follows the XDG folder rules.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Platform {
    Mac,
    Windows,
    Linux,
}

/// How a shortcut is written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyTextStyle {
    /// "⇧⌘K".
    Symbols,
    /// "Ctrl+Shift+K".
    Words,
}

/// The installer file a release carries for a system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpdateAsset {
    Dmg,
    Exe,
    AppImage,
}

impl UpdateAsset {
    /// The file name ending, lowercase except the AppImage convention.
    pub fn suffix(self) -> &'static str {
        match self {
            UpdateAsset::Dmg => ".dmg",
            UpdateAsset::Exe => ".exe",
            UpdateAsset::AppImage => ".AppImage",
        }
    }
}

/// A set environment variable that is not empty (an empty one counts as unset, like the XDG rules say).
fn var(env: &impl Fn(&str) -> Option<OsString>, name: &str) -> Option<PathBuf> {
    env(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

thread_local! {
    static PLATFORM_OVERRIDE: std::cell::Cell<Option<Platform>> = const { std::cell::Cell::new(None) };
}

impl Platform {
    /// The system this build runs on. The only `cfg(target_os)` that decides "which system".
    pub fn current() -> Platform {
        PLATFORM_OVERRIDE.with(|o| o.get()).unwrap_or(Platform::native())
    }

    /// Runs `f` with [`Platform::current`] answering `p` on this thread (layout tests of the three systems' texts).
    pub fn with_override<R>(p: Platform, f: impl FnOnce() -> R) -> R {
        let before = PLATFORM_OVERRIDE.with(|o| o.replace(Some(p)));
        let out = f();
        PLATFORM_OVERRIDE.with(|o| o.set(before));
        out
    }

    /// The system this build is made for (const; [`Platform::current`] adds the test override).
    pub const fn native() -> Platform {
        if cfg!(target_os = "macos") {
            Platform::Mac
        } else if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Linux
        }
    }

    /// The Command key as a shortcut shows it: "⌘" on the Mac, "Ctrl" elsewhere.
    pub fn command_symbol(self) -> &'static str {
        match self {
            Platform::Mac => "⌘",
            Platform::Windows | Platform::Linux => "Ctrl",
        }
    }

    /// The Command key as prose names it: "Cmd" on the Mac, "Ctrl" elsewhere.
    pub fn command_name(self) -> &'static str {
        match self {
            Platform::Mac => "Cmd",
            Platform::Windows | Platform::Linux => "Ctrl",
        }
    }

    /// The Option key as prose names it.
    pub fn option_name(self) -> &'static str {
        match self {
            Platform::Mac => "Opt",
            Platform::Windows | Platform::Linux => "Alt",
        }
    }

    /// Symbols on the Mac, words elsewhere.
    pub fn key_text_style(self) -> KeyTextStyle {
        match self {
            Platform::Mac => KeyTextStyle::Symbols,
            Platform::Windows | Platform::Linux => KeyTextStyle::Words,
        }
    }

    /// Whether the Command modifier of a shortcut is the Cmd (Super) key. Elsewhere it is Ctrl and Super is ignored.
    pub fn command_is_cmd_key(self) -> bool {
        self == Platform::Mac
    }

    /// The name of the Command modifier in prose ("Cmd" on the Mac, "Ctrl" elsewhere).
    pub fn command_key_name(self) -> &'static str {
        if self.command_is_cmd_key() { "Cmd" } else { "Ctrl" }
    }

    /// The name of the Option modifier in prose ("Option" on the Mac, "Alt" elsewhere).
    pub fn option_key_name(self) -> &'static str {
        if self == Platform::Mac { "Option" } else { "Alt" }
    }

    /// Whether the file dialog shows a `.sqproj` package folder as one file it can pick. The others cannot pick a
    /// folder with a file dialog, so the app also offers the `project.json` inside it.
    pub fn dialog_picks_packages(self) -> bool {
        self == Platform::Mac
    }

    /// Whether a new project is one plain file instead of a package folder (Windows).
    pub const fn new_projects_are_files(self) -> bool {
        matches!(self, Platform::Windows)
    }

    /// Whether the system draws the menu bar at the top of the screen (the others get it inside the window).
    pub fn has_native_menu_bar(self) -> bool {
        self == Platform::Mac
    }

    /// Whether the app menu and the window menu carry the Mac rows Hide, Hide Others, Show All, Zoom and Bring All to
    /// Front. The others show Exit and Maximize and no such rows.
    pub fn has_mac_window_rows(self) -> bool {
        self == Platform::Mac
    }

    /// The program that shows a file: Finder, Explorer, or the default file manager.
    pub fn file_manager_name(self) -> &'static str {
        match self {
            Platform::Mac => "Finder",
            Platform::Windows => "Explorer",
            Platform::Linux => "Files",
        }
    }

    /// The menu title of the command that shows a file in the file manager.
    pub fn reveal_title(self) -> &'static str {
        match self {
            Platform::Mac => "Reveal in Finder",
            Platform::Windows => "Show in Explorer",
            Platform::Linux => "Show in File Manager",
        }
    }

    /// The release file of this system.
    pub fn update_asset(self) -> UpdateAsset {
        match self {
            Platform::Mac => UpdateAsset::Dmg,
            Platform::Windows => UpdateAsset::Exe,
            Platform::Linux => UpdateAsset::AppImage,
        }
    }

    /// The system name in a feedback mail.
    pub fn feedback_os_name(self) -> &'static str {
        match self {
            Platform::Mac => "macOS",
            Platform::Windows => "Windows",
            Platform::Linux => "Linux",
        }
    }

    /// The user's home folder; `None` when the environment names none.
    pub fn home_dir(self, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
        var(&env, if self == Platform::Windows { "USERPROFILE" } else { "HOME" })
    }

    /// The folder name of the user's videos: `Movies` on the Mac, `Videos` elsewhere.
    pub fn movies_folder_name(self) -> &'static str {
        if self == Platform::Mac { "Movies" } else { "Videos" }
    }

    /// The default movies folder, `~/Movies` or `~/Videos`.
    pub fn movies_dir(self, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
        Some(self.home_dir(env)?.join(self.movies_folder_name()))
    }

    /// Per-user caches: `~/Library/Caches`, `%LOCALAPPDATA%`, `$XDG_CACHE_HOME` or `~/.cache`.
    pub fn cache_dir(self, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
        match self {
            Platform::Mac => Some(var(&env, "HOME")?.join("Library/Caches")),
            Platform::Windows => var(&env, "LOCALAPPDATA"),
            Platform::Linux => var(&env, "XDG_CACHE_HOME").or_else(|| Some(var(&env, "HOME")?.join(".cache"))),
        }
    }

    /// Per-user data (presets, recents): `~/Library/Application Support`, `%APPDATA%`, `$XDG_DATA_HOME` or
    /// `~/.local/share`.
    pub fn data_dir(self, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
        match self {
            Platform::Mac => Some(var(&env, "HOME")?.join("Library/Application Support")),
            Platform::Windows => var(&env, "APPDATA"),
            Platform::Linux => var(&env, "XDG_DATA_HOME").or_else(|| Some(var(&env, "HOME")?.join(".local/share"))),
        }
    }

    /// Per-user settings: like `data_dir` on the Mac and Windows, `$XDG_CONFIG_HOME` or `~/.config` on Linux.
    pub fn config_dir(self, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
        match self {
            Platform::Linux => var(&env, "XDG_CONFIG_HOME").or_else(|| Some(var(&env, "HOME")?.join(".config"))),
            Platform::Mac | Platform::Windows => self.data_dir(env),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Platform; 3] = [Platform::Mac, Platform::Windows, Platform::Linux];

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| OsString::from(*v))
    }

    fn texts(f: impl Fn(Platform) -> &'static str) -> [&'static str; 3] {
        ALL.map(f)
    }

    #[test]
    fn command_key_names() {
        assert_eq!(texts(Platform::command_symbol), ["⌘", "Ctrl", "Ctrl"]);
        assert_eq!(texts(Platform::command_name), ["Cmd", "Ctrl", "Ctrl"]);
        assert_eq!(texts(Platform::option_name), ["Opt", "Alt", "Alt"]);
    }

    #[test]
    fn key_text_style_per_system() {
        assert_eq!(
            ALL.map(Platform::key_text_style),
            [KeyTextStyle::Symbols, KeyTextStyle::Words, KeyTextStyle::Words]
        );
    }

    #[test]
    fn only_the_mac_has_a_system_menu_bar_and_mac_window_rows() {
        assert_eq!(ALL.map(Platform::has_native_menu_bar), [true, false, false]);
        assert_eq!(ALL.map(Platform::has_mac_window_rows), [true, false, false]);
    }

    #[test]
    fn modifier_names_in_prose() {
        assert_eq!(ALL.map(Platform::command_key_name), ["Cmd", "Ctrl", "Ctrl"]);
        assert_eq!(ALL.map(Platform::option_key_name), ["Option", "Alt", "Alt"]);
    }

    #[test]
    fn command_key_and_project_file_rules() {
        assert_eq!(ALL.map(Platform::command_is_cmd_key), [true, false, false]);
        assert_eq!(ALL.map(Platform::dialog_picks_packages), [true, false, false]);
        assert_eq!(ALL.map(Platform::new_projects_are_files), [false, true, false]);
    }

    #[test]
    fn file_manager_names() {
        assert_eq!(texts(Platform::file_manager_name), ["Finder", "Explorer", "Files"]);
        assert_eq!(texts(Platform::reveal_title), ["Reveal in Finder", "Show in Explorer", "Show in File Manager"]);
    }

    #[test]
    fn update_asset_per_system() {
        assert_eq!(ALL.map(Platform::update_asset), [UpdateAsset::Dmg, UpdateAsset::Exe, UpdateAsset::AppImage]);
        assert_eq!(ALL.map(|p| p.update_asset().suffix()), [".dmg", ".exe", ".AppImage"]);
    }

    #[test]
    fn feedback_names() {
        assert_eq!(texts(Platform::feedback_os_name), ["macOS", "Windows", "Linux"]);
    }

    #[test]
    fn home_and_movies_folders() {
        let e = env(&[("HOME", "/u"), ("USERPROFILE", "C:/u")]);
        assert_eq!(Platform::Mac.home_dir(&e), Some("/u".into()));
        assert_eq!(Platform::Windows.home_dir(&e), Some("C:/u".into()));
        assert_eq!(Platform::Linux.home_dir(&e), Some("/u".into()));
        assert_eq!(Platform::Mac.movies_dir(&e), Some("/u/Movies".into()));
        assert_eq!(Platform::Windows.movies_dir(&e), Some("C:/u/Videos".into()));
        assert_eq!(Platform::Linux.movies_dir(&e), Some("/u/Videos".into()));
        for p in ALL {
            assert_eq!(p.movies_dir(env(&[])), None);
        }
    }

    #[test]
    fn cache_folders() {
        let e = env(&[("HOME", "/u"), ("LOCALAPPDATA", "C:/l"), ("XDG_CACHE_HOME", "/x/cache")]);
        assert_eq!(Platform::Mac.cache_dir(&e), Some("/u/Library/Caches".into()));
        assert_eq!(Platform::Windows.cache_dir(&e), Some("C:/l".into()));
        assert_eq!(Platform::Linux.cache_dir(&e), Some("/x/cache".into()));
        let no_xdg = env(&[("HOME", "/u"), ("XDG_CACHE_HOME", "")]);
        assert_eq!(Platform::Linux.cache_dir(&no_xdg), Some("/u/.cache".into()));
        for p in ALL {
            assert_eq!(p.cache_dir(env(&[])), None);
        }
    }

    #[test]
    fn data_folders() {
        let e = env(&[("HOME", "/u"), ("APPDATA", "C:/a"), ("XDG_DATA_HOME", "/x/data")]);
        assert_eq!(Platform::Mac.data_dir(&e), Some("/u/Library/Application Support".into()));
        assert_eq!(Platform::Windows.data_dir(&e), Some("C:/a".into()));
        assert_eq!(Platform::Linux.data_dir(&e), Some("/x/data".into()));
        assert_eq!(Platform::Linux.data_dir(env(&[("HOME", "/u")])), Some("/u/.local/share".into()));
        for p in ALL {
            assert_eq!(p.data_dir(env(&[])), None);
        }
    }

    #[test]
    fn config_folders() {
        let e = env(&[("HOME", "/u"), ("APPDATA", "C:/a"), ("XDG_CONFIG_HOME", "/x/conf")]);
        assert_eq!(Platform::Mac.config_dir(&e), Some("/u/Library/Application Support".into()));
        assert_eq!(Platform::Windows.config_dir(&e), Some("C:/a".into()));
        assert_eq!(Platform::Linux.config_dir(&e), Some("/x/conf".into()));
        assert_eq!(Platform::Linux.config_dir(env(&[("HOME", "/u")])), Some("/u/.config".into()));
    }

    #[test]
    fn current_is_one_of_the_three_and_stable() {
        assert!(ALL.contains(&Platform::current()));
    }
}
