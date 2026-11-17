//! A cheap permanent check that no label the user reads is an internal name: a bare ISO or file-type code, a snake_case
//! key, or Rust Debug output (`Some(..)`, `Variant { .. }`, `path::Name`). Every visible string table runs through
//! [`internal_name`] in a test, so one that slips in fails the build instead of reaching a user. [`visible_problem`] is the
//! stricter check for text that is shown as it is (menu rows, command titles): it looks at every word, not only the whole label.

/// Short upper-case words that are real labels (formats, units, standards), not codes that stand for a name.
const ACRONYMS: &[&str] = &[
    "OK", "SFX", "PNG", "JPG", "GIF", "RGB", "FPS", "HDR", "SDR", "LUT", "AAC", "MP3", "MP4", "MOV", "MXF", "WAV",
    "EDL", "XML", "CPU", "GPU", "RAM", "USB", "DNG", "RAW", "EXR", "VFR", "CFR", "LOG", "RAD", "AIF", "FLAC", "SRT",
    "ASS", "PGS", "LUFS", "LRA", "BPM", "API", "URL", "PDF", "ISO", "GOP", "AV1", "ACES", "DCI", "SSD", "HDD", "VST",
    "AU", "UI", "ID", "OS", "TV", "PC", "AM", "PM", "UTC", "JSON", "DB", "MB", "GB", "KB", "TB", "HZ", "KHZ", "TC",
    "NTSC", "PAL", "HD", "UHD", "SD", "FX", "VR", "AR", "AI", "DV", "RED", "ND", "NR",
    // Audio and color terms that are the name of the thing (an equalizer, a color model, a level unit, a transfer curve).
    "EQ", "HSL", "HSV", "XYZ", "CMYK", "LFO", "ADSR", "VU", "HLG", "PQ",
    // Text file formats of the export and import rows.
    "CSV", "TXT", "VTT",
];

/// Names that start in lower case on purpose (units, product spellings), so they are not identifiers.
const LOWER_CAMEL_OK: &[&str] =
    &["dB", "kHz", "iPhone", "iPad", "iOS", "macOS", "tvOS", "iCloud", "mAh", "fps", "dBFS", "dBTP"];

/// German words that must not be left in the English interface. Only words that are not also English.
const GERMAN: &[&str] = &[
    "datei",
    "bearbeiten",
    "ansicht",
    "fenster",
    "hilfe",
    "einstellungen",
    "abbrechen",
    "speichern",
    "löschen",
    "öffnen",
    "schließen",
    "zurück",
    "weiter",
    "fertig",
    "wiederholen",
    "rückgängig",
    "ausschneiden",
    "kopieren",
    "einfügen",
    "auswahl",
    "nein",
    "oder",
    "ohne",
    "alle",
    "keine",
    "projekt",
    "sequenz",
    "spur",
    "schnitt",
    "bild",
    "farbe",
    "effekte",
    "übergang",
    "untertitel",
    "ordner",
    "fehler",
    "warnung",
    "laden",
    "exportieren",
    "importieren",
    "aktivieren",
    "deaktivieren",
    "ein",
    "aus",
    "wähle",
    "wählen",
    "markierung",
    "ebene",
    "zeitleiste",
    "vorschau",
];

/// Why `label` reads like an internal name, or `None` when it reads like text for people.
pub fn internal_name(label: &str) -> Option<&'static str> {
    let label = label.trim();
    if label.contains("Some(") || label.contains("Ok(") || label.contains("Err(") || label.contains("::") {
        return Some("Debug output");
    }
    if label.contains(" { ") && label.contains(": ") && label.ends_with('}') {
        return Some("Debug output of a struct");
    }
    let snake = label.split_whitespace().any(|w| {
        let w = w.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '_');
        w.contains('_')
            && w.split('_').all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()))
    });
    if snake {
        return Some("snake_case key");
    }
    let letters = label.chars().count();
    if (2..=3).contains(&letters) && label.chars().all(|c| c.is_ascii_uppercase()) && !ACRONYMS.contains(&label) {
        return Some("bare code");
    }
    None
}

