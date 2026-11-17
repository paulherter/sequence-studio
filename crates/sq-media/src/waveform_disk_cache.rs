//! Port of `SQMedia/WaveformDiskCache.swift`: peaks of a media file kept on disk across launches, so reopening a
//! project draws its waveforms without decoding the audio again. Keyed by path, size, modification time, bucket size
//! and the format version: an edited or replaced file misses. Least recently used files go first beyond `limit_bytes`.

use crate::waveform_data::WaveformData;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Bumped when the peak builder changes what it produces (Swift `WaveformBuilder.peaksVersion`).
pub const PEAKS_VERSION: u32 = 1;

pub struct WaveformDiskCache {
    directory: PathBuf,
    limit_bytes: u64,
    stores_since_prune: AtomicUsize,
}

impl WaveformDiskCache {
    pub fn new(directory: PathBuf, limit_bytes: u64) -> WaveformDiskCache {
        WaveformDiskCache { directory, limit_bytes, stores_since_prune: AtomicUsize::new(0) }
    }

    /// The Swift default of one GiB at `directory`; `None` with `SQ_WAVEFORM_CACHE=0`.
    pub fn shared_at(directory: PathBuf) -> Option<WaveformDiskCache> {
        if std::env::var("SQ_WAVEFORM_CACHE").is_ok_and(|v| v == "0") {
            return None;
        }
        Some(WaveformDiskCache::new(directory, 1 << 30))
    }

    /// Cache file for `source`; `None` when the source cannot be read.
    pub fn file(&self, source: &Path, base_bucket_size: usize) -> Option<PathBuf> {
        self.file_mapped(source, base_bucket_size, None)
    }

    /// `channels`: the (left, right) channels of a clip's Audio Channels map; peaks of chosen channels are their own
    /// entry, `None` is the key every entry had before (Swift `file(url:baseBucketSize:channelMap:)`).
    pub fn file_mapped(
        &self,
        source: &Path,
        base_bucket_size: usize,
        channels: Option<(&[i64], &[i64])>,
    ) -> Option<PathBuf> {
        let meta = fs::metadata(source).ok()?;
        let nanos = meta.modified().ok()?.duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let mut text = format!(
            "{}|{}|{}|{}|v{}.{}",
            source.to_string_lossy(),
            meta.len(),
            nanos,
            base_bucket_size,
            PEAKS_VERSION,
            WaveformData::FORMAT_VERSION
        );
        if let Some((left, right)) = channels {
            let list = |c: &[i64]| c.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
            text.push_str(&format!("|L{}R{}", list(left), list(right)));
        }
        let mut h: u64 = 0xcbf29ce484222325; // FNV-1a 64 (stable across launches)
        for b in text.bytes() {
            h = (h ^ u64::from(b)).wrapping_mul(0x100000001b3);
        }
        Some(self.directory.join(format!("{h:016x}.sqwf")))
    }

    pub fn load(&self, source: &Path, base_bucket_size: usize) -> Option<WaveformData> {
        self.load_mapped(source, base_bucket_size, None)
    }

    pub fn load_mapped(
        &self,
        source: &Path,
        base_bucket_size: usize,
        channels: Option<(&[i64], &[i64])>,
    ) -> Option<WaveformData> {
        let file = self.file_mapped(source, base_bucket_size, channels)?;
        let wf = WaveformData::from_serialized(&fs::read(&file).ok()?).ok()?;
        if wf.base_bucket_size != base_bucket_size {
            return None;
        }
        // Last use, for pruning.
        if let Ok(f) = fs::File::options().write(true).open(&file) {
            let _ = f.set_modified(SystemTime::now());
        }
        Some(wf)
    }

    pub fn store(&self, wf: &WaveformData, source: &Path, base_bucket_size: usize) {
        self.store_mapped(wf, source, base_bucket_size, None);
    }

