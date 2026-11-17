// Swift: Favorites.swift
//! Favorite library entries, the error type of the library stores and the helpers every versioned JSON file uses.

use crate::watched_folder::LibraryEntryID;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sq_core_time::Timestamp;
use std::collections::HashSet;
use std::fmt;
use std::path::{Path, PathBuf};

/// Why a library store could not load or change something.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LibraryStoreError {
    /// The file was written by a newer build; it is left untouched.
    NewerFormat {
        /// Version in the file.
        found: i64,
        /// Newest version this build reads.
        supported: i64,
    },
    /// A name that is empty after trimming.
    EmptyName,
    /// No item with that id.
    NotFound,
    /// An item with that id exists.
    DuplicateId,
    /// The file system refused (Swift throws the system error; here its text).
    Io(String),
}

impl fmt::Display for LibraryStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LibraryStoreError::NewerFormat { found, supported } => {
                write!(f, "file format {found} is newer than the supported {supported}")
            }
            LibraryStoreError::EmptyName => f.write_str("the name is empty"),
            LibraryStoreError::NotFound => f.write_str("not found"),
            LibraryStoreError::DuplicateId => f.write_str("the id exists already"),
            LibraryStoreError::Io(text) => f.write_str(text),
        }
    }
}

impl std::error::Error for LibraryStoreError {}

impl From<std::io::Error> for LibraryStoreError {
    fn from(e: std::io::Error) -> Self {
        LibraryStoreError::Io(e.to_string())
    }
}

/// Set of favorite entries keyed by stable entry id.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Favorites {
    ids: HashSet<LibraryEntryID>,
}

impl Favorites {
    /// A set holding `ids`.
    pub fn new(ids: HashSet<LibraryEntryID>) -> Favorites {
        Favorites { ids }
    }

    /// The favorite ids.
    pub fn ids(&self) -> &HashSet<LibraryEntryID> {
        &self.ids
    }

    /// `id` is a favorite.
    pub fn contains(&self, id: &LibraryEntryID) -> bool {
        self.ids.contains(id)
    }

    /// Makes `id` a favorite.
    pub fn add(&mut self, id: LibraryEntryID) {
        self.ids.insert(id);
    }

    /// Removes `id`.
    pub fn remove(&mut self, id: &LibraryEntryID) {
        self.ids.remove(id);
    }

    /// Returns the new state (true = now favorite).
    pub fn toggle(&mut self, id: LibraryEntryID) -> bool {
        if self.ids.remove(&id) {
            return false;
        }
        self.ids.insert(id);
        true
    }
}

/// Versioned JSON persistence for `Favorites`.
pub struct FavoritesStore;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FavoritesFile {
    format_version: i64,
    items: Vec<LibraryEntryID>,
}

impl FavoritesStore {
    /// Version of the file format.
    pub const FORMAT_VERSION: i64 = 1;

    /// The saved favorites. A missing file is empty; a newer one fails; a damaged one is moved aside (at `now`) and empty.
    pub fn load(path: &Path, now: Timestamp) -> Result<Favorites, LibraryStoreError> {
        match json_file_io::load_versioned::<FavoritesFile>(path, Self::FORMAT_VERSION, now)? {
            json_file_io::Loaded::Value(file) => Ok(Favorites::new(file.items.into_iter().collect())),
            json_file_io::Loaded::Missing | json_file_io::Loaded::Recovered => Ok(Favorites::default()),
        }
    }

    /// Writes the favorites, sorted so the file is the same every time.
    pub fn save(favorites: &Favorites, path: &Path) -> Result<(), LibraryStoreError> {
        let mut items: Vec<LibraryEntryID> = favorites.ids.iter().cloned().collect();
        items.sort_by_cached_key(|i| (i.relative_path.clone(), i.folder_id.to_string()));
        json_file_io::write_atomically(&FavoritesFile { format_version: Self::FORMAT_VERSION, items }, path)
    }
}

/// Shared helpers for versioned JSON files (Swift `JSONFileIO`).
pub(crate) mod json_file_io {
    use super::*;
    use serde_json::ser::Formatter;
    use std::io::{self, Write};

    /// Number of `<name>.corrupt-*` backups kept per file name.
    pub(crate) const CORRUPT_BACKUPS_TO_KEEP: usize = 3;

    /// `JSONEncoder` with `.prettyPrinted`: two-space indent and `"key" : value`.
    struct SwiftPretty {
        depth: usize,
        has_value: bool,
    }

    impl SwiftPretty {
        fn indent<W: ?Sized + Write>(&self, w: &mut W) -> io::Result<()> {
            for _ in 0..self.depth {
                w.write_all(b"  ")?;
            }
            Ok(())
        }

        fn open<W: ?Sized + Write>(&mut self, w: &mut W, bracket: &[u8]) -> io::Result<()> {
            self.depth += 1;
            self.has_value = false;
            w.write_all(bracket)
        }

        fn close<W: ?Sized + Write>(&mut self, w: &mut W, bracket: &[u8]) -> io::Result<()> {
            self.depth -= 1;
            if self.has_value {
                w.write_all(b"\n")?;
                self.indent(w)?;
            }
            w.write_all(bracket)
        }

