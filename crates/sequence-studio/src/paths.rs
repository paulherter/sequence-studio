//! Where the app keeps its per-user state (dock layout, recent projects, presets).

use sq_os::Platform;
use std::ffi::OsString;
use std::path::PathBuf;

/// The support folder of `platform` from its environment values (`Platform::data_dir` plus "Sequence Studio"); `None`
/// when none of them is set.
pub fn support_dir_from(platform: Platform, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    Some(platform.data_dir(env)?.join("Sequence Studio"))
}

/// The app support folder of this machine; `SQ_SUPPORT_DIR` overrides it (tests and portable runs); falls back to the
/// temp folder when the environment names no home. A test build refuses the real folder: set `SQ_SUPPORT_DIR` first, so
/// no test reads or writes the user's presets, prefs or recents.
pub fn app_support_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("SQ_SUPPORT_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    #[cfg(test)]
    panic!("a test resolved the real support folder: set SQ_SUPPORT_DIR to a unique temp folder first");
    #[cfg(not(test))]
    support_dir_from(Platform::current(), |k| std::env::var_os(k))
        .unwrap_or_else(|| std::env::temp_dir().join("sequence-studio"))
}

/// The folder of the app log. macOS: `~/Library/Logs/Sequence Studio` like the Swift app (`SQLog.directory`); elsewhere, and
/// whenever `SQ_SUPPORT_DIR` is set, `Logs` inside the support folder.
pub fn log_dir_from(support: &std::path::Path, platform: Platform, env: impl Fn(&str) -> Option<OsString>) -> PathBuf {
    let own_support = env("SQ_SUPPORT_DIR").is_some_and(|d| !d.is_empty());
    match env("HOME") {
        Some(home) if platform == Platform::Mac && !own_support => {
            PathBuf::from(home).join("Library").join("Logs").join("Sequence Studio")
        }
        _ => support.join("Logs"),
    }
}

/// The app log folder of this machine for `support` (see [`log_dir_from`]).
pub fn log_dir(support: &std::path::Path) -> PathBuf {
    log_dir_from(support, Platform::current(), |k| std::env::var_os(k))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| OsString::from(*v))
    }

    #[test]
    fn each_system_has_its_folder() {
        let home = env(&[("HOME", "/u"), ("APPDATA", "C:/a")]);
        assert_eq!(
            support_dir_from(Platform::Mac, &home),
            Some("/u/Library/Application Support/Sequence Studio".into())
        );
        assert_eq!(support_dir_from(Platform::Windows, &home), Some("C:/a/Sequence Studio".into()));
        assert_eq!(support_dir_from(Platform::Linux, &home), Some("/u/.local/share/Sequence Studio".into()));
        assert_eq!(support_dir_from(Platform::Mac, env(&[])), None);
    }

    #[test]
    fn the_mac_log_sits_in_library_logs_like_the_swift_app() {
        let s = std::path::Path::new("/u/Library/Application Support/Sequence Studio");
        assert_eq!(
            log_dir_from(s, Platform::Mac, env(&[("HOME", "/u")])),
            PathBuf::from("/u/Library/Logs/Sequence Studio")
        );
        assert_eq!(log_dir_from(s, Platform::Mac, env(&[("HOME", "/u"), ("SQ_SUPPORT_DIR", "/t")])), s.join("Logs"));
        assert_eq!(log_dir_from(s, Platform::Linux, env(&[("HOME", "/u")])), s.join("Logs"));
        assert_eq!(log_dir_from(s, Platform::Windows, env(&[("HOME", "/u")])), s.join("Logs"));
    }
}
