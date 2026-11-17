// Swift: LibraryIndex.swift
//! In-memory index of watched folders: snapshots, offline state, incremental rescans.
//!
//! Swift: an `actor` fed by watcher callbacks and an `AsyncStream` of updates. Here: a plain struct. The watcher callback
//! only records the folder id; the owner calls `process_changes` (once per frame or after a wake-up) and reads the
//! updates from a channel. `version` counts every change of the index, so views can poll it.

use crate::folder_scanner::{FolderScanResult, FolderScanner};
use crate::folder_watching::{FolderWatchToken, FolderWatching};
use crate::watched_folder::{LibraryDiff, LibraryEntry, WatchedFolder};
use sq_core_time::Id;
use std::collections::HashMap;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

/// Whether the folder could be read at the last scan.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FolderState {
    /// Read.
    Online,
    /// Missing or unmounted.
    Offline,
}

/// What a scan of one folder changed.
#[derive(Clone, Debug, PartialEq)]
pub struct LibraryUpdate {
    /// The folder.
    pub folder_id: Id,
    /// State after the scan.
    pub state: FolderState,
    /// Difference to the previous snapshot.
    pub diff: LibraryDiff,
}

/// In-memory index of watched folders.
pub struct LibraryIndex {
    scanner: FolderScanner,
    watcher: Box<dyn FolderWatching>,
    folder_list: Vec<WatchedFolder>,
    snapshots: HashMap<Id, Vec<LibraryEntry>>,
    states: HashMap<Id, FolderState>,
    tokens: HashMap<Id, Box<dyn FolderWatchToken>>,
    subscribers: Vec<Sender<LibraryUpdate>>,
    /// Folder ids the watcher reported since the last `process_changes`.
    pending: Arc<Mutex<Vec<Id>>>,
    version: u64,
}

impl LibraryIndex {
    /// An index without folders.
    pub fn new(scanner: FolderScanner, watcher: Box<dyn FolderWatching>) -> LibraryIndex {
        LibraryIndex {
            scanner,
            watcher,
            folder_list: Vec::new(),
            snapshots: HashMap::new(),
            states: HashMap::new(),
            tokens: HashMap::new(),
            subscribers: Vec::new(),
            pending: Arc::new(Mutex::new(Vec::new())),
            version: 0,
        }
    }

    /// Counts every change of folders, snapshots or states.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The folders in the order they were added.
    pub fn folders(&self) -> &[WatchedFolder] {
        &self.folder_list
    }

    /// State at the last scan.
    pub fn state(&self, id: Id) -> Option<FolderState> {
        self.states.get(&id).copied()
    }

    /// Snapshot of one folder.
    pub fn entries(&self, id: Id) -> &[LibraryEntry] {
        self.snapshots.get(&id).map_or(&[], Vec::as_slice)
    }

    /// Adds (or replaces) a folder, scans it and starts watching.
    pub fn add(&mut self, folder: WatchedFolder) -> LibraryUpdate {
        match self.folder_list.iter().position(|f| f.id == folder.id) {
            Some(i) => self.folder_list[i] = folder.clone(),
            None => self.folder_list.push(folder.clone()),
        }
        if let Some(old) = self.tokens.remove(&folder.id) {
            old.cancel();
        }
        let (id, pending) = (folder.id, Arc::clone(&self.pending));
        let token = self.watcher.watch(
            &folder.url,
            Arc::new(move || pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(id)),
        );
        self.tokens.insert(id, token);
        self.rescan_now(&folder)
    }

    /// Forgets a folder and stops watching it.
    pub fn remove(&mut self, id: Id) {
        if let Some(token) = self.tokens.remove(&id) {
            token.cancel();
        }
        self.folder_list.retain(|f| f.id != id);
        self.snapshots.remove(&id);
        self.states.remove(&id);
        self.version += 1;
    }

    /// Scans a folder now; `None` for an unknown id.
    pub fn rescan(&mut self, id: Id) -> Option<LibraryUpdate> {
        let folder = self.folder_list.iter().find(|f| f.id == id)?.clone();
        Some(self.rescan_now(&folder))
    }

    /// Updates produced by `process_changes` (non-empty diffs or state changes). Each call is an independent stream.
    pub fn updates(&mut self) -> Receiver<LibraryUpdate> {
        let (tx, rx) = channel();
        self.subscribers.push(tx);
        rx
    }

