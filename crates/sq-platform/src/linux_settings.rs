//! What the Linux desktop says about the keyboard layout and animations. There is no single API: GNOME keeps it in
//! gsettings, KDE in its config files, any X11 or XWayland session in `setxkbmap`; each is asked in turn and the answers
//! are parsed by pure functions (tested on any host).
//! The first layout of the list counts (the one switched to last is not asked); xkbcommon state through winit would show
//! a layout switch at once.

use sq_os::keyboard::ActiveKeyboard;
use std::process::Command;

fn run(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `[('xkb', 'de+nodeadkeys'), ('xkb', 'us')]`: the first keyboard layout.
pub fn parse_gsettings_sources(text: &str) -> Option<String> {
    let rest = text.split("'xkb',").nth(1)?;
    let id = rest.split('\'').nth(1)?;
    (!id.is_empty()).then(|| id.to_string())
}

/// `layout:     de,us` from `setxkbmap -query`, or `X11 Layout: de` from `localectl status`.
pub fn parse_layout_line(text: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let (key, value) = l.split_once(':')?;
        let key = key.trim();
        if key != "layout" && key != "X11 Layout" {
            return None;
        }
        let first = value.trim().split(',').next()?.trim();
        (!first.is_empty() && first != "n/a").then(|| first.to_string())
    })
}

/// `de,us`: the first of a comma list (KDE's `LayoutList`, `XKB_DEFAULT_LAYOUT`).
pub fn parse_list(text: &str) -> Option<String> {
    let first = text.trim().split(',').next()?.trim();
    (!first.is_empty()).then(|| first.to_string())
}

/// The layout the user types with, asked of the desktop.
pub fn active_keyboard() -> Option<ActiveKeyboard> {
    let id = std::env::var("XKB_DEFAULT_LAYOUT")
        .ok()
        .and_then(|v| parse_list(&v))
        .or_else(|| {
            run("gsettings", &["get", "org.gnome.desktop.input-sources", "sources"])
                .and_then(|t| parse_gsettings_sources(&t))
        })
        .or_else(|| {
            run("kreadconfig6", &["--file", "kxkbrc", "--group", "Layout", "--key", "LayoutList"])
                .and_then(|t| parse_list(&t))
        })
        .or_else(|| run("setxkbmap", &["-query"]).and_then(|t| parse_layout_line(&t)))
        .or_else(|| run("localectl", &["status"]).and_then(|t| parse_layout_line(&t)))?;
    Some(ActiveKeyboard::from_id(&id))
}

/// `false` from gsettings' `enable-animations`, or KDE's animation speed set to instant (factor 0).
pub fn animations_off(gsettings: Option<&str>, kde_factor: Option<&str>) -> bool {
    gsettings.is_some_and(|t| t.trim() == "false")
        || kde_factor.is_some_and(|t| t.trim().parse::<f64>().is_ok_and(|f| f <= 0.0))
}

/// True when the desktop turned animations off (Reduce motion).
pub fn reduce_motion() -> bool {
    let g = run("gsettings", &["get", "org.gnome.desktop.interface", "enable-animations"]);
    let k = run("kreadconfig6", &["--file", "kdeglobals", "--group", "KDE", "--key", "AnimationDurationFactor"]);
    animations_off(g.as_deref(), k.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gsettings_sources_give_the_first_layout() {
        assert_eq!(
            parse_gsettings_sources("[('xkb', 'de+nodeadkeys'), ('xkb', 'us')]\n").as_deref(),
            Some("de+nodeadkeys")
        );
        assert_eq!(parse_gsettings_sources("@a(ss) []"), None);
    }

    #[test]
    fn setxkbmap_and_localectl_lines_give_the_first_layout() {
        assert_eq!(parse_layout_line("rules:      evdev\nlayout:     de,us\n").as_deref(), Some("de"));
        assert_eq!(parse_layout_line("   System Locale: LANG=en_US\n       X11 Layout: fr\n").as_deref(), Some("fr"));
        assert_eq!(parse_layout_line("X11 Layout: n/a"), None);
        assert_eq!(parse_list("ch,us\n").as_deref(), Some("ch"));
        assert_eq!(parse_list(""), None);
    }

    #[test]
    fn linux_reduce_motion_follows_gnome_and_kde() {
        assert!(animations_off(Some("false\n"), None));
        assert!(!animations_off(Some("true\n"), None));
        assert!(animations_off(None, Some("0\n")));
        assert!(!animations_off(None, Some("1\n")));
        assert!(!animations_off(None, None));
    }

    #[test]
    fn a_swiss_layout_draws_the_german_picture() {
        assert!(ActiveKeyboard::from_id("ch").is_german());
    }
}
