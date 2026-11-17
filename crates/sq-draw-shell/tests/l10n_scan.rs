//! Scan test: every user-visible string the dialogs, forms, panels and empty states declare in source must have a German
//! catalog entry (rule: new UI strings come with German at once).
//!
//! shortcut: this reads string literals at the UI call sites (`ShellDialog::new`, `add_button`, `Row::*`, `*_TITLE/HINT/
//! NOTICE/LABEL/MESSAGE` consts); it does not render. Upgrade to a render-time miss log when the headless driver reaches
//! every panel.

use std::path::{Path, PathBuf};

use sq_uikit::localization::SQL10n;

/// The string literals of the call that opens at `open` (the index of its `(`), up to the matching `)`.
fn call_literals(src: &str, open: usize) -> Vec<String> {
    let b: Vec<char> = src[open..].chars().collect();
    let (mut depth, mut i, mut out) = (0i32, 0usize, Vec::new());
    while i < b.len() {
        match b[i] {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => {
                depth -= 1;
                if depth <= 0 {
                    break;
                }
            }
            '\'' if i + 2 < b.len() && (b[i + 2] == '\'' || b[i + 1] == '\\') => {
                // a char literal such as '"' or '\n'
                i += if b[i + 1] == '\\' { 3 } else { 2 };
            }
            '"' => {
                let mut s = String::new();
                i += 1;
                while i < b.len() && b[i] != '"' {
                    if b[i] == '\\' && i + 1 < b.len() {
                        i += 1;
                        match b[i] {
                            'u' => {
                                let end = b[i..].iter().position(|c| *c == '}').unwrap_or(0) + i;
                                let hex: String = b[i + 2..end].iter().collect();
                                s.extend(u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32));
                                i = end;
                            }
                            'n' => s.push('\n'),
                            c => s.push(c),
                        }
                    } else {
                        s.push(b[i]);
                    }
                    i += 1;
                }
                out.push(s);
            }
            _ => {}
        }
        i += 1;
    }
    out
}

fn sources(root: &Path, out: &mut Vec<PathBuf>, samples: bool) {
    let Ok(rd) = std::fs::read_dir(root) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
        if p.is_dir() {
            if name != "tests" {
                sources(&p, out, samples);
            }
        // shell_dialog_samples.rs holds the demo data of `--pose dlg-*` shots, not UI text
        } else if name.ends_with(".rs") && !name.contains("test") && (samples || name != "shell_dialog_samples.rs") {
            out.push(p);
        }
    }
}

/// Literals of the source before its `#[cfg(test)]` module.
fn production(src: &str) -> &str {
    src.find("#[cfg(test)]").map_or(src, |i| &src[..i])
}

fn looks_like_text(s: &str) -> bool {
    s.chars().filter(|c| c.is_alphabetic()).count() >= 2
        && !s.contains('{')
        && !s.starts_with('/')
        && !s.starts_with("sq.")
}

fn declared_strings(crates: &Path) -> Vec<(String, String)> {
    declared_strings_with(crates, false)
}

fn declared_strings_with(crates: &Path, samples: bool) -> Vec<(String, String)> {
    let mut files = Vec::new();
    for c in
        ["sq-draw-shell", "sq-inspector-ui", "sq-app-shell", "sq-draw-timeline", "sq-draw-monitor", "sq-draw-library"]
    {
        sources(&crates.join(c).join("src"), &mut files, samples);
    }
    let mut found = Vec::new();
    for f in files {
        let text = std::fs::read_to_string(&f).unwrap_or_default();
        let src = production(&text);
        let tag = f.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let mut add = |lits: Vec<String>| {
            for l in lits.into_iter().filter(|l| looks_like_text(l)) {
                found.push((l, tag.clone()));
            }
        };
        for (needle, skip) in [
            ("ShellDialog::new(", 0),
            ("sample_form(", 0),
            (".add_button(", 0),
            ("Row::field(", 1),
            ("Row::popup(", 1),
            ("Row::check(", 1),
            ("Row::slider(", 1),
            ("Row::segmented(", 1),
            ("Row::buttons(", 1),
            ("row(\"", 0),
            ("SQMenuItem::new(", 0),
            ("SQMenuItem::header(", 0),
            ("SQMenuItem::caption(", 0),
            (".help = Some(", 0),
            ("draw_text_in(\"", 0),
        ] {
            for (at, _) in src.match_indices(needle) {
                let lits = call_literals(src, at + needle.len() - 1);
                add(lits.into_iter().skip(skip).collect());
            }
        }
        for (at, _) in src.match_indices("&'static str = \"") {
            let head = src[..at].trim_end().trim_end_matches(':').trim_end();
            let name = head.rsplit(|c: char| !(c.is_alphanumeric() || c == '_')).next().unwrap_or("");
            if ["TITLE", "HINT", "NOTICE", "LABEL", "MESSAGE"].iter().any(|s| name.ends_with(s)) {
                add(call_literals(src, at + "&'static str = ".len()).into_iter().take(1).collect());
            }
        }
    }
    found
}

#[test]
fn every_declared_ui_string_has_a_german_entry() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let de = SQL10n::table("de");
    let mut missing: Vec<String> = declared_strings(&crates)
        .into_iter()
        .filter(|(s, _)| !de.contains_key(s))
        .map(|(s, f)| format!("{f}: {s}"))
        .collect();
    missing.sort();
    missing.dedup();
    assert!(missing.is_empty(), "{} UI strings without German:\n{}", missing.len(), missing.join("\n"));
}

/// Every declared string, the demo dialogs included, reads right on Windows and Linux: no "Mac", "Command-", "Finder"
/// left after the wording table, in English and in German.
#[test]
fn declared_ui_strings_have_no_mac_words_on_windows_and_linux() {
    use sq_os::Platform;
    use sq_uikit::platform_wording::{PlatformWording, mac_leftovers};
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let de = SQL10n::table("de");
    let mut bad = Vec::new();
    for (s, file) in declared_strings_with(&crates, true) {
        for platform in [Platform::Windows, Platform::Linux] {
            let mut shown = vec![PlatformWording::adapt(&s, platform)];
            shown.extend(de.get(&s).map(|d| PlatformWording::adapt(d, platform)));
            for t in shown {
                let left = mac_leftovers(&t);
                if !left.is_empty() {
                    bad.push(format!("{file} ({platform:?}) {left:?}: {t}"));
                }
            }
        }
    }
    bad.sort();
    bad.dedup();
    assert!(bad.is_empty(), "{} strings with Mac words:\n{}", bad.len(), bad.join("\n"));
}
