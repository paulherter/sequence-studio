// Swift: LibraryFolderStore.swift (the folders lived in user defaults)
//! The library folders of the Swift app, read once from its user defaults file (read-only, never changed or deleted) when this
//! app's own list is empty, so a library built there is not lost at the switch. Mac only: other systems have no such file.

use std::path::{Path, PathBuf};

use sq_library::library_folder_store::LibraryFolderStore;
use sq_library::watched_folder::WatchedFolder;
use sq_uikit::appearance_palette::UiDefaults;

/// Stored after the one import (also when it found nothing), so folders the user removes later do not come back.
const MARKER: &str = "sq.library.foldersImported";

/// Set by shots and other headless runs: they never read the user's preferences (the Swift app's defaults file).
static ISOLATED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Keeps this run away from the user's real preferences: no Swift defaults import (shots, headless renders and tests
/// then never read the user's watched folders).
pub fn isolate_preferences() {
    ISOLATED.store(true, std::sync::atomic::Ordering::Relaxed);
}

/// Whether the Swift defaults may be read: only on the Mac, in a normal run with the app's own support folder.
fn may_read_swift_defaults(test: bool, mac: bool, own_support: bool, isolated: bool) -> bool {
    !test && mac && !own_support && !isolated
}

/// The user defaults file of the Swift app, `None` off the Mac, when a run has its own support folder (tests, portable
/// runs) or is isolated (shots, headless runs), or when no home is known.
pub(crate) fn swift_defaults_file() -> Option<PathBuf> {
    let own_support = std::env::var_os("SQ_SUPPORT_DIR").is_some_and(|d| !d.is_empty());
    let isolated = ISOLATED.load(std::sync::atomic::Ordering::Relaxed);
    if !may_read_swift_defaults(cfg!(test), cfg!(target_os = "macos"), own_support, isolated) {
        return None;
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Preferences/de.paulherter.SequenceStudio.plist"))
}

/// Imports the folders of the plist `file` into `defaults` once; returns what was imported (empty when nothing is to do).
pub(crate) fn import_swift_folders(
    defaults: &mut (impl UiDefaults + sq_library::library_folder_store::SettingsStore),
    file: &Path,
) -> Vec<WatchedFolder> {
    if UiDefaults::string(defaults, MARKER).is_some() {
        return Vec::new();
    }
    let Some(xml) = plist_xml(file) else { return Vec::new() };
    let Some(bytes) = data_value(&xml, LibraryFolderStore::KEY) else {
        UiDefaults::set_string(defaults, MARKER, "1");
        return Vec::new();
    };
    let folders: Vec<WatchedFolder> = serde_json::from_slice(&bytes).unwrap_or_default();
    UiDefaults::set_string(defaults, MARKER, "1");
    if !folders.is_empty() {
        LibraryFolderStore::save(&folders, defaults);
    }
    folders
}

/// The plist as XML text: an XML file as it is, a binary one converted by `plutil` (a copy on stdout; the file is untouched).
fn plist_xml(file: &Path) -> Option<String> {
    let raw = std::fs::read(file).ok()?;
    if raw.starts_with(b"<?xml") {
        return String::from_utf8(raw).ok();
    }
    let out = std::process::Command::new("plutil").args(["-convert", "xml1", "-o", "-"]).arg(file).output().ok()?;
    out.status.success().then(|| String::from_utf8(out.stdout).ok()).flatten()
}

/// The `<data>` value stored under `key` in an XML plist.
fn data_value(xml: &str, key: &str) -> Option<Vec<u8>> {
    let after = &xml[xml.find(&format!("<key>{key}</key>"))? + key.len() + 11..];
    let rest = after.trim_start().strip_prefix("<data>")?;
    let body: String = rest[..rest.find("</data>")?].split_whitespace().collect();
    sq_core_time::base64::decode(&body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::persist::{FileDefaults, FileView};
    use std::rc::Rc;

    #[test]
    fn shots_and_headless_runs_never_read_the_swift_defaults() {
        assert!(may_read_swift_defaults(false, true, false, false), "a normal Mac run imports once");
        assert!(!may_read_swift_defaults(false, true, false, true), "isolated: no import");
        assert!(!may_read_swift_defaults(false, true, true, false), "own support folder: no import");
        assert!(
            !may_read_swift_defaults(true, true, false, false) && !may_read_swift_defaults(false, false, false, false)
        );
    }

    fn fake_plist(dir: &Path, folders_json: &str) -> PathBuf {
        let data = sq_core_time::base64::encode(folders_json.as_bytes());
        let (a, b) = data.split_at(data.len() / 2);
        let xml = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n<key>sq.library.tileSize</key><real>0.25</real>\n<key>sq.library.folders</key>\n<data>\n{a}\n{b}\n</data>\n</dict></plist>\n"
        );
        let path = dir.join("old.plist");
        std::fs::write(&path, xml).unwrap();
        path
    }

    #[test]
    fn the_folders_of_the_old_app_are_imported_once_and_the_old_file_stays() {
        let dir = crate::test_rig::test_dir("sq-legacy-folders");
        std::fs::create_dir_all(&dir).unwrap();
        let json = r#"[{"displayName":"Footage","id":"9B70C735-2617-42DB-B082-C4EBDE259F51","url":"file:\/\/\/Users\/me\/Footage\/"}]"#;
        let plist = fake_plist(&dir, json);
        let before = std::fs::read(&plist).unwrap();
        let mut view = FileView(FileDefaults::shared(&dir));
        let got = import_swift_folders(&mut view, &plist);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].display_name, "Footage");
        assert_eq!(got[0].url, PathBuf::from("/Users/me/Footage"));
        assert_eq!(LibraryFolderStore::load(&mut FileView(Rc::clone(&view.0))).len(), 1, "stored in the new list");
        assert_eq!(std::fs::read(&plist).unwrap(), before, "the old file is untouched");
        // The user removes the folder later: it must not come back from the old file.
        LibraryFolderStore::save(&[], &mut view);
        assert!(import_swift_folders(&mut view, &plist).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_old_file_or_no_key_imports_nothing() {
        let dir = crate::test_rig::test_dir("sq-legacy-none");
        std::fs::create_dir_all(&dir).unwrap();
        let mut view = FileView(FileDefaults::shared(&dir));
        assert!(import_swift_folders(&mut view, &dir.join("missing.plist")).is_empty());
        let other = dir.join("other.plist");
        std::fs::write(&other, "<?xml version=\"1.0\"?><plist><dict><key>a</key><string>b</string></dict></plist>")
            .unwrap();
        assert!(import_swift_folders(&mut view, &other).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
