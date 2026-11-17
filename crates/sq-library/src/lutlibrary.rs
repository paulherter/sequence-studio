// Swift: LUTLibrary.swift
//! The user's LUT collection: `.cube` files copied into one directory (App Support), plus starred favorites.

use crate::favorites::json_file_io;
use serde::{Deserialize, Serialize};
use sq_core_time::{Timestamp, text::standard_compare};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// One LUT of the library.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LUTEntry {
    /// File name with extension; the identity.
    pub file_name: String,
    /// Full path.
    pub path: String,
    /// Starred.
    pub is_favourite: bool,
}

impl LUTEntry {
    /// Display name: file name without extension.
    pub fn name(&self) -> &str {
        self.file_name.rsplit_once('.').map_or(self.file_name.as_str(), |(stem, _)| stem)
    }
}

/// The biggest LUT file read; a 64^3 table is about 8 MB of text, so this only stops a wrong file from filling memory.
const MAX_LUT_BYTES: u64 = 256 * 1024 * 1024;

/// Reads `path` with the same parser the renderer uses. `Err` is the reason in one phrase ("not a valid LUT (line 2: ...)"),
/// for a message that starts with the file name. A file that fails here would be dropped silently at render time,
/// so no import or file choice may let it through.
pub fn check_lut_file(path: &Path) -> Result<(), String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("the file cannot be read ({e})"))?;
    if meta.len() > MAX_LUT_BYTES {
        return Err("not a valid LUT (the file is too large)".to_string());
    }
    let bytes = std::fs::read(path).map_err(|e| format!("the file cannot be read ({e})"))?;
    sq_render::color::CubeLut::parse(&String::from_utf8_lossy(&bytes))
        .map(|_| ())
        .map_err(|e| format!("not a valid LUT ({e})"))
}

/// What an import did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportResult {
    /// LUTs copied into the library.
    pub added: Vec<LUTEntry>,
    /// Files that were refused (not a valid LUT) or could not be copied, with the reason.
    pub failures: Vec<(PathBuf, String)>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FavouriteFile {
    format_version: i64,
    items: Vec<String>,
}

/// The user's LUT collection. Favorites are stored next to the files and always list first.
#[derive(Debug)]
pub struct LUTLibrary {
    directory: PathBuf,
    favourites: BTreeSet<String>,
    load_error: Option<String>,
}

impl LUTLibrary {
    /// Name of the favorites file in the LUT folder.
    pub const FAVOURITES_FILE_NAME: &'static str = "favourites.json";

    /// Opens the library in `directory`. An unreadable `favourites.json` is moved aside (stamped `now`, not overwritten).
    pub fn new(directory: PathBuf, now: Timestamp) -> LUTLibrary {
        let path = directory.join(Self::FAVOURITES_FILE_NAME);
        let (favourites, load_error) = match Self::load_favourites(&path) {
            Ok(set) => (set, None),
            Err(e) => {
                let _ = json_file_io::backup_corrupt(&path, now);
                (
                    BTreeSet::new(),
                    Some(format!("Favorites could not be read ({e}); the old file was kept as a backup.")),
                )
            }
        };
        LUTLibrary { directory, favourites, load_error }
    }

    fn load_favourites(path: &Path) -> Result<BTreeSet<String>, String> {
        if !path.exists() {
            return Ok(BTreeSet::new());
        }
        let data = std::fs::read(path).map_err(|e| e.to_string())?;
        let file: FavouriteFile = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
        Ok(file.items.into_iter().collect())
    }

    /// `<app support>/<app name>/LUTs`.
    pub fn default_directory(application_support: &Path, app_name: &str) -> PathBuf {
        application_support.join(app_name).join("LUTs")
    }

    /// The folder of the LUT files.
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Set when `favourites.json` was unreadable; the bad file was moved aside (`favourites.json.corrupt-*`), not overwritten.
    pub fn load_error(&self) -> Option<&str> {
        self.load_error.as_deref()
    }

    /// Drops stars of LUT files that no longer exist. Returns true if anything changed.
    pub fn prune_missing_favourites(&mut self) -> Result<bool, crate::favorites::LibraryStoreError> {
        let missing: Vec<String> =
            self.favourites.iter().filter(|f| !self.directory.join(f).exists()).cloned().collect();
        if missing.is_empty() {
            return Ok(false);
        }
        for m in &missing {
            self.favourites.remove(m);
        }
        self.save_favourites()?;
        Ok(true)
    }

    /// The file name is starred.
    pub fn is_favourite(&self, file_name: &str) -> bool {
        self.favourites.contains(file_name)
    }