    pub fn store_mapped(
        &self,
        wf: &WaveformData,
        source: &Path,
        base_bucket_size: usize,
        channels: Option<(&[i64], &[i64])>,
    ) {
        let Some(file) = self.file_mapped(source, base_bucket_size, channels) else { return };
        if fs::create_dir_all(&self.directory).is_err() {
            return;
        }
        // Atomic: write beside, then rename, so a crash never leaves a torn entry.
        let tmp = file.with_extension("tmp");
        if fs::write(&tmp, wf.serialized()).is_err() || fs::rename(&tmp, &file).is_err() {
            let _ = fs::remove_file(&tmp);
            return;
        }
        if self.stores_since_prune.fetch_add(1, Ordering::Relaxed) + 1 >= 32 {
            self.stores_since_prune.store(0, Ordering::Relaxed);
            self.prune();
        }
    }

    /// Deletes the least recently used files until the folder fits the limit.
    pub fn prune(&self) {
        self.prune_to(self.limit_bytes);
    }

    pub fn prune_to(&self, limit: u64) {
        let Ok(dir) = fs::read_dir(&self.directory) else { return };
        let mut entries: Vec<(PathBuf, u64, SystemTime)> = dir
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "sqwf"))
            .filter_map(|e| {
                let m = e.metadata().ok()?;
                Some((e.path(), m.len(), m.modified().unwrap_or(UNIX_EPOCH)))
            })
            .collect();
        let mut total: u64 = entries.iter().map(|e| e.1).sum();
        if total <= limit {
            return;
        }
        entries.sort_by_key(|e| e.2);
        for (path, size, _) in entries {
            if total <= limit {
                break;
            }
            if fs::remove_file(path).is_ok() {
                total -= size;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sqwf-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn wave() -> WaveformData {
        WaveformData::new(48_000, 1, 1000, 256, vec![vec![-0.5, 0.5, -1.0, 1.0]])
    }

    #[test]
    fn a_stored_waveform_loads_back_and_a_changed_file_misses() {
        let dir = scratch("roundtrip");
        let media = dir.join("a.wav");
        fs::write(&media, b"one").unwrap();
        let cache = WaveformDiskCache::new(dir.join("cache"), 1 << 20);
        assert!(cache.load(&media, 256).is_none());
        cache.store(&wave(), &media, 256);
        assert_eq!(cache.load(&media, 256), Some(wave()));
        assert!(cache.load(&media, 512).is_none(), "another bucket size is its own entry");
        fs::write(&media, b"changed").unwrap();
        assert!(cache.load(&media, 256).is_none(), "size change invalidates");
        assert!(cache.load(&dir.join("missing.wav"), 256).is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_corrupt_entry_misses_and_pruning_drops_the_oldest() {
        let dir = scratch("prune");
        let cache = WaveformDiskCache::new(dir.join("cache"), 1 << 20);
        let (a, b) = (dir.join("a.wav"), dir.join("b.wav"));
        fs::write(&a, b"a").unwrap();
        fs::write(&b, b"bb").unwrap();
        cache.store(&wave(), &a, 256);
        cache.store(&wave(), &b, 256);
        let fa = cache.file(&a, 256).unwrap();
        fs::File::options().write(true).open(&fa).unwrap().set_modified(UNIX_EPOCH).unwrap();
        let one = fs::metadata(&fa).unwrap().len();
        cache.prune_to(one);
        assert!(!fa.exists(), "the oldest went first");
        assert!(cache.file(&b, 256).unwrap().exists());
        fs::write(cache.file(&b, 256).unwrap(), b"garbage").unwrap();
        assert!(cache.load(&b, 256).is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_channel_map_is_its_own_entry() {
        let dir = scratch("mapped");
        let media = dir.join("a.wav");
        fs::write(&media, b"one").unwrap();
        let cache = WaveformDiskCache::new(dir.join("cache"), 1 << 20);
        let map: Option<(&[i64], &[i64])> = Some((&[0], &[1]));
        cache.store_mapped(&wave(), &media, 256, map);
        assert_eq!(cache.load_mapped(&media, 256, map), Some(wave()));
        assert!(cache.load(&media, 256).is_none(), "the file's own mix is another entry");
        assert!(cache.load_mapped(&media, 256, Some((&[1], &[0]))).is_none(), "other channels, other entry");
        assert_ne!(cache.file_mapped(&media, 256, map), cache.file(&media, 256));
        let _ = fs::remove_dir_all(&dir);
    }
}
