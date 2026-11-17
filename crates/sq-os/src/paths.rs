//! How a file path is spelled where: stored in a project, shown to the user, handed to the system.
//!
//! One path has three spellings and each has one owner here:
//! - **stored** (`stored_form`): what a project file and the model keep. Plain and with `/`, so a project saved on Windows
//!   (`C:/Media/a.mp4`, `//server/share/a.mp4`) reads the same on every system.
//! - **shown** (`display_form`): what the user reads. The system's own spelling: `C:\Media\a.mp4` on Windows.
//! - **system** (`os_form`): what Win32 shell calls accept (`ShellExecute`, Explorer's `/select,`). Backslashes, and the
//!   `\\?\` prefix only where the path needs it (260 UTF-16 units or more).
//!
//! The verbatim prefix (`\\?\C:\a`, `\\?\UNC\server\share\a`) is none of these: `std::fs::canonicalize` returns it on
//! Windows, and the shell does not understand it (the project panel's "Show in Explorer" opened the Desktop and "Edit
//! Original" failed with ShellExecute 2). [`canonical`] is `canonicalize` without it; every spelling below drops it.
//! All functions work on the text, so a Windows path is read the same on a Mac or Linux host (a project round trip).

use crate::Platform;
use std::borrow::Cow;
use std::io;
use std::path::{Path, PathBuf};

/// Win32's `MAX_PATH`: a path of this many UTF-16 units (with the NUL) or more needs the verbatim prefix for APIs that do
/// not extend it themselves.
const MAX_PATH: usize = 260;

fn is_sep(c: char) -> bool {
    c == '/' || c == '\\'
}

fn is_drive(text: &str) -> bool {
    let mut chars = text.chars();
    matches!((chars.next(), chars.next(), chars.next()), (Some(d), Some(':'), Some(s)) if d.is_ascii_alphabetic() && is_sep(s))
}

/// The text after a `\\?\` or `//?/` prefix, when `text` has one.
fn after_verbatim(text: &str) -> Option<&str> {
    text.strip_prefix("\\\\?\\").or_else(|| text.strip_prefix("//?/"))
}

/// `text` without a verbatim prefix: `\\?\C:\a` becomes `C:\a`, `//?/C:/a` becomes `C:/a`, `\\?\UNC\srv\share\a`
/// becomes `\\srv\share\a`, `//?/UNC/srv/share/a` becomes `//srv/share/a`. Anything else (a plain path, a device path
/// such as `\\?\Volume{...}\a`, a POSIX path) stays as it is.
pub fn strip_verbatim(text: &str) -> Cow<'_, str> {
    let Some(rest) = after_verbatim(text) else { return Cow::Borrowed(text) };
    if is_drive(rest) {
        return Cow::Borrowed(rest);
    }
    let sep = if text.starts_with('/') { "//" } else { "\\\\" };
    match rest.as_bytes() {
        [u, n, c, s, ..] if b"unc".eq_ignore_ascii_case(&[*u, *n, *c]) && is_sep(char::from(*s)) => {
            Cow::Owned(format!("{sep}{}", &rest[4..]))
        }
        _ => Cow::Borrowed(text),
    }
}

/// True for the spellings of a Windows path: a drive path (`C:\a`, `C:/a`) or a share path with backslashes (`\\srv\a`).
/// A share written with slashes (`//srv/share/a`) is also one, but only [`Platform::Windows`] reads it so (on the others
/// `//x` is a POSIX path); the callers that know the system pass it.
fn is_windows_spelling(platform: Platform, text: &str) -> bool {
    if is_drive(text) || text.starts_with("\\\\") {
        return true;
    }
    platform == Platform::Windows && text.starts_with("//") && !text[2..].starts_with(is_sep) && text[2..].contains('/')
}

/// What a project stores for `text`: plain, and with `/` where it is a Windows path (a Mac or Linux path keeps a `\` in a
/// file name). Total: any text comes back, a non-path unchanged.
pub fn stored_form(text: &str) -> String {
    let plain = strip_verbatim(text);
    if is_drive(&plain) || plain.starts_with("\\\\") { plain.replace('\\', "/") } else { plain.into_owned() }
}

/// What the user reads on `platform`: plain, and with `\` where Windows writes a path (`C:\Media\a.mp4`,
/// `\\srv\share\a.mp4`). The other systems show a Windows path the way it is stored.
pub fn display_form(platform: Platform, text: &str) -> String {
    let plain = strip_verbatim(text);
    if platform == Platform::Windows && is_windows_spelling(platform, &plain) {
        plain.replace('/', "\\")
    } else {
        stored_form(&plain)
    }
}

