// Swift: Model.swift
//! Proxy kinds, source fingerprints, cache records and settings.

use serde::{Deserialize, Serialize};
use sq_core_time::sha256_digest;
use sq_core_time::{Time, Timestamp};
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;
use std::time::SystemTime;

/// Which proxy a file is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProxyKind {
    /// ProRes 422, source resolution.
    Optimized,
    /// ProRes 422 Proxy, 1/2 width and height.
    ProxyHalf,
    /// ProRes 422 Proxy, 1/4 width and height.
    ProxyQuarter,
}

impl ProxyKind {
    /// Swift `CaseIterable.allCases`.
    pub const ALL: [ProxyKind; 3] = [ProxyKind::Optimized, ProxyKind::ProxyHalf, ProxyKind::ProxyQuarter];

    /// The Swift raw value (used in cache file names).
    pub fn raw_value(self) -> &'static str {
        match self {
            ProxyKind::Optimized => "optimized",
            ProxyKind::ProxyHalf => "proxyHalf",
            ProxyKind::ProxyQuarter => "proxyQuarter",
        }
    }

    /// Integer divisor applied to width and height relative to the source.
    pub fn scale_divisor(self) -> i64 {
        match self {
            ProxyKind::Optimized => 1,
            ProxyKind::ProxyHalf => 2,
            ProxyKind::ProxyQuarter => 4,
        }
    }

    /// Codec FourCC of the video track written for this kind.
    pub fn codec_four_cc(self) -> &'static str {
        if self == ProxyKind::Optimized { "apcn" } else { "apco" }
    }
}

/// Width and height of a proxy picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProxyDimensions {
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
}

impl ProxyDimensions {
    /// Divides by `divisor`, rounding down to even numbers (minimum 2).
    pub fn scaled(&self, divisor: i64) -> ProxyDimensions {
        let even = |v: i64| ((v / divisor) & !1).max(2);
        ProxyDimensions { width: even(self.width), height: even(self.height) }
    }
}

/// Path-independent identity of a source file: size, mtime and a hash of its first and last 64 KB.
/// Only small chunks are read, so it is cheap for multi-GB files.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceFingerprint {
    /// File size in bytes.
    pub size: i64,
    /// Modification time in milliseconds since 1970.
    pub modified_millis: i64,
    /// SHA-256 hex of the first chunk.
    pub head_hash: String,
    /// SHA-256 hex of the last chunk (empty for files that fit in one chunk).
    pub tail_hash: String,
}

/// Modification time of `meta` in milliseconds since 1970, or `fallback_seconds` when the system does not tell.
pub(crate) fn modified_millis(meta: &fs::Metadata, fallback_seconds: f64) -> i64 {
    let seconds = match meta.modified() {
        Ok(t) => match t.duration_since(SystemTime::UNIX_EPOCH) {
            Ok(d) => d.as_secs_f64(),
            Err(e) => -e.duration().as_secs_f64(),
        },
        Err(_) => fallback_seconds,
    };
    // `as` saturates; file times are far inside the i64 range.
    (seconds * 1000.0).round() as i64
}

impl SourceFingerprint {
    /// Bytes read from the head and the tail.
    pub const CHUNK_SIZE: usize = 64 * 1024;

    /// Stable, file-name safe identifier.
    pub fn id(&self) -> String {
        let prefix = |s: &str| s.chars().take(16).collect::<String>();
        format!("{}-{}-{}{}", self.size, self.modified_millis, prefix(&self.head_hash), prefix(&self.tail_hash))
    }

    /// Reads size, mtime and the two chunks of `path`.
    pub fn compute(path: &Path) -> io::Result<SourceFingerprint> {
        let meta = fs::metadata(path)?;
        let size = i64::try_from(meta.len()).unwrap_or(i64::MAX);
        let millis = modified_millis(&meta, 0.0);
        let mut file = File::open(path)?;
        let n = Self::CHUNK_SIZE as i64;
        let head = read_chunk(&mut file)?;
        let mut tail = Vec::new();
        if size > n {
            file.seek(SeekFrom::Start((size - n).max(0) as u64))?;
            tail = read_chunk(&mut file)?;
        }
        Ok(SourceFingerprint {
            size,
            modified_millis: millis,
            head_hash: sha256_digest::hex(&head),
            tail_hash: sha256_digest::hex(&tail),
        })
    }
}

/// Up to one chunk from the current position.
fn read_chunk(file: &mut File) -> io::Result<Vec<u8>> {
    let mut data = Vec::new();
    file.take(SourceFingerprint::CHUNK_SIZE as u64).read_to_end(&mut data)?;
    Ok(data)
}