    /// Favorites first, then the rest; each group in natural, case-insensitive name order.
    pub fn entries(&self) -> Vec<LUTEntry> {
        let names = std::fs::read_dir(&self.directory)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.to_lowercase().ends_with(".cube"));
        let (mut stars, mut rest): (Vec<LUTEntry>, Vec<LUTEntry>) = names
            .map(|n| LUTEntry {
                path: self.directory.join(&n).to_string_lossy().into_owned(),
                is_favourite: self.favourites.contains(&n),
                file_name: n,
            })
            .partition(|e| e.is_favourite);
        let by_name = |a: &LUTEntry, b: &LUTEntry| {
            standard_compare(&a.file_name, &b.file_name).then_with(|| a.file_name.cmp(&b.file_name))
        };
        stars.sort_by(by_name);
        rest.sort_by(by_name);
        stars.extend(rest);
        stars
    }

    /// Copies the `.cube` files among `paths` into the library (never moves or edits the originals);
    /// name clashes get a numeric suffix. A file that is not a valid LUT is refused (see [`check_lut_file`]) and one that
    /// fails to copy is reported; neither stops the others.
    pub fn import_luts(&mut self, paths: &[PathBuf]) -> ImportResult {
        let mut result = ImportResult::default();
        if let Err(e) = std::fs::create_dir_all(&self.directory) {
            result.failures = paths.iter().map(|p| (p.clone(), e.to_string())).collect();
            return result;
        }
        for path in paths.iter().filter(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("cube"))) {
            if let Err(why) = check_lut_file(path) {
                result.failures.push((path.clone(), why));
                continue;
            }
            let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            let (mut name, mut n) = (format!("{stem}.cube"), 2);
            while self.directory.join(&name).exists() {
                name = format!("{stem} {n}.cube");
                n += 1;
            }
            let dest = self.directory.join(&name);
            match std::fs::copy(path, &dest) {
                Ok(_) => result.added.push(LUTEntry {
                    file_name: name,
                    path: dest.to_string_lossy().into_owned(),
                    is_favourite: false,
                }),
                Err(e) => result.failures.push((path.clone(), e.to_string())),
            }
        }
        result
    }

    /// Stars or unstars a LUT; returns the new state.
    pub fn toggle_favourite(&mut self, file_name: &str) -> Result<bool, crate::favorites::LibraryStoreError> {
        let now = !self.favourites.contains(file_name);
        if now {
            self.favourites.insert(file_name.to_string());
        } else {
            self.favourites.remove(file_name);
        }
        self.save_favourites()?;
        Ok(now)
    }

    /// Deletes the library copy (and its star).
    pub fn remove(&mut self, file_name: &str) -> Result<(), crate::favorites::LibraryStoreError> {
        let _ = std::fs::remove_file(self.directory.join(file_name));
        if self.favourites.remove(file_name) {
            self.save_favourites()?;
        }
        Ok(())
    }

    fn save_favourites(&self) -> Result<(), crate::favorites::LibraryStoreError> {
        json_file_io::write_atomically(
            &FavouriteFile { format_version: 1, items: self.favourites.iter().cloned().collect() },
            &self.directory.join(Self::FAVOURITES_FILE_NAME),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn lib(dst: &TempDir) -> LUTLibrary {
        LUTLibrary::new(dst.path().join("LUTs"), NOW)
    }

    fn names(l: &LUTLibrary) -> Vec<String> {
        l.entries().iter().map(|e| e.name().to_string()).collect()
    }

    fn file_names(l: &LUTLibrary) -> Vec<String> {
        l.entries().iter().map(|e| e.file_name.clone()).collect()
    }

    /// A valid 2 x 2 x 2 LUT (the identity) written to `name`.
    fn cube(dir: &TempDir, name: &str) -> PathBuf {
        let rows: String = (0..8).map(|i| format!("{} {} {}\n", i & 1, (i >> 1) & 1, (i >> 2) & 1)).collect();
        write_text(dir, name, &format!("LUT_3D_SIZE 2\n{rows}"))
    }

    fn write_text(dir: &TempDir, name: &str, text: &str) -> PathBuf {
        let file = dir.path().join(name);
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&file, text);
        file
    }

    #[test]
    fn import_refuses_a_broken_cube_and_names_the_file_and_the_reason() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        let broken = write_text(&src, "broken.cube", "this is not a LUT\nLUT_3D_SIZE 99999\n1 2\n");
        let r = l.import_luts(&[broken.clone(), cube(&src, "good.cube")]);
        assert_eq!(r.added.iter().map(|e| e.file_name.as_str()).collect::<Vec<_>>(), ["good.cube"]);
        let (path, why) = &r.failures[0];
        assert_eq!(path, &broken);
        assert!(why.starts_with("not a valid LUT ("), "{why}");
        assert_eq!(file_names(&l), ["good.cube"], "nothing of the broken file is stored");
    }

    #[test]
    fn check_lut_file_says_what_is_wrong() {
        let src = TempDir::new();
        let reason = |text: &str| check_lut_file(&write_text(&src, "x.cube", text)).err().unwrap_or_default();
        assert!(reason("LUT_3D_SIZE 99999\n").contains("out of range"), "size");
        assert!(reason("LUT_3D_SIZE 2\n0 0 0\n").contains("1 table rows, but its size asks for 8"), "short table");
        for garbage in ["hello\n", "LUT_3D_SIZE 2\n0 0 x\n", ""] {
            assert!(reason(garbage).starts_with("not a valid LUT ("), "{garbage:?}");
        }
        assert!(check_lut_file(&src.path().join("missing.cube")).is_err());
        assert_eq!(check_lut_file(&cube(&src, "ok.cube")), Ok(()));
    }

    #[test]
    fn import_copies_cube_files_only() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let (a, b) = (cube(&src, "Warm.cube"), src.write("notes.txt", 4));
        let mut l = lib(&dst);
        let added = l.import_luts(&[a.clone(), b]).added;
        assert_eq!(added.iter().map(|e| e.file_name.as_str()).collect::<Vec<_>>(), ["Warm.cube"]);
        assert!(Path::new(&l.entries()[0].path).exists());
        assert_eq!(l.entries()[0].name(), "Warm");
        assert!(a.exists()); // original untouched
    }

    #[test]
    fn import_renames_on_collision() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let (a, b) = (cube(&src, "Warm.cube"), cube(&src, "sub/Warm.cube"));
        let mut l = lib(&dst);
        l.import_luts(&[a]);
        l.import_luts(&[b]);
        assert_eq!(file_names(&l), ["Warm 2.cube", "Warm.cube"]);
    }

    #[test]
    fn starred_lut_is_first() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        l.import_luts(&["A.cube", "B.cube", "C.cube"].map(|n| cube(&src, n)));
        assert_eq!(names(&l), ["A", "B", "C"]);
        assert_eq!(l.toggle_favourite("C.cube"), Ok(true));
        assert_eq!(names(&l), ["C", "A", "B"]);
        assert!(l.entries()[0].is_favourite);
        assert!(l.toggle_favourite("B.cube").is_ok());
        assert_eq!(names(&l), ["B", "C", "A"]);
        assert_eq!(l.toggle_favourite("C.cube"), Ok(false));
        assert_eq!(names(&l), ["B", "A", "C"]);
    }

    #[test]
    fn favourites_persist_across_reload() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        l.import_luts(&["A.cube", "B.cube"].map(|n| cube(&src, n)));
        assert!(l.toggle_favourite("B.cube").is_ok());
        assert_eq!(names(&lib(&dst)), ["B", "A"]);
    }

    #[test]
    fn remove_deletes_file_and_favourite() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        l.import_luts(&[cube(&src, "A.cube")]);
        assert!(l.toggle_favourite("A.cube").is_ok());
        assert!(l.remove("A.cube").is_ok());
        assert!(l.entries().is_empty());
        assert!(!lib(&dst).is_favourite("A.cube"));
    }

    #[test]
    fn natural_name_order() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        l.import_luts(&["look10.cube", "Look2.cube"].map(|n| cube(&src, n)));
        assert_eq!(names(&l), ["Look2", "look10"]);
    }

    #[test]
    fn import_keeps_earlier_files_when_a_later_one_fails() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        let list = [cube(&src, "A.cube"), src.path().join("missing.cube"), cube(&src, "C.cube")];
        let r = l.import_luts(&list);
        assert_eq!(r.added.iter().map(|e| e.file_name.as_str()).collect::<Vec<_>>(), ["A.cube", "C.cube"]);
        assert_eq!(r.failures.len(), 1);
    }

    #[test]
    fn corrupt_favourites_are_kept_as_backup_not_overwritten() {
        let dst = TempDir::new();
        let dir = dst.path().join("LUTs");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("favourites.json"), b"not json");
        let mut l = LUTLibrary::new(dir.clone(), NOW);
        assert!(l.load_error().is_some());
        assert!(l.toggle_favourite("A.cube").is_ok());
        assert!(json_file_io::names_in(&dir).iter().any(|n| n.starts_with("favourites.json.corrupt-")));
    }

    #[test]
    fn prune_drops_stars_of_missing_files() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let mut l = lib(&dst);
        l.import_luts(&["A.cube", "B.cube"].map(|n| cube(&src, n)));
        assert!(l.toggle_favourite("A.cube").is_ok() && l.toggle_favourite("B.cube").is_ok());
        let _ = std::fs::remove_file(l.directory().join("A.cube"));
        assert_eq!(l.prune_missing_favourites(), Ok(true));
        assert!(!l.is_favourite("A.cube") && l.is_favourite("B.cube"));
        assert!(!lib(&dst).is_favourite("A.cube"));
    }
}
