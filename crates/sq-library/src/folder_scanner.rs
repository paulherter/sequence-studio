// Swift: FolderScanner.swift
//! Recursive scan of a watched folder.

use crate::library_item_kind::LibraryItemKind;
use crate::watched_folder::{DISTANT_PAST, LibraryEntry, WatchedFolder, standardized_path};
use sq_core_project::file_walk::{self, Step, Values};

/// What a scan found.
#[derive(Clone, Debug, PartialEq)]
pub enum FolderScanResult {
    /// The folder was read.
    Online(Vec<LibraryEntry>),
    /// Folder missing, unmounted or not a directory. Not an error.
    Offline,
}

/// Scans watched folders.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FolderScanner {
    /// Directories deeper than this are not entered.
    pub max_depth: usize,
    /// The scan stops at this many entries. The walk never follows links to directories, so link loops cannot recurse.
    pub max_entries: usize,
}

impl Default for FolderScanner {
    fn default() -> Self {
        FolderScanner { max_depth: 24, max_entries: 100_000 }
    }
}

impl FolderScanner {
    /// Recursive scan; hidden and system files are skipped.
    // shortcut: no cancellation hook (Swift stops on `Task.isCancelled`); add a `&dyn Fn() -> bool` when a scan runs
    // on a worker the UI can abandon.
    pub fn scan(&self, folder: &WatchedFolder) -> FolderScanResult {
        if !folder.url.is_dir() {
            return FolderScanResult::Offline;
        }
        let base = standardized_path(&folder.url);
        let resolved_base =
            sq_os::paths::canonical(&folder.url).map_or_else(|_| base.clone(), |p| standardized_path(&p));
        let mut entries: Vec<LibraryEntry> = Vec::new();
        file_walk::walk(&folder.url, &mut |url, v, level| {
            if entries.len() >= self.max_entries {
                return Step::Stop;
            }
            // level 1 = direct children of the folder; a directory at level max_depth is not entered.
            let next = if level >= self.max_depth { Step::Skip } else { Step::Descend };
            let Some(mut values) = v.copied() else { return next };
            let Some(kind) = LibraryItemKind::classify_if_visible(url, false) else { return next };
            if values.is_symbolic_link == Some(true) {
                // A link to a file inside the folder is listed under its own (unresolved) path; the file
                // attributes come from the target. Links pointing outside the folder are skipped.
                let Ok(target) = sq_os::paths::canonical(url) else { return next };
                if !standardized_path(&target).starts_with(&format!("{resolved_base}/")) {
                    return next;
                }
                let Some(tv) = Values::read(&target) else { return next };
                values = tv;
            }
            if values.is_regular_file != Some(true) {
                return next;
            }
            let full = standardized_path(url);
            let Some(relative) = full.strip_prefix(&format!("{base}/")) else { return next };
            entries.push(LibraryEntry {
                folder_id: folder.id,
                relative_path: relative.to_string(),
                kind,
                size: values.file_size.unwrap_or(0),
                modified: values.content_modification_date.unwrap_or(DISTANT_PAST),
            });
            next
        });
        entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
        FolderScanResult::Online(entries)
    }
}

/// Temporary folders for the file system tests of this crate.
#[cfg(test)]
pub(crate) mod test_dir {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::SystemTime;

    /// A fresh folder below the system temp directory, removed on drop.
    pub(crate) struct TempDir(PathBuf);

