// Swift: LibraryFolderStore.swift
//! The app-wide list of library folders, kept in the settings store (never in a project).

use crate::watched_folder::WatchedFolder;
use std::collections::HashMap;

/// Where small app settings are kept (user defaults on the Mac, a file or the registry elsewhere). The app implements it.
pub trait SettingsStore {
    /// The bytes stored under `key`.
    fn data(&self, key: &str) -> Option<Vec<u8>>;
    /// Stores `value` under `key`.
    fn set_data(&mut self, key: &str, value: Vec<u8>);
    /// Removes the value of `key`.
    fn remove(&mut self, key: &str);
}

/// A `SettingsStore` in memory (tests, and apps that persist elsewhere).
#[derive(Default)]
pub struct MemorySettings(HashMap<String, Vec<u8>>);

impl SettingsStore for MemorySettings {
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.0.get(key).cloned()
    }

    fn set_data(&mut self, key: &str, value: Vec<u8>) {
        self.0.insert(key.to_string(), value);
    }

    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}

/// The app-wide list of library folders. Every project shows the same list.
pub struct LibraryFolderStore;

impl LibraryFolderStore {
    /// Settings key of the list.
    pub const KEY: &'static str = "sq.library.folders";
    /// Key used before the list was named `sq.*`; read once, then moved.
    pub const LEGACY_KEY: &'static str = "library.watchedFolders";

    /// The saved folders; unreadable data reads as empty.
    pub fn load(settings: &mut dyn SettingsStore) -> Vec<WatchedFolder> {
        if let Some(data) = settings.data(Self::KEY) {
            return serde_json::from_slice(&data).unwrap_or_default();
        }
        let Some(old) = settings.data(Self::LEGACY_KEY) else { return Vec::new() };
        let folders = serde_json::from_slice(&old).unwrap_or_default();
        settings.set_data(Self::KEY, old);
        settings.remove(Self::LEGACY_KEY);
        folders
    }

    /// Saves the list.
    pub fn save(folders: &[WatchedFolder], settings: &mut dyn SettingsStore) {
        if let Ok(data) = serde_json::to_vec(folders) {
            settings.set_data(Self::KEY, data);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Id;
    use std::path::PathBuf;

    fn folder(path: &str) -> WatchedFolder {
        WatchedFolder::new(Id::fixed(1), PathBuf::from(path), None, None)
    }

    #[test]
    fn round_trip() {
        let mut d = MemorySettings::default();
        let f = folder("/Volumes/News/Sounds");
        LibraryFolderStore::save(std::slice::from_ref(&f), &mut d);
        assert_eq!(LibraryFolderStore::load(&mut d), vec![f]);
    }

    #[test]
    fn migrates_legacy_key() {
        let mut d = MemorySettings::default();
        let f = folder("/tmp/gfx");
        d.set_data(LibraryFolderStore::LEGACY_KEY, serde_json::to_vec(&[&f]).unwrap_or_default());
        assert_eq!(LibraryFolderStore::load(&mut d), vec![f]);
        assert!(d.data(LibraryFolderStore::LEGACY_KEY).is_none());
        assert!(d.data(LibraryFolderStore::KEY).is_some());
    }

    #[test]
    fn empty_and_corrupt() {
        let mut d = MemorySettings::default();
        assert!(LibraryFolderStore::load(&mut d).is_empty());
        d.set_data(LibraryFolderStore::KEY, vec![1, 2, 3]);
        assert!(LibraryFolderStore::load(&mut d).is_empty());
    }
}
