// Swift: WatchedFolder.swift
//! A folder the user added to the library, its entries and the difference between two scans.

use crate::library_item_kind::LibraryItemKind;
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Timestamp};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Swift `Date.distantPast`, the stand-in for a missing date.
pub(crate) const DISTANT_PAST: Timestamp = Timestamp::from_reference_seconds(-63_114_076_800.0);

/// A folder the user added to the library.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchedFolder {
    /// Identity.
    pub id: Id,
    /// Folder path, written like a Swift `URL`: `file:///...` text.
    #[serde(with = "file_url")]
    pub url: PathBuf,
    /// Shown name.
    pub display_name: String,
    /// Security-scoped bookmark (set by the app layer; opaque here).
    #[serde(default, skip_serializing_if = "Option::is_none", with = "sq_core_time::base64::option")]
    pub bookmark: Option<Vec<u8>>,
}

impl WatchedFolder {
    /// `display_name` defaults to the last path component.
    pub fn new(id: Id, url: PathBuf, display_name: Option<&str>, bookmark: Option<Vec<u8>>) -> WatchedFolder {
        let display_name = display_name.map_or_else(|| last_component(&url), str::to_string);
        WatchedFolder { id, url, display_name, bookmark }
    }
}

/// Stable entry id: folder id + path relative to the folder.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryEntryID {
    /// The folder the entry is in.
    #[serde(rename = "folderID")]
    pub folder_id: Id,
    /// Path below the folder, `/` separated.
    pub relative_path: String,
}

/// One file in a watched folder.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryEntry {
    /// The folder the entry is in.
    #[serde(rename = "folderID")]
    pub folder_id: Id,
    /// Path below the folder, `/` separated.
    pub relative_path: String,
    /// Kind by extension.
    pub kind: LibraryItemKind,
    /// Size in bytes.
    pub size: i64,
    /// Last content change.
    pub modified: Timestamp,
}

impl LibraryEntry {
    /// Folder id and relative path.
    pub fn id(&self) -> LibraryEntryID {
        LibraryEntryID { folder_id: self.folder_id, relative_path: self.relative_path.clone() }
    }

    /// File name without the folders.
    pub fn name(&self) -> &str {
        self.relative_path.rsplit('/').next().unwrap_or("")
    }

    /// Full path of the file.
    pub fn url(&self, folder: &WatchedFolder) -> PathBuf {
        folder.url.join(&self.relative_path)
    }
}

/// Difference between two snapshots of one folder.
#[derive(Clone, Debug, PartialEq)]
pub struct LibraryDiff {
    /// In the new snapshot only.
    pub added: Vec<LibraryEntry>,
    /// In the old snapshot only.
    pub removed: Vec<LibraryEntry>,
    /// In both, with other size, date or kind.
    pub changed: Vec<LibraryEntry>,
}

impl LibraryDiff {
    /// No difference.
    pub fn empty() -> LibraryDiff {
        LibraryDiff { added: vec![], removed: vec![], changed: vec![] }
    }

    /// Nothing added, removed or changed.
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.removed.is_empty() && self.changed.is_empty()
    }

    /// What differs between `old` and `new` (the first entry of a repeated id counts).
    pub fn between(old: &[LibraryEntry], new: &[LibraryEntry]) -> LibraryDiff {
        fn by_id(list: &[LibraryEntry]) -> HashMap<LibraryEntryID, &LibraryEntry> {
            let mut map = HashMap::new();
            for e in list {
                map.entry(e.id()).or_insert(e);
            }
            map
        }
        let (old_by_id, new_by_id) = (by_id(old), by_id(new));
        LibraryDiff {
            added: new.iter().filter(|e| !old_by_id.contains_key(&e.id())).cloned().collect(),
            removed: old.iter().filter(|e| !new_by_id.contains_key(&e.id())).cloned().collect(),
            changed: new.iter().filter(|e| old_by_id.get(&e.id()).is_some_and(|o| *o != *e)).cloned().collect(),
        }
    }
}

/// Last path component as text ("" for a root).
pub(crate) fn last_component(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Swift `standardizedFileURL.path`: `.` and `..` resolved by text, no trailing slash, `/` separators.
pub(crate) fn standardized_path(path: &Path) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut prefix = String::new();
    for c in path.components() {
        use std::path::Component::{CurDir, Normal, ParentDir, Prefix, RootDir};
        match c {
            Prefix(p) => prefix = p.as_os_str().to_string_lossy().into_owned(),
            RootDir => prefix.push('/'),
            CurDir => {}
            ParentDir => {
                parts.pop();
            }
            Normal(n) => parts.push(n.to_string_lossy().into_owned()),
        }
    }
    format!("{prefix}{}", parts.join("/"))
}

