// Swift: ShellPlatformText.swift
//! Texts that name the platform the shared shell runs on and the key hints of the start screen, so the Mac shows "⌘N" and
//! "not in the shared UI yet" where Windows says "Ctrl+N".

use sq_os::Platform;
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::key_binding_text::KeyBindingText;

/// Platform dependent shell texts.
pub struct ShellPlatformText;

impl ShellPlatformText {
    /// `abbreviatingWithTildeInPath`: the home folder shown as "~" (Mac only; Windows paths stay whole).
    pub fn abbreviating_home(path: &str) -> String {
        if cfg!(target_os = "macos")
            && let Some(home) = std::env::var_os("HOME").and_then(|h| h.into_string().ok())
        {
            if path == home {
                return "~".to_string();
            }
            if let Some(rest) = path.strip_prefix(&format!("{home}/")) {
                return format!("~/{rest}");
            }
        }
        path.to_string()
    }

    /// A command or panel the shared UI does not have yet.
    pub fn not_available() -> &'static str {
        if Platform::current() == Platform::Windows {
            "Not available on Windows yet."
        } else {
            "Not available in the shared UI yet."
        }
    }

    /// The placeholder card's note.
    pub fn panel_missing() -> &'static str {
        if Platform::current() == Platform::Windows { "Not on Windows yet" } else { "Not in the shared UI yet" }
    }

    /// Preferences > Advanced, the Edit API help (two whole strings, so each has its own translation).
    pub fn edit_api_help() -> &'static str {
        if Platform::current() != Platform::Mac {
            "Only programs on this computer can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md."
        } else {
            "Only programs on this Mac can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md."
        }
    }

    /// Preferences > Cache, the Frame Cache help (whole strings per system, so each has its own translation).
    pub fn frame_cache_help(platform: Platform) -> &'static str {
        if platform == Platform::Mac {
            "Memory for decoded frames of both monitors (this Mac: %@ GB). More plays back smoother, less leaves room for other apps. Auto scales with your Mac and shrinks when memory runs low."
        } else {
            "Memory for decoded frames of both monitors (this PC: %@ GB). More plays back smoother, less leaves room for other apps. Auto scales with your PC and shrinks when memory runs low."
        }
    }

    /// The Command-key hint for `key` ("Ctrl+N" / "⌘N").
    pub fn command_key(key: char) -> String {
        KeyBindingText::text(&KeyBinding::new(Key::Char(key), KeyModifiers::COMMAND), Platform::current())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_key_names_the_command_modifier() {
        let t = ShellPlatformText::command_key('n');
        assert!(t.ends_with('N') || t.ends_with('n'), "{t}");
    }

    #[test]
    fn frame_cache_help_names_the_machine_per_platform() {
        assert!(ShellPlatformText::frame_cache_help(Platform::Mac).contains("this Mac: %@ GB"));
        for p in [Platform::Windows, Platform::Linux] {
            let t = ShellPlatformText::frame_cache_help(p);
            assert!(t.contains("this PC: %@ GB") && !t.contains("Mac"), "{t}");
        }
    }

    /// Settings > Playback rows sat 16 px lower on Linux because the longer "computer" wording wrapped one line more
    /// than the Mac text: every platform's help must wrap to the same number of lines, measured in the real font (Linux and Windows draw Inter, where "computer" wrapped one line more).
    #[test]
    fn frame_cache_help_wraps_like_the_mac_text() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let tm = sq_draw::TextMeasure::new(Some(&atlas), 1.0);
        let lines = |p| {
            tm.lines(
                &ShellPlatformText::frame_cache_help(p).replace("%@", "16"),
                348.0,
                sq_uikit::design_tokens::sq_tokens::type_size::BODY as f64,
            )
            .len()
        };
        for p in [Platform::Windows, Platform::Linux] {
            assert_eq!(lines(p), lines(Platform::Mac), "{p:?}");
        }
    }

    #[test]
    fn abbreviating_home_keeps_other_paths() {
        assert_eq!(ShellPlatformText::abbreviating_home("/definitely/not/home"), "/definitely/not/home");
    }
}