/// One finished proxy in the cache.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(from = "RecordFields", rename_all = "camelCase")]
pub struct ProxyRecord {
    /// The source it was made from.
    pub fingerprint: SourceFingerprint,
    /// Which proxy.
    pub kind: ProxyKind,
    /// File name relative to the cache folder.
    pub file_name: String,
    /// Picture size of the proxy.
    pub dimensions: ProxyDimensions,
    /// When the file was committed.
    #[serde(with = "sq_core_time::timestamp::iso8601")]
    pub created_at: Timestamp,
    /// Duration of the source.
    pub source_duration: Time,
    /// Last time a lookup handed this proxy out (LRU eviction). Defaults to `created_at`.
    #[serde(with = "sq_core_time::timestamp::iso8601")]
    pub last_access: Timestamp,
    /// Which transcoder made the file (`CURRENT_BUILD`). A record without it is from before proxies of interlaced
    /// sources were deinterlaced (0): such a proxy is woven, so it is not handed out until its source was checked
    /// (`ProxyProvider::warm`: an interlaced source's proxy is deleted and made again, any other is marked current).
    pub build: i64,
}

/// The coded shape of a record: `lastAccess` and `build` may be missing in old index files.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecordFields {
    fingerprint: SourceFingerprint,
    kind: ProxyKind,
    file_name: String,
    dimensions: ProxyDimensions,
    #[serde(with = "sq_core_time::timestamp::iso8601")]
    created_at: Timestamp,
    source_duration: Time,
    #[serde(default, with = "sq_core_time::timestamp::iso8601::option")]
    last_access: Option<Timestamp>,
    #[serde(default)]
    build: Option<i64>,
}

impl From<RecordFields> for ProxyRecord {
    fn from(f: RecordFields) -> ProxyRecord {
        ProxyRecord {
            fingerprint: f.fingerprint,
            kind: f.kind,
            file_name: f.file_name,
            dimensions: f.dimensions,
            created_at: f.created_at,
            source_duration: f.source_duration,
            last_access: f.last_access.unwrap_or(f.created_at),
            build: f.build.unwrap_or(0),
        }
    }
}

impl ProxyRecord {
    /// 1: interlaced sources get a deinterlaced, progressive proxy.
    pub const CURRENT_BUILD: i64 = 1;

    /// A record made by the current transcoder, last used when it was created.
    pub fn new(
        fingerprint: SourceFingerprint,
        kind: ProxyKind,
        file_name: String,
        dimensions: ProxyDimensions,
        created_at: Timestamp,
        source_duration: Time,
    ) -> ProxyRecord {
        ProxyRecord {
            fingerprint,
            kind,
            file_name,
            dimensions,
            created_at,
            source_duration,
            last_access: created_at,
            build: Self::CURRENT_BUILD,
        }
    }

    /// Made by the current transcoder.
    pub fn is_current(&self) -> bool {
        self.build >= Self::CURRENT_BUILD
    }
}

/// Identity ignores `last_access` (volatile usage bookkeeping).
impl PartialEq for ProxyRecord {
    fn eq(&self, b: &ProxyRecord) -> bool {
        self.fingerprint == b.fingerprint
            && self.kind == b.kind
            && self.file_name == b.file_name
            && self.dimensions == b.dimensions
            && self.created_at == b.created_at
            && self.source_duration == b.source_duration
            && self.build == b.build
    }
}

impl Eq for ProxyRecord {}

impl Hash for ProxyRecord {
    fn hash<H: Hasher>(&self, h: &mut H) {
        self.fingerprint.hash(h);
        self.kind.hash(h);
        self.file_name.hash(h);
    }
}

/// User-facing proxy settings, persisted as `settings.json` inside the cache folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxySettings {
    /// Maximum total size of the proxy cache (LRU eviction above it).
    pub cache_cap_bytes: i64,
    /// Manual toggle: proxies also for playback (slow machines). Paused frames stay original.
    pub use_proxies_for_playback: bool,
}

impl ProxySettings {
    /// 50 GB.
    pub const DEFAULT_CACHE_CAP: i64 = 50_000_000_000;
}

impl Default for ProxySettings {
    fn default() -> ProxySettings {
        ProxySettings { cache_cap_bytes: Self::DEFAULT_CACHE_CAP, use_proxies_for_playback: false }
    }
}