/// Why `label`, a text shown to the user as it is (a menu row, a command title, a caption), reads like something
/// internal or foreign, or `None`. It runs [`internal_name`] and then looks at every word: an all-caps 2 or 3 letter
/// code that is not an allow-listed acronym, a locale code (`en-US`), an identifier in camelCase, an unfilled
/// placeholder (`%@`, `{name}`), a leftover `nil`, and German words or letters in the English interface.
pub fn visible_problem(label: &str) -> Option<&'static str> {
    if let Some(why) = internal_name(label) {
        return Some(why);
    }
    let label = label.trim();
    if label.contains("%@")
        || label.contains("%d")
        || label.contains("%s")
        || (label.contains('{') && label.contains('}'))
    {
        return Some("unfilled placeholder");
    }
    if label.chars().any(|c| matches!(c, 'ä' | 'ö' | 'ü' | 'Ä' | 'Ö' | 'Ü' | 'ß')) {
        return Some("German letters");
    }
    let words = label
        .split(|c: char| c.is_whitespace() || "/()[],:;\"+=\u{2026}\u{2192}".contains(c))
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric() && c != '_' && c != '-'))
        .filter(|w| !w.is_empty());
    for word in words {
        let letters = word.chars().count();
        if (2..=3).contains(&letters) && word.chars().all(|c| c.is_ascii_uppercase()) && !ACRONYMS.contains(&word) {
            return Some("bare code");
        }
        // A locale code: `en-US`, `pt_BR`, `zh-Hans`, `es-419`. A hyphenated word like `use-pass` is not one.
        if let Some((lang, region)) = word.split_once(['-', '_'])
            && (2..=3).contains(&lang.len())
            && lang.chars().all(|c| c.is_ascii_lowercase())
            && (region.len() == 2 && region.chars().all(|c| c.is_ascii_uppercase())
                || region.len() == 4
                    && region.starts_with(|c: char| c.is_ascii_uppercase())
                    && region[1..].chars().all(|c| c.is_ascii_lowercase())
                || region.len() == 3 && region.chars().all(|c| c.is_ascii_digit()))
        {
            return Some("locale code");
        }
        if word.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && word.chars().any(|c| c.is_ascii_uppercase())
            && !LOWER_CAMEL_OK.contains(&word)
        {
            return Some("camelCase identifier");
        }
        if matches!(word, "nil" | "null" | "undefined" | "NaN" | "TODO" | "FIXME") {
            return Some("leftover placeholder word");
        }
        if GERMAN.contains(&word.to_lowercase().as_str()) {
            return Some("German word");
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::localization::SQL10n;

    #[test]
    fn the_visible_text_lint_looks_at_every_word() {
        for bad in [
            "Language: DE",
            "Spoken Language (pt-BR)",
            "Open quickExport",
            "Delete %@",
            "Move {name} up",
            "Löschen",
            "Datei öffnen",
            "Zeitleiste",
            "Clip is nil",
            "Set Mode: clip_speed",
            "Some(3)",
        ] {
            assert!(visible_problem(bad).is_some(), "{bad}");
        }
        for good in [
            "Import LUT…",
            "Add HDR Tone Mapping",
            "Audio EQ",
            "Level (dB)",
            "Export 4K",
            "Open in ProRes 422",
            "Share to YouTube",
            "Go to In",
            "None",
            "Use iPhone Camera Profile",
        ] {
            assert_eq!(visible_problem(good), None, "{good}");
        }
    }

    /// Every command the app can run has an English title that reads like text, so a menu or a shortcut list never shows an
    /// identifier (`quickExport`) or a code.
    #[test]
    fn no_command_title_is_a_code_an_identifier_or_a_german_word() {
        use crate::command_catalog::CommandCatalog;
        use crate::command_map::CommandMap;
        let map = CommandMap::premiere_default();
        let commands = CommandCatalog::audited(&map);
        assert!(commands.len() > 300, "the catalog loads: {}", commands.len());
        let bad: Vec<String> = commands
            .iter()
            .filter_map(|c| visible_problem(&c.title()).map(|why| format!("{c:?} -> {:?}: {why}", c.title())))
            .collect();
        assert!(bad.is_empty(), "command titles that read like internal names: {bad:#?}");
    }

    #[test]
    fn the_lint_names_what_it_catches() {
        for bad in ["LB", "LN", "Some(3)", "Green { r: 1 }", "clip_speed", "model::Kind"] {
            assert!(internal_name(bad).is_some(), "{bad}");
        }
        for good in ["Luxembourgish", "OK", "PNG", "Speed (%)", "Save as…", "Undo %@", "No sound", "AV1"] {
            assert_eq!(internal_name(good), None, "{good}");
        }
    }

    /// Every English label of the interface (the keys of the localization tables) reads like text for people.
    #[test]
    fn no_localized_label_is_a_code_a_snake_case_key_or_debug_output() {
        let table = SQL10n::table("de");
        assert!(table.len() > 100, "the bundled table loads");
        let bad: Vec<String> =
            table.keys().filter_map(|k| internal_name(k).map(|why| format!("{k:?}: {why}"))).collect();
        assert!(bad.is_empty(), "labels that read like internal names: {bad:#?}");
    }
}