    impl TempDir {
        pub(crate) fn new() -> TempDir {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let dir = std::env::temp_dir().join(format!(
                "sq-library-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::create_dir_all(&dir);
            TempDir(dir)
        }

        pub(crate) fn path(&self) -> &Path {
            &self.0
        }

        /// Writes `bytes` bytes of 1 to `relative` (folders are made) and returns the full path.
        pub(crate) fn write(&self, relative: &str, bytes: usize) -> PathBuf {
            let file = self.0.join(relative);
            if let Some(parent) = file.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(&file, vec![1u8; bytes]);
            file
        }

        pub(crate) fn set_modified(&self, file: &Path, when: SystemTime) {
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open(file) {
                let _ = f.set_modified(when);
            }
        }

        pub(crate) fn remove(&self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            self.remove();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_dir::TempDir;
    use super::*;
    use sq_core_time::Id;
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    fn folder(url: PathBuf) -> WatchedFolder {
        WatchedFolder::new(Id::fixed(1), url, None, None)
    }

    fn online(scanner: &FolderScanner, dir: &TempDir) -> Vec<LibraryEntry> {
        match scanner.scan(&folder(dir.path().to_path_buf())) {
            FolderScanResult::Online(e) => e,
            FolderScanResult::Offline => panic!("offline"),
        }
    }

    fn paths(entries: &[LibraryEntry]) -> Vec<&str> {
        entries.iter().map(|e| e.relative_path.as_str()).collect()
    }

    #[test]
    fn scans_recursively_and_skips_hidden() {
        let dir = TempDir::new();
        dir.write("a.mp4", 10);
        dir.write("sub/deep/b.WAV", 20);
        dir.write(".DS_Store", 4);
        dir.write(".hiddenDir/c.mp4", 4);
        dir.write("sub/look.cube", 4);
        let entries = online(&FolderScanner::default(), &dir);
        let set: BTreeSet<&str> = paths(&entries).into_iter().collect();
        assert_eq!(set, BTreeSet::from(["a.mp4", "sub/deep/b.WAV", "sub/look.cube"]));
        let by = |p: &str| entries.iter().find(|e| e.relative_path == p);
        assert_eq!(by("a.mp4").map(|e| (e.kind, e.size)), Some((LibraryItemKind::Video, 10)));
        assert_eq!(by("sub/deep/b.WAV").map(|e| e.kind), Some(LibraryItemKind::Audio));
        assert_eq!(by("sub/look.cube").map(|e| e.kind), Some(LibraryItemKind::Lut));
        assert_eq!(by("a.mp4").map(|e| e.folder_id), Some(Id::fixed(1)));
    }

    #[cfg(unix)]
    #[test]
    fn symlink_and_target_get_distinct_ids() {
        let dir = TempDir::new();
        let target = dir.write("real.mp4", 10);
        let _ = std::os::unix::fs::symlink(&target, dir.path().join("link.mp4"));
        let entries = online(&FolderScanner::default(), &dir);
        assert_eq!(paths(&entries), ["link.mp4", "real.mp4"]);
        assert_eq!(entries.iter().map(LibraryEntry::id).collect::<std::collections::HashSet<_>>().len(), 2);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_directory_loop_terminates() {
        let dir = TempDir::new();
        dir.write("Cat/a.wav", 4);
        let _ = std::os::unix::fs::symlink(dir.path(), dir.path().join("Cat/loop"));
        assert_eq!(paths(&online(&FolderScanner::default(), &dir)), ["Cat/a.wav"]);
    }

    #[test]
    fn missing_folder_is_offline_not_error() {
        let f = folder(PathBuf::from("/nonexistent-sq-library-test"));
        assert_eq!(FolderScanner::default().scan(&f), FolderScanResult::Offline);
    }

    #[test]
    fn file_instead_of_folder_is_offline() {
        let dir = TempDir::new();
        let f = dir.write("x.mp4", 4);
        assert_eq!(FolderScanner::default().scan(&folder(f)), FolderScanResult::Offline);
    }

    #[test]
    fn hidden_folders_and_files_are_skipped() {
        let dir = TempDir::new();
        dir.write("Cat/.secret/a.wav", 4);
        dir.write("Cat/.b.wav", 4);
        dir.write("Cat/ok.wav", 4);
        assert_eq!(paths(&online(&FolderScanner::default(), &dir)), ["Cat/ok.wav"]);
    }

    #[test]
    fn depth_guard_stops_descent() {
        let dir = TempDir::new();
        dir.write("a/b/c/d/deep.wav", 4);
        dir.write("a/near.wav", 4);
        let scanner = FolderScanner { max_depth: 3, ..FolderScanner::default() };
        assert_eq!(paths(&online(&scanner, &dir)), ["a/near.wav"]);
    }

    #[test]
    fn entry_limit_caps_result() {
        let dir = TempDir::new();
        for i in 0..30 {
            dir.write(&format!("c/f{i}.wav"), 1);
        }
        let scanner = FolderScanner { max_entries: 10, ..FolderScanner::default() };
        assert_eq!(online(&scanner, &dir).len(), 10);
    }

    #[test]
    fn five_thousand_files_scan() {
        let dir = TempDir::new();
        for i in 0..5000 {
            dir.write(&format!("c{}/f{i}.wav", i % 25), 1);
        }
        assert_eq!(online(&FolderScanner::default(), &dir).len(), 5000);
    }

    #[test]
    fn two_thousand_files_scan_fast() {
        let dir = TempDir::new();
        for d in 0..20 {
            for i in 0..100 {
                dir.write(&format!("sub{d}/s{i}.wav"), 1);
            }
        }
        let start = std::time::Instant::now();
        let entries = online(&FolderScanner::default(), &dir);
        assert!(start.elapsed().as_millis() < 3000);
        assert_eq!(entries.len(), 2000);
    }
}
