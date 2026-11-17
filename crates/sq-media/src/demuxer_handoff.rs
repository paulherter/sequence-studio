//! Port of `SQMedia/Sources/SQMedia/DemuxerHandoff.swift`.

use crate::demuxing::Demuxing;
use sq_core_time::Timestamp;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::SystemTime;

/// Hands the demuxer `MediaImporter.probe` built (a full sample-table walk) to the first open of the same file right after
/// import (`ProjectMediaResolver.openDemuxer`), so a freshly imported file is not walked twice (docs/PLAYBACK-PERF.md
/// "Import speed"). Demuxers are immutable after init, so sharing one is safe. Keyed by path + size + modification date
/// (a file changed in between is opened anew); each entry is taken once, expires after `LIFETIME`, and at most `CAPACITY`
/// demuxers / `SAMPLE_BUDGET` index entries are held (oldest dropped first; an hour of 60 fps is 216 000 entries, ~25 MB).
pub enum DemuxerHandoff {}

/// Identity of a file on disk: path, size and modification date.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Key {
    path: String,
    size: i64,
    modified: Option<SystemTime>,
}

struct Entry {
    key: Key,
    demuxer: Arc<dyn Demuxing>,
    stored: Timestamp,
}

static ENTRIES: Mutex<Vec<Entry>> = Mutex::new(Vec::new());
/// Off for before/after measurements (EngineBench `import-probe`).
static ENABLED: AtomicBool = AtomicBool::new(true);

fn entries() -> MutexGuard<'static, Vec<Entry>> {
    ENTRIES.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `path` without `.` components and made absolute (Swift's `standardizedFileURL.path`; symlinks are not resolved).
fn standardized(path: &Path) -> String {
    let abs: PathBuf = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    abs.to_string_lossy().into_owned()
}

fn expired(now: Timestamp, stored: Timestamp) -> bool {
    now.reference_seconds() - stored.reference_seconds() > DemuxerHandoff::LIFETIME
}

impl DemuxerHandoff {
    pub const LIFETIME: f64 = 120.0;
    pub const CAPACITY: usize = 64;
    pub const SAMPLE_BUDGET: usize = 1_000_000;

    pub fn is_enabled() -> bool {
        ENABLED.load(Ordering::Relaxed)
    }

    pub fn set_enabled(on: bool) {
        ENABLED.store(on, Ordering::Relaxed);
        if !on {
            entries().clear();
        }
    }

    pub fn key(url: &Path) -> Option<Key> {
        let a = std::fs::metadata(url).ok()?;
        Some(Key { path: standardized(url), size: i64::try_from(a.len()).unwrap_or(-1), modified: a.modified().ok() })
    }

    /// Keeps `demuxer` (built from `url`) for the next `take` of the same file.
    pub fn store(demuxer: Arc<dyn Demuxing>, url: &Path, pre_key: Option<Key>, now: Timestamp) {
        if !Self::is_enabled() {
            return;
        }
        let Some(k) = pre_key.or_else(|| Self::key(url)) else { return };
        let mut e = entries();
        e.retain(|x| !(expired(now, x.stored) || x.key.path == k.path));
        e.push(Entry { key: k, demuxer, stored: now });
        if e.len() > Self::CAPACITY {
            let extra = e.len() - Self::CAPACITY;
            e.drain(..extra);
        }
        let mut samples: usize = e.iter().map(|x| x.demuxer.index().count()).sum();
        while samples > Self::SAMPLE_BUDGET && !e.is_empty() {
            samples -= e[0].demuxer.index().count();
            e.remove(0);
        }
    }

    /// The demuxer stored for `url` if the file is unchanged and the entry not expired; removed either way.
    pub fn take(url: &Path, now: Timestamp) -> Option<Arc<dyn Demuxing>> {
        if !Self::is_enabled() {
            return None;
        }
        let path = standardized(url);
        let hit = {
            let mut e = entries();
            e.retain(|x| !expired(now, x.stored));
            let i = e.iter().position(|x| x.key.path == path)?;
            e.remove(i)
        };
        if Self::key(url).as_ref() == Some(&hit.key) { Some(hit.demuxer) } else { None }
    }

    /// Number of entries held (tests).
    #[doc(hidden)]
    pub fn count() -> usize {
        entries().len()
    }

    #[doc(hidden)]
    pub fn remove_all() {
        entries().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::demuxing::tests::FakeDemuxer;
    use std::sync::Mutex as TestLock;

    /// The handoff is process-wide state: tests that use it run one at a time (`.serialized` in Swift).
    static SERIAL: TestLock<()> = TestLock::new(());

    fn file(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("sq-handoff-{}-{name}", std::process::id()));
        std::fs::write(&p, b"clip").unwrap();
        p
    }

    fn at(seconds: f64) -> Timestamp {
        Timestamp::from_reference_seconds(seconds)
    }

    #[test]
    fn stored_demuxer_is_taken_once_for_the_same_file() {
        let _g = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        let url = file("once.mov");
        DemuxerHandoff::remove_all();
        DemuxerHandoff::store(Arc::new(FakeDemuxer::new(30)), &url, None, at(0.0));
        let d = DemuxerHandoff::take(&url, at(1.0)).unwrap();
        assert_eq!(d.index().count(), 30);
        assert!(DemuxerHandoff::take(&url, at(1.0)).is_none()); // taken once
    }

    #[test]
    fn changed_file_or_expired_entry_is_not_handed_out() {
        let _g = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        let url = file("changed.mov");
        DemuxerHandoff::remove_all();
        let d: Arc<dyn Demuxing> = Arc::new(FakeDemuxer::new(6));
        DemuxerHandoff::store(Arc::clone(&d), &url, None, at(0.0));
        std::fs::write(&url, b"a longer clip").unwrap(); // size differs since the probe
        assert!(DemuxerHandoff::take(&url, at(1.0)).is_none());
        std::fs::write(&url, b"clip").unwrap();
        DemuxerHandoff::store(Arc::clone(&d), &url, None, at(0.0));
        assert!(DemuxerHandoff::take(&url, at(DemuxerHandoff::LIFETIME + 1.0)).is_none()); // expired
        assert_eq!(DemuxerHandoff::count(), 0);
    }

    #[test]
    fn capacity_and_sample_budget_drop_the_oldest() {
        let _g = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        DemuxerHandoff::remove_all();
        let urls: Vec<PathBuf> = (0..3).map(|i| file(&format!("budget{i}.mov"))).collect();
        for (i, u) in urls.iter().enumerate() {
            DemuxerHandoff::store(Arc::new(FakeDemuxer::new(400_000)), u, None, at(i as f64));
        }
        // Three demuxers of 400 000 entries exceed the 1 000 000 budget: the first one is gone.
        assert_eq!(DemuxerHandoff::count(), 2);
        assert!(DemuxerHandoff::take(&urls[0], at(3.0)).is_none());
        assert!(DemuxerHandoff::take(&urls[2], at(3.0)).is_some());
        DemuxerHandoff::remove_all();
    }

    #[test]
    fn disabled_handoff_keeps_nothing() {
        let _g = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        let url = file("off.mov");
        DemuxerHandoff::remove_all();
        DemuxerHandoff::set_enabled(false);
        DemuxerHandoff::store(Arc::new(FakeDemuxer::new(3)), &url, None, at(0.0));
        DemuxerHandoff::set_enabled(true);
        assert_eq!(DemuxerHandoff::count(), 0);
        assert!(DemuxerHandoff::take(&url, at(0.0)).is_none());
    }
}