    /// Rescans the folders the watcher reported and sends the resulting updates to every subscriber.
    pub fn process_changes(&mut self) {
        let ids: Vec<Id> = std::mem::take(&mut *self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        for id in ids {
            self.handle_change(id);
        }
    }

    fn handle_change(&mut self, id: Id) {
        let Some(folder) = self.folder_list.iter().find(|f| f.id == id).cloned() else { return };
        let before = self.states.get(&id).copied();
        let update = self.rescan_now(&folder);
        if update.diff.is_empty() && before == Some(update.state) {
            return;
        }
        // A receiver that was dropped ends its stream.
        self.subscribers.retain(|s| s.send(update.clone()).is_ok());
    }

    fn rescan_now(&mut self, folder: &WatchedFolder) -> LibraryUpdate {
        self.version += 1;
        match self.scanner.scan(folder) {
            FolderScanResult::Offline => {
                // Keep the last snapshot so nothing is reported as removed.
                self.states.insert(folder.id, FolderState::Offline);
                LibraryUpdate { folder_id: folder.id, state: FolderState::Offline, diff: LibraryDiff::empty() }
            }
            FolderScanResult::Online(entries) => {
                let diff = LibraryDiff::between(self.entries(folder.id), &entries);
                self.snapshots.insert(folder.id, entries);
                self.states.insert(folder.id, FolderState::Online);
                LibraryUpdate { folder_id: folder.id, state: FolderState::Online, diff }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use crate::folder_watching::FakeFolderWatcher;

    /// The index owns its watcher, so the tests keep a second handle to fire events.
    struct Shared(Arc<FakeFolderWatcher>);
    impl FolderWatching for Shared {
        fn watch(
            &self,
            path: &std::path::Path,
            f: crate::folder_watching::ChangeCallback,
        ) -> Box<dyn FolderWatchToken> {
            self.0.watch(path, f)
        }
    }

    fn setup(dir: &TempDir) -> (LibraryIndex, Arc<FakeFolderWatcher>, WatchedFolder) {
        let watcher = Arc::new(FakeFolderWatcher::new());
        let index = LibraryIndex::new(FolderScanner::default(), Box::new(Shared(Arc::clone(&watcher))));
        (index, watcher, WatchedFolder::new(Id::fixed(1), dir.path().to_path_buf(), None, None))
    }

    fn added(u: &LibraryUpdate) -> Vec<&str> {
        u.diff.added.iter().map(|e| e.relative_path.as_str()).collect()
    }

    #[test]
    fn rescan_reports_diff_and_offline_keeps_snapshot() {
        let dir = TempDir::new();
        let (mut index, _w, folder) = setup(&dir);
        dir.write("a.mp4", 4);
        assert_eq!(index.add(folder.clone()).diff.added.len(), 1);
        assert_eq!(index.state(folder.id), Some(FolderState::Online));
        dir.write("b.wav", 4);
        assert_eq!(index.rescan(folder.id).as_ref().map(added), Some(vec!["b.wav"]));
        assert_eq!(index.entries(folder.id).len(), 2);
        dir.remove();
        assert!(index.rescan(folder.id).is_some_and(|u| u.diff.is_empty()));
        assert_eq!(index.state(folder.id), Some(FolderState::Offline));
        assert_eq!(index.entries(folder.id).len(), 2);
        assert_eq!(index.rescan(Id::fixed(99)), None);
    }

    #[test]
    fn watcher_event_triggers_rescan() {
        let dir = TempDir::new();
        let (mut index, watcher, folder) = setup(&dir);
        index.add(folder.clone());
        let updates = index.updates();
        dir.write("new.mp4", 4);
        watcher.fire(dir.path());
        assert!(updates.try_recv().is_err());
        let before = index.version();
        index.process_changes();
        assert!(index.version() > before);
        let update = updates.try_recv().ok();
        assert_eq!(update.as_ref().map(|u| u.folder_id), Some(folder.id));
        assert_eq!(update.as_ref().map(added), Some(vec!["new.mp4"]));
        index.process_changes();
        assert!(updates.try_recv().is_err());
    }

    #[test]
    fn remove_stops_watching() {
        let dir = TempDir::new();
        let (mut index, watcher, folder) = setup(&dir);
        index.add(folder.clone());
        assert_eq!(watcher.active_count(), 1);
        index.remove(folder.id);
        assert_eq!(watcher.active_count(), 0);
        assert!(index.folders().is_empty());
    }
}