/// What the playhead is doing when a decoder is requested.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProxyUseContext {
    /// Dragging the playhead.
    Scrubbing,
    /// Playing.
    Playback,
    /// Stopped on a frame.
    Paused,
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A fresh empty temp directory, removed on drop.
    pub struct TempDir(pub PathBuf);

    impl TempDir {
        pub fn new() -> TempDir {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let n = NEXT.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir().join(format!("sqproxy-{}-{n}", std::process::id()));
            std::fs::create_dir_all(&dir).ok();
            TempDir(dir)
        }
        pub fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).ok();
        }
    }

    /// `bytes` of deterministic content seeded by `seed`.
    pub fn write_file(path: &Path, bytes: usize, seed: u8) {
        let data: Vec<u8> = (0..bytes).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)).collect();
        std::fs::write(path, data).ok();
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;

    #[test]
    fn scale_and_codec() {
        assert_eq!(ProxyKind::Optimized.scale_divisor(), 1);
        assert_eq!(ProxyKind::ProxyHalf.scale_divisor(), 2);
        assert_eq!(ProxyKind::ProxyQuarter.scale_divisor(), 4);
        assert_eq!(ProxyKind::Optimized.codec_four_cc(), "apcn");
        assert_eq!(ProxyKind::ProxyHalf.codec_four_cc(), "apco");
        assert_eq!(ProxyKind::ProxyQuarter.codec_four_cc(), "apco");
    }

    #[test]
    fn scaled_dimensions_are_even() {
        let d = ProxyDimensions { width: 3840, height: 2160 }.scaled(4);
        assert_eq!(d, ProxyDimensions { width: 960, height: 540 });
        let odd = ProxyDimensions { width: 1922, height: 1082 }.scaled(4);
        assert!(odd.width % 2 == 0 && odd.height % 2 == 0);
    }

    #[test]
    fn moved_file_keeps_fingerprint() {
        let dir = TempDir::new();
        let a = dir.join("a.bin");
        write_file(&a, 300_000, 1);
        let f1 = SourceFingerprint::compute(&a).unwrap();
        let b = dir.join("renamed.bin");
        fs::rename(&a, &b).unwrap();
        assert_eq!(SourceFingerprint::compute(&b).unwrap(), f1);
    }

    #[test]
    fn head_tail_and_size_change_fingerprint() {
        let dir = TempDir::new();
        let a = dir.join("a.bin");
        write_file(&a, 300_000, 1);
        let mtime = fs::metadata(&a).unwrap().modified().unwrap();
        let base = SourceFingerprint::compute(&a).unwrap();
        let mutate = |offset: usize| {
            let mut d = fs::read(&a).unwrap();
            d[offset] ^= 0xFF;
            fs::write(&a, &d).unwrap();
            File::options().write(true).open(&a).unwrap().set_modified(mtime).unwrap();
            let fp = SourceFingerprint::compute(&a).unwrap();
            d[offset] ^= 0xFF;
            fs::write(&a, &d).unwrap();
            File::options().write(true).open(&a).unwrap().set_modified(mtime).unwrap();
            fp
        };
        assert_ne!(mutate(10), base);
        assert_ne!(mutate(299_990), base);
        // documented limitation: middle edit with same size+mtime is not detected
        assert_eq!(mutate(150_000), base);
        let mut d = fs::read(&a).unwrap();
        d.push(0);
        fs::write(&a, d).unwrap();
        assert_ne!(SourceFingerprint::compute(&a).unwrap(), base);
    }

    #[test]
    fn small_file_and_codable() {
        let dir = TempDir::new();
        let a = dir.join("s.bin");
        write_file(&a, 100, 1);
        let f = SourceFingerprint::compute(&a).unwrap();
        let back: SourceFingerprint = serde_json::from_str(&serde_json::to_string(&f).unwrap()).unwrap();
        assert_eq!(back, f);
        assert!(!f.id().is_empty() && !f.id().contains('/'));
    }

    #[test]
    fn missing_file_errors() {
        assert!(SourceFingerprint::compute(Path::new("/nonexistent/x.mov")).is_err());
    }

    #[test]
    fn records_without_a_build_are_old() {
        let fp = SourceFingerprint { size: 1, modified_millis: 2, head_hash: "a".into(), tail_hash: "b".into() };
        let new = ProxyRecord::new(
            fp,
            ProxyKind::ProxyHalf,
            "f".into(),
            ProxyDimensions { width: 2, height: 2 },
            Timestamp::from_unix_seconds(10.0),
            Time::new(5, 1),
        );
        assert!(new.is_current());
        let mut json = serde_json::to_value(&new).unwrap();
        let back: ProxyRecord = serde_json::from_value(json.clone()).unwrap();
        assert!(back.is_current());
        json.as_object_mut().unwrap().remove("build");
        json.as_object_mut().unwrap().remove("lastAccess");
        let old: ProxyRecord = serde_json::from_value(json).unwrap();
        assert!(old.build == 0 && !old.is_current());
        assert_eq!(old.last_access, old.created_at);
    }
}
