// Swift: MediaFileStamp.swift
//! Size and modification time of a media file, and a tracker that reports files that changed.

use sq_core_time::Timestamp;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

/// Size and modification time of a media file. A change means the file grew (capture in progress) or was
/// re-rendered over the same path, so the item must be refreshed (FILMCRAFT-PRS #625).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MediaFileStamp {
    /// Size in bytes.
    pub size: i64,
    /// Last content change.
    pub modified: Timestamp,
}

impl MediaFileStamp {
    /// `None` when the file is missing or unreadable.
    pub fn read(path: &Path) -> Option<MediaFileStamp> {
        let meta = std::fs::symlink_metadata(path).ok()?;
        let since_epoch = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
        Some(MediaFileStamp {
            size: i64::try_from(meta.len()).ok()?,
            modified: Timestamp::from_unix_seconds(since_epoch.as_secs_f64()),
        })
    }
}

/// Reads the stamp of a path (the file system, or a test double).
pub type StampReader = Box<dyn Fn(&Path) -> Option<MediaFileStamp> + Send>;

/// Remembers the stamp of each tracked file; `poll()` returns the paths whose stamp changed since the last
/// poll. A file that disappears or reappears counts as changed once (relink handles the rest).
/// Plain value type: the caller drives it from a timer and owns the interval and the on/off preference.
pub struct MediaFileStampTracker {
    stamps: HashMap<PathBuf, Option<MediaFileStamp>>,
    reader: StampReader,
}

impl MediaFileStampTracker {
    /// Reads stamps from the file system.
    pub fn new() -> MediaFileStampTracker {
        Self::with_reader(Box::new(MediaFileStamp::read))
    }

    /// Reads stamps through `reader` (a test or another storage).
    pub fn with_reader(reader: StampReader) -> MediaFileStampTracker {
        MediaFileStampTracker { stamps: HashMap::new(), reader }
    }

    /// The tracked paths.
    pub fn tracked(&self) -> BTreeSet<PathBuf> {
        self.stamps.keys().cloned().collect()
    }

    /// Starts tracking `path` with its current stamp (no change reported for it).
    pub fn track(&mut self, path: &Path) {
        if !self.stamps.contains_key(path) {
            let stamp = (self.reader)(path);
            self.stamps.insert(path.to_path_buf(), stamp);
        }
    }

    /// Replaces the tracked set: adds new paths, drops the ones no longer present.
    pub fn set_tracked<'a>(&mut self, paths: impl IntoIterator<Item = &'a Path>) {
        let wanted: BTreeSet<&Path> = paths.into_iter().collect();
        self.stamps.retain(|p, _| wanted.contains(p.as_path()));
        for p in wanted {
            self.track(p);
        }
    }

    /// Paths whose stamp differs from the remembered one, sorted by path; remembered stamps are updated.
    pub fn poll(&mut self) -> Vec<PathBuf> {
        let mut changed = Vec::new();
        for (path, old) in &mut self.stamps {
            let now = (self.reader)(path);
            if now != *old {
                *old = now;
                changed.push(path.clone());
            }
        }
        changed.sort();
        changed
    }
}

impl Default for MediaFileStampTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use std::io::Write;
    use std::time::{Duration, SystemTime};

    #[test]
    fn unchanged_file_is_not_reported() {
        let dir = TempDir::new();
        let url = dir.write("a.mov", 10);
        let mut tracker = MediaFileStampTracker::new();
        tracker.track(&url);
        assert!(tracker.poll().is_empty());
    }

    #[test]
    fn growing_file_is_reported_once() {
        let dir = TempDir::new();
        let url = dir.write("a.mov", 10);
        let mut tracker = MediaFileStampTracker::new();
        tracker.track(&url);
        let mut f = std::fs::OpenOptions::new().append(true).open(&url).unwrap_or_else(|e| panic!("{e}"));
        let _ = f.write_all(&[0; 100]);
        drop(f);
        assert_eq!(tracker.poll(), vec![url]);
        assert!(tracker.poll().is_empty());
    }

    #[test]
    fn re_render_with_same_size_changes_modification_date() {
        let dir = TempDir::new();
        let url = dir.write("a.mov", 10);
        let mut tracker = MediaFileStampTracker::new();
        tracker.track(&url);
        dir.set_modified(&url, SystemTime::now() + Duration::from_secs(60));
        assert_eq!(tracker.poll(), vec![url]);
    }

    #[test]
    fn missing_then_reappearing_is_reported() {
        let dir = TempDir::new();
        let url = dir.write("a.mov", 10);
        let mut tracker = MediaFileStampTracker::new();
        tracker.track(&url);
        let _ = std::fs::remove_file(&url);
        assert_eq!(tracker.poll(), vec![url.clone()]);
        assert!(tracker.poll().is_empty());
        dir.write("a.mov", 5);
        assert_eq!(tracker.poll(), vec![url]);
    }

    #[test]
    fn set_tracked_adds_and_drops() {
        let (a, b) = (Path::new("/a.mov"), Path::new("/b.mov"));
        let mut tracker = MediaFileStampTracker::with_reader(Box::new(|_| None));
        tracker.set_tracked([a]);
        tracker.set_tracked([b]);
        assert_eq!(tracker.tracked(), BTreeSet::from([b.to_path_buf()]));
    }

    #[test]
    fn tracked_missing_file_does_not_report_at_start() {
        let mut tracker = MediaFileStampTracker::with_reader(Box::new(|_| None));
        tracker.track(Path::new("/gone.mov"));
        assert!(tracker.poll().is_empty());
    }
}
