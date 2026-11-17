// Swift: Localization.swift (`SQL10n.currentLanguage`: the system preference list plus the `sq.language` override)
//! The interface language of this run, chosen once at launch: `sq.language` in `prefs.json` ("system", "en", "de"), else
//! the system's preferred languages. Without this the catalogs never load and the app stays English.

use sq_uikit::localization::{SQL10n, selected_language};
use std::path::Path;

/// The `sq.language` string stored in `prefs.json` under `support`.
fn stored_language(support: &Path) -> Option<String> {
    let bytes = std::fs::read(support.join("prefs.json")).ok()?;
    let v: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    v["strings"][sq_uikit::localization::DEFAULTS_KEY].as_str().map(str::to_string)
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
/// `AppleLanguages` as `defaults read -g AppleLanguages` prints it: `("de-DE", "en-DE")` over several lines.
pub(crate) fn parse_apple_languages(text: &str) -> Vec<String> {
    text.lines()
        .map(|l| l.trim().trim_matches(|c| c == ',' || c == '(' || c == ')').trim_matches('"').to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

/// The system's preferred languages, most wanted first.
fn preferred_languages() -> Vec<String> {
    #[cfg(windows)]
    return sq_platform_win::preferred_languages();
    #[cfg(target_os = "macos")]
    return std::process::Command::new("defaults")
        .args(["read", "-g", "AppleLanguages"])
        .output()
        .map(|o| parse_apple_languages(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default();
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        ["LC_ALL", "LC_MESSAGES", "LANG"].iter().filter_map(|k| std::env::var(k).ok()).collect()
    }
}

/// Installs the catalogs for this run's language; call before any UI text is made.
pub fn install(support: &Path) {
    // A `--ui-shot` run is a script run even from the packaged binary: SQ_LANGUAGE counts there.
    let shot = std::env::args().any(|a| a == "--ui-shot");
    let bundle = !shot && std::env::current_exe().is_ok_and(|p| p.to_string_lossy().contains(".app/Contents/"));
    let env = std::env::var("SQ_LANGUAGE").ok();
    let stored = stored_language(support);
    let preferred = preferred_languages();
    let preferred: Vec<&str> = preferred.iter().map(String::as_str).collect();
    SQL10n::install(&selected_language(env.as_deref(), stored.as_deref(), bundle, &preferred));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apple_languages_list_is_read_in_order() {
        let text = "(\n    \"de-DE\",\n    \"en-DE\"\n)\n";
        assert_eq!(parse_apple_languages(text), vec!["de-DE".to_string(), "en-DE".to_string()]);
    }

    #[test]
    fn the_app_is_english_whatever_the_system_or_a_stored_choice_say() {
        assert_eq!(selected_language(None, Some("en"), true, &["de-DE"]), "en");
        assert_eq!(selected_language(None, Some("system"), true, &["de-DE"]), "en");
        assert_eq!(selected_language(None, Some("de"), true, &["de-DE"]), "en");
        assert_eq!(selected_language(Some("de"), None, false, &["de-DE"]), "en");
        assert_eq!(selected_language(None, None, true, &["fr-FR"]), "en");
    }

    #[test]
    fn the_stored_language_is_read_from_prefs_json_at_start() {
        let dir = std::env::temp_dir().join(format!("sq-lang-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        assert_eq!(stored_language(&dir), None, "no file: follow the system");
        std::fs::write(dir.join("prefs.json"), r#"{"strings":{"sq.language":"de"}}"#).expect("write");
        let stored = stored_language(&dir);
        assert_eq!(stored.as_deref(), Some("de"));
        // the stored choice still resolves (German returns when ENGLISH_ONLY is turned off), the app ignores it for now
        assert_eq!(sq_uikit::localization::resolve_language(stored.as_deref(), &["en-US"]), "de");
        assert_eq!(selected_language(None, stored.as_deref(), true, &["en-US"]), "en");
    }
}