/// What a Win32 shell call takes on `platform` for `text`: [`display_form`], plus the `\\?\` prefix (`\\?\UNC\` for a
/// share) when the path is `MAX_PATH` units or longer. Other systems get the text unchanged.
pub fn os_form(platform: Platform, text: &str) -> String {
    if platform != Platform::Windows {
        return text.to_string();
    }
    let plain = display_form(platform, text);
    let long = plain.encode_utf16().count() >= MAX_PATH;
    if !long {
        return plain;
    }
    if is_drive(&plain) {
        format!("\\\\?\\{plain}")
    } else if let Some(share) = plain.strip_prefix("\\\\").filter(|s| !s.starts_with(['?', '.'])) {
        format!("\\\\?\\UNC\\{share}")
    } else {
        plain
    }
}

/// [`stored_form`] of a path (lossy for a name that is not Unicode, like the project file itself).
pub fn stored(path: &Path) -> String {
    stored_form(&path.to_string_lossy())
}

/// The path as text without a verbatim prefix and otherwise as it is: what a list of recent files or a setting keeps, so
/// the entry still equals the path a file dialog hands back.
pub fn plain(path: &Path) -> String {
    strip_verbatim(&path.to_string_lossy()).into_owned()
}

/// [`display_form`] of a path on this system.
pub fn shown(path: &Path) -> String {
    display_form(Platform::current(), &path.to_string_lossy())
}

/// `path` as the user reads it on `platform` with the home folder written `~` (`~/Movies/a.mp4`, `~\Videos\a.mp4` on
/// Windows, which compares the folder names without case). Only a whole folder name counts, so `/Users/annax` is not
/// under `/Users/anna`. An empty `home` leaves the path whole. Text only: a Windows path reads the same on a Mac or Linux.
pub fn tilde(platform: Platform, path: &str, home: &str) -> String {
    let shown = display_form(platform, path);
    let home = display_form(platform, home);
    let home = home.trim_end_matches(is_sep);
    let (Some(head), Some(rest)) = (shown.get(..home.len()), shown.get(home.len()..)) else { return shown };
    let same = if platform == Platform::Windows { head.eq_ignore_ascii_case(home) } else { head == home };
    if home.is_empty() || !same || !(rest.is_empty() || rest.starts_with(is_sep)) {
        return shown;
    }
    format!("~{rest}")
}

/// [`tilde`] of a path on this system, the home folder from the environment ([`Platform::home_dir`]).
pub fn tilde_here(path: &Path) -> String {
    let platform = Platform::current();
    let home = platform.home_dir(|name| std::env::var_os(name)).unwrap_or_default();
    tilde(platform, &path.to_string_lossy(), &home.to_string_lossy())
}

/// The path a system call takes: [`os_form`] on Windows, the path itself elsewhere (a Linux name may be no Unicode).
pub fn for_os(path: &Path) -> PathBuf {
    if Platform::current() != Platform::Windows {
        return path.to_path_buf();
    }
    path.to_str().map_or_else(|| path.to_path_buf(), |text| PathBuf::from(os_form(Platform::Windows, text)))
}

/// `std::fs::canonicalize` for a path that is stored, compared or shown: the real path without the verbatim prefix
/// Windows adds. Only the prefix is dropped when the plain path still names the same file (a drive path or a share path;
/// a long path keeps the prefix, which it needs).
pub fn canonical(path: &Path) -> io::Result<PathBuf> {
    let real = std::fs::canonicalize(path)?;
    Ok(plain_path(real))
}

