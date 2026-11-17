// SPDX-License-Identifier: GPL-3.0-or-later
//! The files a package may hold (`packaging/stage-allowlist.txt`, which `packaging/windows/build-installer.ps1` reads too).
//! A folder copied wholesale carries only what is on the list, and the finished stage is checked, so a stray file (a sync
//! tool's `.sync-state.json`, a `.DS_Store`) stops the build instead of shipping.

use std::path::{Path, PathBuf};

const LIST: &str = include_str!("../../../packaging/stage-allowlist.txt");

/// What the sections of the list let through.
pub(crate) struct Allow {
    extensions: Vec<String>,
    names: Vec<String>,
}

impl Allow {
    /// The entries of the named sections of the shipped list.
    pub(crate) fn of(sections: &[&str]) -> Allow {
        Allow::parse(LIST, sections)
    }

    fn parse(text: &str, sections: &[&str]) -> Allow {
        let mut allow = Allow { extensions: Vec::new(), names: Vec::new() };
        let mut current = "";
        for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
            if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                current = name;
            } else if sections.contains(&current) {
                match line.strip_prefix('=') {
                    Some(name) => allow.names.push(name.to_lowercase()),
                    None => allow.extensions.push(line.to_lowercase()),
                }
            }
        }
        allow
    }

    /// Whether a file of this name may be in the package.
    pub(crate) fn allows(&self, file_name: &str) -> bool {
        let name = file_name.to_lowercase();
        self.names.contains(&name) || extension(&name).is_some_and(|e| self.extensions.iter().any(|x| x == e))
    }

    fn allows_path(&self, path: &Path) -> bool {
        path.file_name().is_some_and(|n| self.allows(&n.to_string_lossy()))
    }
}

/// `libavcodec.so.63` is a shared library whatever its version digits.
fn extension(name: &str) -> Option<&str> {
    if let Some((_, version)) = name.split_once(".so.")
        && version.chars().all(|c| c.is_ascii_digit() || c == '.')
    {
        return Some("so");
    }
    name.rsplit_once('.').map(|(_, e)| e)
}

/// Every file below `root` (links count as files), relative to it, in name order.
fn files(root: &Path) -> Result<Vec<PathBuf>, String> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))? {
            let entry = entry.map_err(|e| e.to_string())?;
            if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
                pending.push(entry.path());
            } else {
                found.push(entry.path().strip_prefix(root).map_err(|e| e.to_string())?.to_path_buf());
            }
        }
    }
    found.sort();
    Ok(found)
}

/// Copies the files of `from` that `allow` lets through into `to`, keeping the folder layout; returns the files left out.
fn copy_allowed(from: &Path, to: &Path, allow: &Allow) -> Result<Vec<PathBuf>, String> {
    let mut left_out = Vec::new();
    for rel in files(from)? {
        if !allow.allows_path(&rel) {
            left_out.push(rel);
            continue;
        }
        let dest = to.join(&rel);
        if let Some(dir) = dest.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::copy(from.join(&rel), &dest).map_err(|e| format!("{}: {e}", rel.display()))?;
    }
    Ok(left_out)
}

/// The Fonts folder: font files and their license texts only.
pub(crate) fn copy_fonts(from: &Path, to: &Path) -> Result<(), String> {
    let left_out = copy_allowed(from, to, &Allow::of(&["fonts"]))?;
    if !left_out.is_empty() {
        println!(
            "== fonts: left out {} file(s) that are not fonts or license texts: {}",
            left_out.len(),
            names(&left_out)
        );
    }
    Ok(())
}

/// Fails when `stage` holds a file that the sections do not allow.
pub(crate) fn check(stage: &Path, sections: &[&str]) -> Result<(), String> {
    let allow = Allow::of(sections);
    let stray: Vec<PathBuf> = files(stage)?.into_iter().filter(|rel| !allow.allows_path(rel)).collect();
    if stray.is_empty() {
        return Ok(());
    }
    Err(format!(
        "{} holds {} file(s) that are not on packaging/stage-allowlist.txt: {}",
        stage.display(),
        stray.len(),
        names(&stray)
    ))
}

fn names(files: &[PathBuf]) -> String {
    let shown: Vec<String> = files.iter().take(20).map(|p| p.display().to_string()).collect();
    let more = files.len().saturating_sub(shown.len());
    format!("{}{}", shown.join(", "), if more > 0 { format!(" (and {more} more)") } else { String::new() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-xtask-stage-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    fn touch(root: &Path, rel: &str) {
        let path = root.join(rel);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
        std::fs::write(path, "x").expect("write");
    }

    #[test]
    fn the_shipped_list_lets_through_what_each_package_holds_and_refuses_strays() {
        let windows = Allow::of(&["common", "windows"]);
        for name in [
            "SequenceStudio.exe",
            "avcodec-61.dll",
            "onnxruntime.dll",
            "SequenceStudio.ico",
            "edgetam_encoder.onnx",
            "Inter-VariableFont_opsz,wght.ttf",
            "OFL.txt",
            "LICENSE",
            "SUPPORTERS.md",
        ] {
            assert!(windows.allows(name), "{name}");
        }
        let linux = Allow::of(&["common", "linux"]);
        for name in ["libavcodec.so.63", "libx.so.1.2.3", "libonnxruntime.so", "AppRun", ".DirIcon", "sequence-studio"]
        {
            assert!(linux.allows(name), "{name}");
        }
        assert!(Allow::of(&["common", "macos"]).allows("Sequence Studio"));
        assert!(Allow::of(&["common", "macos"]).allows("libavcodec.61.dylib"));
        for name in [".sync-state.json", "notes.json", ".DS_Store", "Thumbs.db", "run.sh", "libx.so.beta"] {
            assert!(!linux.allows(name), "{name}");
            assert!(!windows.allows(name), "{name}");
        }
        assert!(!windows.allows("libavcodec.so.63"), "a Linux library does not belong in the Windows stage");
        assert!(!Allow::of(&["fonts"]).allows("SequenceStudio.exe"), "the Fonts folder takes no programs");
    }

    #[test]
    fn the_fonts_copy_keeps_fonts_and_license_texts_and_leaves_the_rest() {
        let (from, to) = (scratch("fonts-from"), scratch("fonts-to"));
        for rel in ["Inter.ttf", "OFL.txt", "Families/anton/Anton.ttf", "Families/anton/OFL.txt", "Big.OTF"] {
            touch(&from, rel);
        }
        for rel in [".sync-state.json", "Families/anton/.DS_Store", "tool.exe"] {
            touch(&from, rel);
        }
        let left_out = copy_allowed(&from, &to, &Allow::of(&["fonts"])).expect("copy");
        assert_eq!(left_out.len(), 3, "{left_out:?}");
        assert!(to.join("Families/anton/Anton.ttf").exists() && to.join("Big.OTF").exists());
        assert_eq!(files(&to).expect("files").len(), 5);
        let _ = (std::fs::remove_dir_all(from), std::fs::remove_dir_all(to));
    }

    #[test]
    fn a_stray_file_anywhere_in_the_stage_fails_the_check_and_names_its_place() {
        let stage = scratch("stage");
        touch(&stage, "SequenceStudio.exe");
        touch(&stage, "Fonts/Inter.ttf");
        assert_eq!(check(&stage, &["common", "windows"]), Ok(()));
        touch(&stage, "Fonts/.sync-state.json");
        let error = check(&stage, &["common", "windows"]).expect_err("a json must fail");
        assert!(error.contains("1 file(s)") && error.contains(".sync-state.json"), "{error}");
        let _ = std::fs::remove_dir_all(stage);
    }
}
