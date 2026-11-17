// SPDX-License-Identifier: GPL-3.0-or-later
//! The one place that names the product's folders under the per-user roots (Application Support, the caches folder,
//! `%LOCALAPPDATA%`, the XDG data folder): `Sequence Studio` everywhere, with the older `SequenceStudio` spelling moved over
//! once.

use std::path::{Path, PathBuf};

/// The product's folder name under every per-user root.
pub const APP_FOLDER: &str = "Sequence Studio";
/// The spelling older builds used for the model and matte folders.
const LEGACY_APP_FOLDER: &str = "SequenceStudio";

/// `<root>/Sequence Studio/<name>`. An older `<root>/SequenceStudio/<name>` is moved there once (when the new folder does
/// not exist yet); the old parent goes away when nothing else is left in it.
pub fn app_subfolder(root: &Path, name: &str) -> PathBuf {
    let new = root.join(APP_FOLDER).join(name);
    let old_root = root.join(LEGACY_APP_FOLDER);
    let old = old_root.join(name);
    if !new.exists() && old.is_dir() {
        if let Some(parent) = new.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if std::fs::rename(&old, &new).is_ok() {
            let _ = std::fs::remove_dir(&old_root);
        }
    }
    new
}

/// A model folder: the folder `override_var` names, else `name` under the per-user data root (`%LOCALAPPDATA%`, Application
/// Support on the Mac, the XDG data folder elsewhere). `env` reads the variables.
pub fn data_subfolder(env: impl Fn(&str) -> Option<String>, override_var: &str, name: &str) -> PathBuf {
    let set = |key: &str| env(key).filter(|v| !v.is_empty());
    if let Some(p) = set(override_var) {
        return PathBuf::from(p);
    }
    if let Some(p) = set("LOCALAPPDATA") {
        return app_subfolder(Path::new(&p), name);
    }
    let home = PathBuf::from(set("HOME").unwrap_or_default());
    let root = if cfg!(target_os = "macos") {
        home.join("Library/Application Support")
    } else {
        set("XDG_DATA_HOME").map_or_else(|| home.join(".local/share"), PathBuf::from)
    };
    app_subfolder(&root, name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-os-folders-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    #[test]
    fn the_name_has_the_space_and_nothing_is_created() {
        let root = temp("plain");
        assert_eq!(app_subfolder(&root, "People"), root.join("Sequence Studio").join("People"));
        assert!(!root.join("Sequence Studio").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_old_folder_moves_over_once_and_keeps_its_files() {
        let root = temp("move");
        let old = root.join("SequenceStudio").join("Whisper");
        std::fs::create_dir_all(&old).expect("old");
        std::fs::write(old.join("model.bin"), b"m").expect("file");
        let new = app_subfolder(&root, "Whisper");
        assert_eq!(std::fs::read(new.join("model.bin")).expect("moved"), b"m");
        assert!(!root.join("SequenceStudio").exists(), "the emptied old parent is gone");
        assert_eq!(app_subfolder(&root, "Whisper"), new, "the second call changes nothing");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_new_folder_that_exists_wins_and_the_old_one_stays() {
        let root = temp("both");
        std::fs::create_dir_all(root.join("Sequence Studio/People")).expect("new");
        std::fs::create_dir_all(root.join("SequenceStudio/People")).expect("old");
        app_subfolder(&root, "People");
        assert!(root.join("SequenceStudio/People").is_dir());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_override_wins_and_the_data_root_is_named_by_the_environment() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(a, _)| *a == k).map(|(_, v)| (*v).to_string())
        };
        assert_eq!(data_subfolder(env(&[("SQ_X", "/m"), ("HOME", "/h")]), "SQ_X", "People"), PathBuf::from("/m"));
        assert_eq!(
            data_subfolder(env(&[("LOCALAPPDATA", "/L")]), "SQ_X", "People"),
            PathBuf::from("/L/Sequence Studio/People")
        );
        let home = data_subfolder(env(&[("HOME", "/h"), ("XDG_DATA_HOME", "/x")]), "SQ_X", "People");
        let want = if cfg!(target_os = "macos") { "/h/Library/Application Support" } else { "/x" };
        assert_eq!(home, Path::new(want).join("Sequence Studio/People"));
    }
}