/// `real` without a verbatim prefix when it is short enough to work without it.
fn plain_path(real: PathBuf) -> PathBuf {
    let Some(text) = real.to_str() else { return real };
    let plain = strip_verbatim(text);
    if plain == text || plain.encode_utf16().count() >= MAX_PATH {
        return real;
    }
    PathBuf::from(plain.into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_home_folder_shows_as_a_tilde_on_every_system() {
        assert_eq!(tilde(Platform::Mac, "/Users/anna/Movies/a.mp4", "/Users/anna"), "~/Movies/a.mp4");
        assert_eq!(tilde(Platform::Mac, "/Users/anna", "/Users/anna/"), "~");
        assert_eq!(tilde(Platform::Linux, "/home/paul/Videos/a.mp4", "/home/paul"), "~/Videos/a.mp4");
        assert_eq!(tilde(Platform::Windows, "C:\\Users\\anna\\Videos\\a.mp4", "C:\\Users\\anna"), "~\\Videos\\a.mp4");
        assert_eq!(tilde(Platform::Windows, "c:/users/Anna/Videos/a.mp4", "C:\\Users\\anna"), "~\\Videos\\a.mp4");
    }

    #[test]
    fn a_path_outside_the_home_folder_or_a_folder_with_the_same_start_stays_whole() {
        assert_eq!(tilde(Platform::Mac, "/Users/annax/a.mp4", "/Users/anna"), "/Users/annax/a.mp4");
        assert_eq!(tilde(Platform::Mac, "/Volumes/Work/a.mp4", "/Users/anna"), "/Volumes/Work/a.mp4");
        assert_eq!(tilde(Platform::Mac, "/Users/anna/a.mp4", ""), "/Users/anna/a.mp4");
        assert_eq!(tilde(Platform::Mac, "/a.mp4", "/"), "/a.mp4");
    }

    #[test]
    fn a_verbatim_drive_path_loses_its_prefix_in_both_separator_styles() {
        assert_eq!(strip_verbatim("\\\\?\\C:\\sq\\a.mp4"), "C:\\sq\\a.mp4");
        assert_eq!(strip_verbatim("//?/C:/sq-w47-light/pl-4k-hevc.mp4"), "C:/sq-w47-light/pl-4k-hevc.mp4");
    }

    #[test]
    fn a_verbatim_share_path_becomes_a_plain_share_path() {
        assert_eq!(strip_verbatim("\\\\?\\UNC\\server\\share\\a.mp4"), "\\\\server\\share\\a.mp4");
        assert_eq!(strip_verbatim("//?/UNC/server/share/a.mp4"), "//server/share/a.mp4");
        assert_eq!(strip_verbatim("\\\\?\\unc\\server\\share"), "\\\\server\\share");
    }

    #[test]
    fn paths_that_are_not_verbatim_drives_stay_untouched() {
        for text in [
            "C:\\a.mp4",
            "/Users/anna/a.mp4",
            "\\\\server\\share\\a.mp4",
            "\\\\?\\Volume{1234}\\a.mp4",
            "\\\\.\\pipe\\x",
            "//?",
            "",
            "ü/日本",
        ] {
            assert_eq!(strip_verbatim(text), text, "{text}");
        }
    }

    #[test]
    fn a_project_stores_a_windows_path_plain_with_slashes() {
        assert_eq!(stored_form("\\\\?\\C:\\Media\\a.mp4"), "C:/Media/a.mp4");
        assert_eq!(stored_form("//?/C:/Media/a.mp4"), "C:/Media/a.mp4");
        assert_eq!(stored_form("C:\\Media\\a b.mp4"), "C:/Media/a b.mp4");
        assert_eq!(stored_form("\\\\server\\share\\a.mp4"), "//server/share/a.mp4");
        assert_eq!(stored_form("\\\\?\\UNC\\server\\share\\a.mp4"), "//server/share/a.mp4");
        assert_eq!(stored_form("//server/share/a.mp4"), "//server/share/a.mp4");
    }

    #[test]
    fn a_posix_path_keeps_its_backslashes() {
        assert_eq!(stored_form("/Users/anna/we\\ird.mp4"), "/Users/anna/we\\ird.mp4");
        assert_eq!(stored_form("relative\\name.mp4"), "relative\\name.mp4");
    }

    #[test]
    fn storing_twice_changes_nothing() {
        for text in ["//?/C:/a/b.mp4", "\\\\?\\UNC\\s\\sh\\a", "C:\\a", "/a/b", "//s/sh/a"] {
            let once = stored_form(text);
            assert_eq!(stored_form(&once), once, "{text}");
        }
    }

    #[test]
    fn windows_shows_the_explorer_spelling() {
        let show = |t: &str| display_form(Platform::Windows, t);
        assert_eq!(show("//?/C:/sq-w47-light/pl-4k-hevc.mp4"), "C:\\sq-w47-light\\pl-4k-hevc.mp4");
        assert_eq!(show("C:/Media/a.mp4"), "C:\\Media\\a.mp4");
        assert_eq!(show("//server/share/a.mp4"), "\\\\server\\share\\a.mp4");
        assert_eq!(show("\\\\?\\UNC\\server\\share\\a.mp4"), "\\\\server\\share\\a.mp4");
        assert_eq!(show("\\\\server\\share\\a.mp4"), "\\\\server\\share\\a.mp4");
    }

    #[test]
    fn the_other_systems_show_a_path_as_stored() {
        for platform in [Platform::Mac, Platform::Linux] {
            assert_eq!(display_form(platform, "C:\\Media\\a.mp4"), "C:/Media/a.mp4");
            assert_eq!(display_form(platform, "//?/C:/Media/a.mp4"), "C:/Media/a.mp4");
            assert_eq!(display_form(platform, "/Users/anna/a.mp4"), "/Users/anna/a.mp4");
            // On these systems `//x/y` is a POSIX path, not a share.
            assert_eq!(display_form(platform, "//x/y/a.mp4"), "//x/y/a.mp4");
        }
    }

    #[test]
    fn a_posix_path_is_never_rewritten_on_windows() {
        assert_eq!(display_form(Platform::Windows, "/Users/anna/a.mp4"), "/Users/anna/a.mp4");
        assert_eq!(os_form(Platform::Windows, "/Users/anna/a.mp4"), "/Users/anna/a.mp4");
    }

    #[test]
    fn the_system_gets_backslashes_and_no_prefix_for_a_short_path() {
        assert_eq!(
            os_form(Platform::Windows, "//?/C:/sq-w47-light/pl-4k-hevc.mp4"),
            "C:\\sq-w47-light\\pl-4k-hevc.mp4"
        );
        assert_eq!(os_form(Platform::Windows, "//server/share/a.mp4"), "\\\\server\\share\\a.mp4");
    }

    #[test]
    fn a_long_path_gets_the_verbatim_prefix_it_needs() {
        let folder = "d".repeat(60);
        let long = format!("C:/{folder}/{folder}/{folder}/{folder}/{folder}/clip.mp4");
        let win = long.replace('/', "\\");
        assert!(win.len() >= MAX_PATH);
        assert_eq!(os_form(Platform::Windows, &long), format!("\\\\?\\{win}"));
        // An already verbatim spelling does not get a second prefix.
        assert_eq!(os_form(Platform::Windows, &format!("//?/{long}")), format!("\\\\?\\{win}"));
        let share = format!("//server/share/{folder}/{folder}/{folder}/{folder}/{folder}/clip.mp4");
        let share_win = share.replace('/', "\\");
        assert_eq!(os_form(Platform::Windows, &share), format!("\\\\?\\UNC\\{}", &share_win[2..]));
        // It is the stored form again after the round trip.
        assert_eq!(stored_form(&os_form(Platform::Windows, &long)), long);
        assert_eq!(stored_form(&os_form(Platform::Windows, &share)), share);
    }

    #[test]
    fn a_path_just_under_the_limit_stays_plain() {
        let text = format!("C:\\{}", "a".repeat(MAX_PATH - 1 - "C:\\".len()));
        assert_eq!(text.len(), MAX_PATH - 1);
        assert_eq!(os_form(Platform::Windows, &text), text);
        let at_limit = format!("{text}b");
        assert_eq!(os_form(Platform::Windows, &at_limit), format!("\\\\?\\{at_limit}"));
    }

    #[test]
    fn the_other_systems_hand_the_text_to_the_system_unchanged() {
        for platform in [Platform::Mac, Platform::Linux] {
            assert_eq!(os_form(platform, "/Users/anna/a b.mp4"), "/Users/anna/a b.mp4");
        }
    }

    #[test]
    fn an_old_project_path_survives_the_round_trip_between_systems() {
        // Saved by a build that canonicalized on Windows, then opened on a Mac, saved there and opened on Windows again.
        let old = "//?/C:/sq-w47-light/pl-4k-hevc.mp4";
        let on_mac = stored_form(old);
        assert_eq!(on_mac, "C:/sq-w47-light/pl-4k-hevc.mp4");
        assert_eq!(display_form(Platform::Mac, &on_mac), "C:/sq-w47-light/pl-4k-hevc.mp4");
        assert_eq!(display_form(Platform::Windows, &on_mac), "C:\\sq-w47-light\\pl-4k-hevc.mp4");
        assert_eq!(os_form(Platform::Windows, &on_mac), "C:\\sq-w47-light\\pl-4k-hevc.mp4");
    }

    #[test]
    fn canonical_gives_the_real_path_and_never_a_verbatim_one() -> io::Result<()> {
        let dir = std::env::temp_dir().join(format!("sq-os-paths-{}", std::process::id()));
        std::fs::create_dir_all(&dir)?;
        let file = dir.join("a.mp4");
        std::fs::write(&file, b"x")?;
        let real = canonical(&file)?;
        let text = real.to_string_lossy().into_owned();
        assert!(!text.starts_with("\\\\?\\") && !text.starts_with("//?/"), "{text}");
        assert!(real.is_file());
        assert!(canonical(&dir.join("missing.mp4")).is_err());
        std::fs::remove_dir_all(&dir)
    }

    #[test]
    fn shown_and_for_os_follow_the_current_system() {
        Platform::with_override(Platform::Windows, || {
            assert_eq!(shown(Path::new("//?/C:/a/b.mp4")), "C:\\a\\b.mp4");
            assert_eq!(for_os(Path::new("//?/C:/a/b.mp4")), PathBuf::from("C:\\a\\b.mp4"));
        });
        Platform::with_override(Platform::Mac, || {
            assert_eq!(shown(Path::new("//?/C:/a/b.mp4")), "C:/a/b.mp4");
            assert_eq!(for_os(Path::new("/Users/p/b.mp4")), PathBuf::from("/Users/p/b.mp4"));
        });
    }
}