        fn item<W: ?Sized + Write>(&self, w: &mut W, first: bool) -> io::Result<()> {
            w.write_all(if first { b"\n" } else { b",\n" })?;
            self.indent(w)
        }
    }

    impl Formatter for SwiftPretty {
        fn begin_array<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
            self.open(w, b"[")
        }
        fn end_array<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
            self.close(w, b"]")
        }
        fn begin_array_value<W: ?Sized + Write>(&mut self, w: &mut W, first: bool) -> io::Result<()> {
            self.item(w, first)
        }
        fn end_array_value<W: ?Sized + Write>(&mut self, _: &mut W) -> io::Result<()> {
            self.has_value = true;
            Ok(())
        }
        fn begin_object<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
            self.open(w, b"{")
        }
        fn end_object<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
            self.close(w, b"}")
        }
        fn begin_object_key<W: ?Sized + Write>(&mut self, w: &mut W, first: bool) -> io::Result<()> {
            self.item(w, first)
        }
        fn begin_object_value<W: ?Sized + Write>(&mut self, w: &mut W) -> io::Result<()> {
            w.write_all(b" : ")
        }
        fn end_object_value<W: ?Sized + Write>(&mut self, _: &mut W) -> io::Result<()> {
            self.has_value = true;
            Ok(())
        }
    }

    /// Pretty JSON with sorted keys (Swift `[.prettyPrinted, .sortedKeys]`): going through `Value` sorts the keys.
    pub(crate) fn pretty_sorted<T: Serialize>(value: &T) -> Result<Vec<u8>, LibraryStoreError> {
        let value = sq_core_time::json_sorted::to_value(value).map_err(|e| LibraryStoreError::Io(e.to_string()))?;
        let mut out = Vec::new();
        let mut ser = serde_json::Serializer::with_formatter(&mut out, SwiftPretty { depth: 0, has_value: false });
        value.serialize(&mut ser).map_err(|e| LibraryStoreError::Io(e.to_string()))?;
        Ok(out)
    }

    /// Writes `value` as pretty sorted JSON, making the folder first; the file appears whole or not at all.
    pub(crate) fn write_atomically<T: Serialize>(value: &T, path: &Path) -> Result<(), LibraryStoreError> {
        let data = pretty_sorted(value)?;
        write_bytes_atomically(&data, path)
    }

    /// Writes `data` next to `path` and renames it into place.
    pub(crate) fn write_bytes_atomically(data: &[u8], path: &Path) -> Result<(), LibraryStoreError> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut temp = path.as_os_str().to_owned();
        temp.push(format!(".tmp-{}", std::process::id()));
        let temp = PathBuf::from(temp);
        std::fs::write(&temp, data)?;
        std::fs::rename(&temp, path).inspect_err(|_| {
            let _ = std::fs::remove_file(&temp);
        })?;
        Ok(())
    }

    /// What `load_versioned` found.
    pub(crate) enum Loaded<T> {
        /// No file.
        Missing,
        /// A damaged file: it was moved aside.
        Recovered,
        /// The file's content.
        Value(T),
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Header {
        format_version: i64,
    }

    /// Reads a file with a `formatVersion` key. A newer version fails and leaves the file; a damaged file is moved aside.
    pub(crate) fn load_versioned<T: DeserializeOwned>(
        path: &Path,
        supported: i64,
        now: Timestamp,
    ) -> Result<Loaded<T>, LibraryStoreError> {
        if !path.exists() {
            return Ok(Loaded::Missing);
        }
        let data = std::fs::read(path)?;
        if let Ok(header) = serde_json::from_slice::<Header>(&data) {
            if header.format_version > supported {
                return Err(LibraryStoreError::NewerFormat { found: header.format_version, supported });
            }
            if let Ok(value) = serde_json::from_slice::<T>(&data) {
                return Ok(Loaded::Value(value));
            }
        }
        backup_corrupt(path, now)?;
        Ok(Loaded::Recovered)
    }

    /// `(stamp, counter)` of `<name>.corrupt-<stamp>[-<counter>]`.
    fn order_of(file_name: &str, prefix: &str) -> Option<(i64, i64)> {
        let rest = file_name.strip_prefix(prefix)?;
        let parts: Vec<&str> = rest.split('-').collect();
        if !(1..=2).contains(&parts.len()) {
            return None;
        }
        let stamp = parts[0].parse().ok()?;
        match parts.get(1) {
            None => Some((stamp, 0)),
            Some(n) => Some((stamp, n.parse().ok()?)),
        }
    }

    pub(crate) fn names_in(dir: &Path) -> Vec<String> {
        std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect()
    }

    /// Moves the damaged file aside as `<name>.corrupt-<unix seconds>[-n]` and prunes old backups.
    pub(crate) fn backup_corrupt(path: &Path, now: Timestamp) -> Result<(), LibraryStoreError> {
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        let file_name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let prefix = format!("{file_name}.corrupt-");
        let stamp = now.unix_seconds().floor() as i64;
        // Next free counter for this second: max existing + 1, so pruning never frees a lower name that would sort as oldest.
        let used: Vec<(i64, i64)> =
            names_in(dir).iter().filter_map(|n| order_of(n, &prefix)).filter(|o| o.0 == stamp).collect();
        let mut name = format!("{prefix}{stamp}");
        if !used.is_empty() {
            name.push_str(&format!("-{}", used.iter().map(|o| o.1).max().unwrap_or(0) + 1));
        }
        std::fs::rename(path, dir.join(name))?;
        prune_corrupt_backups(path);
        Ok(())
    }

    /// Keeps the newest `CORRUPT_BACKUPS_TO_KEEP` backups of this file name (by name stamp, then counter); siblings of
    /// other names are untouched.
    pub(crate) fn prune_corrupt_backups(path: &Path) {
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        let file_name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let prefix = format!("{file_name}.corrupt-");
        let mut backups: Vec<(String, (i64, i64))> =
            names_in(dir).into_iter().filter_map(|n| order_of(&n, &prefix).map(|o| (n, o))).collect();
        backups.sort_by_key(|b| std::cmp::Reverse(b.1));
        for (name, _) in backups.iter().skip(CORRUPT_BACKUPS_TO_KEEP) {
            let _ = std::fs::remove_file(dir.join(name));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use sq_core_time::Id;

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn id(folder: u64, path: &str) -> LibraryEntryID {
        LibraryEntryID { folder_id: Id::fixed(folder), relative_path: path.into() }
    }

    fn backups(dir: &TempDir, name: &str) -> Vec<String> {
        let prefix = format!("{name}.corrupt-");
        let mut names: Vec<String> = json_file_io::names_in(dir.path());
        names.retain(|n| n.starts_with(&prefix));
        names
    }

    #[test]
    fn toggle_and_contains() {
        let mut f = Favorites::default();
        let id1 = id(1, "a.mov");
        assert!(!f.contains(&id1));
        assert!(f.toggle(id1.clone()));
        assert!(f.contains(&id1));
        assert!(!f.toggle(id1));
        assert!(f.ids().is_empty());
    }

    #[test]
    fn persistence_round_trip_and_deterministic_output() {
        let dir = TempDir::new();
        let path = dir.path().join("sub/favorites.json");
        let mut f = Favorites::default();
        f.add(id(1, "a.mov"));
        f.add(id(2, "b/c.wav"));
        assert!(FavoritesStore::save(&f, &path).is_ok());
        assert_eq!(FavoritesStore::load(&path, NOW), Ok(f.clone()));
        let first = std::fs::read(&path).unwrap_or_default();
        assert!(FavoritesStore::save(&f, &path).is_ok());
        assert_eq!(std::fs::read(&path).unwrap_or_default(), first);
        assert!(String::from_utf8_lossy(&first).contains("\"formatVersion\" : 1"));
    }

    #[test]
    fn missing_file_is_empty() {
        let dir = TempDir::new();
        let loaded = FavoritesStore::load(&dir.path().join("none.json"), NOW);
        assert_eq!(loaded, Ok(Favorites::default()));
    }

    #[test]
    fn newer_version_fails() {
        let dir = TempDir::new();
        let path = dir.path().join("f.json");
        let _ = std::fs::write(&path, br#"{"formatVersion":99,"items":[]}"#);
        assert_eq!(FavoritesStore::load(&path, NOW), Err(LibraryStoreError::NewerFormat { found: 99, supported: 1 }));
        assert!(path.exists());
    }

    #[test]
    fn corrupt_file_is_backed_up_and_empty() {
        let dir = TempDir::new();
        let path = dir.path().join("f.json");
        let _ = std::fs::write(&path, b"not json");
        assert_eq!(FavoritesStore::load(&path, NOW), Ok(Favorites::default()));
        assert_eq!(backups(&dir, "f.json").len(), 1);
    }

    #[test]
    fn keeps_only_three_newest_backups() {
        let dir = TempDir::new();
        let path = dir.path().join("f.json");
        for i in 1..=5 {
            let _ = std::fs::write(&path, format!("bad{i}"));
            assert!(json_file_io::backup_corrupt(&path, NOW).is_ok());
        }
        let names = backups(&dir, "f.json");
        assert_eq!(names.len(), 3);
        let mut contents: Vec<String> =
            names.iter().map(|n| std::fs::read_to_string(dir.path().join(n)).unwrap_or_default()).collect();
        contents.sort();
        assert_eq!(contents, ["bad3", "bad4", "bad5"]);
    }

    #[test]
    fn other_file_names_are_untouched() {
        let dir = TempDir::new();
        for i in 0..5 {
            dir.write(&format!("g.json.corrupt-{}", 100 + i), 4);
        }
        let path = dir.path().join("f.json");
        for _ in 1..=5 {
            let _ = std::fs::write(&path, b"bad");
            assert!(json_file_io::backup_corrupt(&path, NOW).is_ok());
        }
        assert_eq!(backups(&dir, "g.json").len(), 5);
        assert_eq!(backups(&dir, "f.json").len(), 3);
    }
}
