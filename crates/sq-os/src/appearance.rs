//! Whether the system is set to a dark look (the "System" Appearance choice).
//!
//! shortcut: the answer comes from a short-lived system tool (`defaults` on the Mac, `reg` on Windows, `gdbus` or
//! `gsettings` on Linux) instead of a native API, so sq-os stays free of system bindings; upgrade to the native
//! calls (NSApp effectiveAppearance, the UISettings change event, a portal signal) when the app needs live following.

use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::Platform;

/// macOS: `defaults read -g AppleInterfaceStyle` prints `Dark` in dark mode and fails in light mode.
pub fn parse_mac(success: bool, stdout: &str) -> bool {
    success && stdout.trim().eq_ignore_ascii_case("dark")
}

/// Windows: `reg query ...\Personalize /v AppsUseLightTheme`; the value `0x0` means dark apps. `None` when unreadable.
pub fn parse_windows(stdout: &str) -> Option<bool> {
    let line = stdout.lines().find(|l| l.contains("AppsUseLightTheme"))?;
    let value = line.split_whitespace().last()?;
    let n = u32::from_str_radix(value.trim_start_matches("0x"), 16).ok()?;
    Some(n == 0)
}

/// Linux portal: `org.freedesktop.appearance color-scheme` is 0 (no preference), 1 (dark) or 2 (light); the answer prints
/// as `(<<uint32 1>>,)`. `None` when there is no number.
pub fn parse_portal(stdout: &str) -> Option<bool> {
    let n = stdout.split(|c: char| !c.is_ascii_digit()).rfind(|s| !s.is_empty())?;
    match n {
        "1" => Some(true),
        "2" | "0" => Some(false),
        _ => None,
    }
}

/// Linux GTK setting: `gsettings get org.gnome.desktop.interface color-scheme` prints `'prefer-dark'`, `'prefer-light'`
/// or `'default'`.
pub fn parse_gsettings(stdout: &str) -> bool {
    stdout.contains("dark")
}

fn run(program: &str, args: &[&str]) -> Option<(bool, String)> {
    let mut cmd = Command::new(program);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // no console window
    }
    let out = cmd.output().ok()?;
    Some((out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned()))
}

fn probe(platform: Platform) -> bool {
    match platform {
        Platform::Mac => {
            run("defaults", &["read", "-g", "AppleInterfaceStyle"]).is_some_and(|(ok, out)| parse_mac(ok, &out))
        }
        Platform::Windows => run(
            "reg",
            &["query", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "/v", "AppsUseLightTheme"],
        )
        .and_then(|(_, out)| parse_windows(&out))
        .unwrap_or(true),
        Platform::Linux => run(
            "gdbus",
            &[
                "call",
                "--session",
                "--dest",
                "org.freedesktop.portal.Desktop",
                "--object-path",
                "/org/freedesktop/portal/desktop",
                "--method",
                "org.freedesktop.portal.Settings.Read",
                "org.freedesktop.appearance",
                "color-scheme",
            ],
        )
        .filter(|(ok, _)| *ok)
        .and_then(|(_, out)| parse_portal(&out))
        .or_else(|| {
            run("gsettings", &["get", "org.gnome.desktop.interface", "color-scheme"])
                .filter(|(ok, _)| *ok)
                .map(|(_, out)| parse_gsettings(&out))
        })
        .unwrap_or(true),
    }
}

static CACHE: Mutex<Option<(Instant, bool)>> = Mutex::new(None);

/// True when the system is set to a dark look; dark when it cannot be read (the app's own default). The answer is kept
/// for two seconds so a redraw never starts a tool twice.
pub fn prefers_dark() -> bool {
    let Ok(mut cache) = CACHE.lock() else { return true };
    if let Some((at, dark)) = *cache
        && at.elapsed() < Duration::from_secs(2)
    {
        return dark;
    }
    let dark = probe(Platform::current());
    *cache = Some((Instant::now(), dark));
    dark
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_is_dark_only_when_the_style_key_says_dark() {
        assert!(parse_mac(true, "Dark\n"));
        assert!(!parse_mac(false, ""));
        assert!(!parse_mac(true, "Light"));
    }

    #[test]
    fn windows_reads_the_apps_use_light_theme_value() {
        let dark = "\nHKEY_CURRENT_USER\\...\\Personalize\n    AppsUseLightTheme    REG_DWORD    0x0\n\n";
        let light = dark.replace("0x0", "0x1");
        assert_eq!(parse_windows(dark), Some(true));
        assert_eq!(parse_windows(&light), Some(false));
        assert_eq!(parse_windows("ERROR: not found"), None);
    }

    #[test]
    fn linux_reads_the_portal_then_the_gtk_setting() {
        assert_eq!(parse_portal("(<<uint32 1>>,)\n"), Some(true));
        assert_eq!(parse_portal("(<<uint32 2>>,)"), Some(false));
        assert_eq!(parse_portal("(<<uint32 0>>,)"), Some(false));
        assert_eq!(parse_portal("no number"), None);
        assert!(parse_gsettings("'prefer-dark'\n"));
        assert!(!parse_gsettings("'default'"));
    }

    #[test]
    fn the_probe_answers_without_panicking() {
        let _ = prefers_dark();
        let _ = prefers_dark();
    }
}