/// Swift `URL` coding of a file path: `file://` plus the percent-encoded path. Reading also accepts a plain path.
pub(crate) mod file_url {
    use serde::{Deserialize, Deserializer, Serializer};
    use std::path::{Path, PathBuf};

    pub(crate) fn serialize<S: Serializer>(path: &Path, s: S) -> Result<S::Ok, S::Error> {
        let text = path.to_string_lossy().replace('\\', "/");
        let mut out = String::from("file://");
        if !text.starts_with('/') {
            out.push('/');
        }
        for b in text.bytes() {
            if b.is_ascii_alphanumeric() || b"-._~/:@!$&'()*+,;=".contains(&b) {
                out.push(char::from(b));
            } else {
                out.push_str(&format!("%{b:02X}"));
            }
        }
        s.serialize_str(&out)
    }

    pub(crate) fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<PathBuf, D::Error> {
        let text = <std::borrow::Cow<'de, str>>::deserialize(d)?;
        let Some(rest) = text.strip_prefix("file://") else { return Ok(PathBuf::from(text.as_ref())) };
        let rest = rest.strip_prefix("localhost").unwrap_or(rest);
        let (bytes, mut out, mut i) = (rest.as_bytes(), Vec::with_capacity(rest.len()), 0);
        while i < bytes.len() {
            let hex = (bytes[i] == b'%' && i + 2 < bytes.len())
                .then(|| std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()))
                .flatten();
            match hex {
                Some(b) => {
                    out.push(b);
                    i += 3;
                }
                None => {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
        }
        let decoded = String::from_utf8_lossy(&out).into_owned();
        let trimmed = if decoded.len() > 1 { decoded.trim_end_matches('/') } else { decoded.as_str() };
        // `/C:/Footage` is a Windows drive path.
        let b = trimmed.as_bytes();
        let path = if b.len() >= 3 && b[0] == b'/' && b[1].is_ascii_alphabetic() && b[2] == b':' {
            &trimmed[1..]
        } else {
            trimmed
        };
        Ok(PathBuf::from(path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str, size: i64) -> LibraryEntry {
        LibraryEntry {
            folder_id: Id::fixed(1),
            relative_path: path.into(),
            kind: LibraryItemKind::Audio,
            size,
            modified: DISTANT_PAST,
        }
    }

    #[test]
    fn folder_json_uses_file_urls_and_round_trips() {
        let f = WatchedFolder::new(Id::fixed(7), PathBuf::from("/Volumes/News Room/Sounds"), None, Some(vec![1, 2, 3]));
        assert_eq!(f.display_name, "Sounds");
        let json = serde_json::to_string(&f).unwrap_or_default();
        assert!(json.contains("\"url\":\"file:///Volumes/News%20Room/Sounds\""), "{json}");
        assert!(json.contains("\"bookmark\":\"AQID\""), "{json}");
        let back: WatchedFolder = serde_json::from_str(&json).unwrap_or_else(|_| f.clone());
        assert_eq!(back, f);
        let swift = r#"{"id":"00000000-0000-0000-0000-000000000007","url":"file:///tmp/gfx/","displayName":"gfx"}"#;
        let read: WatchedFolder = serde_json::from_str(swift).unwrap_or_else(|_| f.clone());
        assert_eq!(read.url, PathBuf::from("/tmp/gfx"));
    }

    #[test]
    fn diff_lists_added_removed_and_changed() {
        let old = [entry("a.wav", 1), entry("b.wav", 1), entry("c.wav", 1)];
        let new = [entry("b.wav", 2), entry("c.wav", 1), entry("d.wav", 1)];
        let d = LibraryDiff::between(&old, &new);
        assert_eq!(d.added, vec![entry("d.wav", 1)]);
        assert_eq!(d.removed, vec![entry("a.wav", 1)]);
        assert_eq!(d.changed, vec![entry("b.wav", 2)]);
        assert!(LibraryDiff::between(&old, &old).is_empty());
    }

    #[test]
    fn entry_name_and_url() {
        let e = entry("Calm/a.wav", 1);
        assert_eq!(e.name(), "a.wav");
        let f = WatchedFolder::new(Id::fixed(1), PathBuf::from("/m"), None, None);
        assert_eq!(e.url(&f), PathBuf::from("/m/Calm/a.wav"));
    }

    #[test]
    fn standardized_path_resolves_dots() {
        assert_eq!(standardized_path(Path::new("/a/./b/../c/")), "/a/c");
    }
}
