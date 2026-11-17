// Swift: PreviewRequests.swift
//! Preview requests, the on-disk preview cache (LRU by modification date) and the coordinator that serves previews from
//! the cache, merges identical in-flight requests and drops stale work.
//!
//! Swift: `PreviewCoordinator` is an `actor` that awaits a provider inside `Task`s. Here the coordinator is a plain struct
//! driven in steps by its single owner: `begin` answers from the cache or hands out a `PreviewTicket`, the owner runs the
//! (blocking) `PreviewProvider` wherever it likes (a worker thread, the executor) and reports back with `complete`;
//! `leave` is a cancelled waiter. Calls that would overlap in Swift (two identical requests, a newer file version while the
//! old preview renders) overlap here as `begin` calls between a ticket's `begin` and `complete`. `version` counts changes.

use crate::watched_folder::{DISTANT_PAST, LibraryEntry, LibraryEntryID, WatchedFolder, standardized_path};
use serde::{Deserialize, Serialize};
use sq_core_project::cache_disk_policy::CacheDiskPolicy;
use sq_core_project::file_walk::{self, Step};
use sq_core_time::Timestamp;
use std::cmp::Ordering;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};

/// What a preview shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PreviewKind {
    /// A still frame.
    Thumbnail,
    /// The audio waveform.
    Waveform,
}

impl PreviewKind {
    /// Folder name and file name part.
    pub fn raw_value(self) -> &'static str {
        match self {
            PreviewKind::Thumbnail => "thumbnail",
            PreviewKind::Waveform => "waveform",
        }
    }

    fn file_extension(self) -> &'static str {
        match self {
            PreviewKind::Thumbnail => "png",
            PreviewKind::Waveform => "waveform",
        }
    }
}

/// Identifies a file version: path + modification time + size.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ContentHash {
    /// Full path of the file.
    pub path: String,
    /// Last content change.
    pub modified: Timestamp,
    /// Size in bytes.
    pub size: i64,
}

impl ContentHash {
    /// Stable 16 hex digit key (FNV-1a 64; a per-process hash would be useless on disk).
    pub fn key(&self) -> String {
        let millis = (self.modified.unix_seconds() * 1000.0).round() as i64;
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in format!("{}|{millis}|{}", self.path, self.size).bytes() {
            h ^= u64::from(byte);
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
        format!("{h:016x}")
    }
}

/// One preview to make.
#[derive(Clone, Debug, PartialEq)]
pub struct PreviewRequest {
    /// The library entry.
    pub entry_id: LibraryEntryID,
    /// Thumbnail or waveform.
    pub kind: PreviewKind,
    /// Width of the result.
    pub pixel_width: i64,
    /// Height of the result.
    pub pixel_height: i64,
    /// The file version.
    pub content_hash: ContentHash,
}

impl PreviewRequest {
    /// The request for a library entry.
    pub fn for_entry(
        entry: &LibraryEntry,
        folder: &WatchedFolder,
        kind: PreviewKind,
        pixel_width: i64,
        pixel_height: i64,
    ) -> PreviewRequest {
        PreviewRequest {
            entry_id: entry.id(),
            kind,
            pixel_width,
            pixel_height,
            content_hash: ContentHash {
                path: sq_os::paths::stored(&entry.url(folder)),
                modified: entry.modified,
                size: entry.size,
            },
        }
    }

    /// Unique key of the rendered result (content + kind + size); the entry id is not part of it.
    fn cache_key(&self) -> String {
        format!("{}_{}x{}", self.content_hash.key(), self.pixel_width, self.pixel_height)
    }
}

/// Why a preview was not made.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreviewError {
    /// The file changed while the preview was being generated.
    Stale,
    /// Free disk space is below the cache floor (`CacheDiskPolicy`): nothing is generated.
    DiskLow,
    /// The waiter or the whole request was cancelled.
    Cancelled,
    /// The provider or the file system failed (their text).
    Failed(String),
}

/// Generates a preview file at `destination`. Implemented elsewhere (AVFoundation, FFmpeg); must stop early when `cancel` is set.
pub trait PreviewProvider: Send + Sync {
    /// Makes the preview file, or fails.
    fn generate(&self, request: &PreviewRequest, destination: &Path, cancel: &AtomicBool) -> Result<(), PreviewError>;
}

/// Derives cache file locations: `<caches>/Sequence Studio/Previews/<kind>/<key>.<ext>`.
pub struct PreviewCache {
    /// Folder of all preview files.
    pub root: PathBuf,
    /// Maximum total size of all cached files in bytes.
    pub byte_cap: i64,
    /// Disk space rule.
    pub disk: CacheDiskPolicy,
}

struct CachedFile {
    path: PathBuf,
    size: i64,
    accessed: Timestamp,
}

impl PreviewCache {
    /// Default `byte_cap`: 2 GB.
    pub const DEFAULT_BYTE_CAP: i64 = 2 * 1024 * 1024 * 1024;

    /// A cache below a caches directory (the app passes the real one).
    pub fn in_caches_directory(caches_directory: &Path, byte_cap: i64, disk: CacheDiskPolicy) -> PreviewCache {
        PreviewCache { root: caches_directory.join("Sequence Studio").join("Previews"), byte_cap, disk }
    }

    /// A cache whose files sit in `<cache_root>/Previews` (the cache folder of Settings > Media).
    pub fn in_cache_root(cache_root: &Path, byte_cap: i64, disk: CacheDiskPolicy) -> PreviewCache {
        PreviewCache { root: cache_root.join("Previews"), byte_cap, disk }
    }

    /// Where the preview of `request` lives.
    pub fn file_url(&self, request: &PreviewRequest) -> PathBuf {
        self.root.join(request.kind.raw_value()).join(format!(
            "{}.{}",
            request.cache_key(),
            request.kind.file_extension()
        ))
    }

    // LRU bookkeeping: the last access time is the file's modification date (no index file).
    // Cache files are write-once, so the mtime is free to carry "last used"; `touch` bumps it.

    /// Files below the root (the walk leaves out dot names, so in-flight `.tmp-` files are not listed).
    fn cached_files(&self) -> Vec<CachedFile> {
        let mut out = Vec::new();
        file_walk::walk(&self.root, &mut |path, values, _| {
            if let Some(v) = values.filter(|v| v.is_regular_file == Some(true)) {
                out.push(CachedFile {
                    path: path.to_path_buf(),
                    size: v.file_size.unwrap_or(0),
                    accessed: v.content_modification_date.unwrap_or(DISTANT_PAST),
                });
            }
            Step::Descend
        });
        out
    }

    /// Bytes of all cached files.
    pub fn total_size(&self) -> i64 {
        self.cached_files().iter().map(|f| f.size).sum()
    }

    /// Marks `path` as just used. Files outside the cache root are ignored.
    // shortcut: reads the system clock (the modification date is "now" by definition); inject a clock when a test needs it.
    pub fn touch(&self, path: &Path) {
        if !self.is_inside_root(path) {
            return;
        }
        if let Ok(f) = std::fs::OpenOptions::new().write(true).open(path) {
            let _ = f.set_modified(std::time::SystemTime::now());
        }
    }

    fn resolved(path: &Path) -> String {
        standardized_path(&sq_os::paths::canonical(path).unwrap_or_else(|_| path.to_path_buf()))
    }

    fn is_inside_root(&self, path: &Path) -> bool {
        Self::resolved(path).starts_with(&format!("{}/", Self::resolved(&self.root)))
    }

    /// Removes least recently used files until `total + additional_bytes <= byte_cap`. Protected files are never removed.
    /// Returns the removed paths (oldest first).
    pub fn evict(&self, additional_bytes: i64, protecting: &BTreeSet<PathBuf>) -> Vec<PathBuf> {
        let protected: BTreeSet<String> = protecting.iter().map(|p| Self::resolved(p)).collect();
        let mut files = self.cached_files();
        let mut total: i64 = files.iter().map(|f| f.size).sum::<i64>() + additional_bytes;
        if total <= self.byte_cap {
            return Vec::new();
        }
        files.sort_by(|a, b| a.accessed.partial_cmp(&b.accessed).unwrap_or(Ordering::Equal));
        let mut removed = Vec::new();
        for f in files {
            if total <= self.byte_cap {
                break;
            }
            if protected.contains(&Self::resolved(&f.path)) {
                continue;
            }
            if std::fs::remove_file(&f.path).is_ok() {
                total -= f.size;
                removed.push(f.path);
            }
        }
        removed
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Slot {
    entry_id: LibraryEntryID,
    kind: PreviewKind,
}

struct Flight {
    id: u64,
    waiters: usize,
    slot: Slot,
    content_key: String,
    superseded: bool,
    cancel: Arc<AtomicBool>,
}

struct Version {
    key: String,
    modified: Timestamp,
    size: i64,
}

/// What `begin` found.
#[derive(Debug)]
pub enum PreviewStart {
    /// The preview is in the cache.
    Ready(PathBuf),
    /// The caller makes the preview (provider, then `complete`).
    Generate(PreviewTicket),
    /// An identical request is running: wait for its `complete`, then `take_outcome`.
    Joined(PreviewTicket),
}

/// One caller's share of a running preview.
#[derive(Debug)]
pub struct PreviewTicket {
    key: String,
    id: u64,
    request: PreviewRequest,
    destination: PathBuf,
    temp: PathBuf,
    cancel: Arc<AtomicBool>,
}

impl PreviewTicket {
    /// The request.
    pub fn request(&self) -> &PreviewRequest {
        &self.request
    }

    /// Where the provider writes (a hidden temp file next to the final one).
    pub fn temp_path(&self) -> &Path {
        &self.temp
    }

    /// Set when the work was cancelled or superseded; the provider stops early.
    pub fn cancel_flag(&self) -> &AtomicBool {
        &self.cancel
    }
}

/// Serves previews from cache, de-duplicates identical in-flight requests and drops stale work.
pub struct PreviewCoordinator {
    cache: PreviewCache,
    flights: HashMap<String, Flight>,
    latest_content: HashMap<Slot, Version>,
    known_files: HashMap<Slot, HashMap<String, BTreeSet<PathBuf>>>,
    /// Results of finished flights that joined callers have not taken yet: (flight key, id) -> (result, callers left).
    outcomes: HashMap<(String, u64), (Result<PathBuf, PreviewError>, usize)>,
    next_flight: u64,
    version: u64,
}

fn flight_key(r: &PreviewRequest) -> String {
    format!("{}/{}", r.kind.raw_value(), r.cache_key())
}

impl PreviewCoordinator {
    /// A coordinator with nothing running.
    pub fn new(cache: PreviewCache) -> PreviewCoordinator {
        PreviewCoordinator {
            cache,
            flights: HashMap::new(),
            latest_content: HashMap::new(),
            known_files: HashMap::new(),
            outcomes: HashMap::new(),
            next_flight: 0,
            version: 0,
        }
    }

    /// The cache the previews live in.
    pub fn cache(&self) -> &PreviewCache {
        &self.cache
    }

    /// Counts every change of the running work.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Previews being made.
    pub fn in_flight_count(&self) -> usize {
        self.flights.len()
    }

    /// Callers waiting for the preview of `request`.
    pub fn waiter_count(&self, request: &PreviewRequest) -> usize {
        self.flights.get(&flight_key(request)).map_or(0, |f| f.waiters)
    }

    /// Starts a request: a cached file, a new job, or a job to wait for. A request for older content than the latest seen
    /// is dropped (`Stale`) without touching the newer job or its files.
    pub fn begin(&mut self, request: &PreviewRequest) -> Result<PreviewStart, PreviewError> {
        let slot = Slot { entry_id: request.entry_id.clone(), kind: request.kind };
        let content = request.content_hash.key();
        let version =
            Version { key: content.clone(), modified: request.content_hash.modified, size: request.content_hash.size };
        if let Some(latest) = self.latest_content.get(&slot).filter(|l| l.key != content) {
            let order = version
                .modified
                .partial_cmp(&latest.modified)
                .unwrap_or(Ordering::Equal)
                .then(version.size.cmp(&latest.size));
            if order == Ordering::Less {
                return Err(PreviewError::Stale);
            }
            self.supersede(&slot, &content);
        }
        self.latest_content.insert(slot.clone(), version);

        let destination = self.cache.file_url(request);
        if destination.exists() {
            self.known_files.entry(slot).or_default().entry(content).or_default().insert(destination.clone());
            self.cache.touch(&destination);
            return Ok(PreviewStart::Ready(destination));
        }

        let key = flight_key(request);
        let cancel = Arc::new(AtomicBool::new(false));
        if let Some(existing) = self.flights.get_mut(&key) {
            existing.waiters += 1;
            self.version += 1;
            let ticket = PreviewTicket {
                key,
                id: existing.id,
                request: request.clone(),
                temp: Self::temp_for(&destination, existing.id),
                destination,
                cancel: Arc::clone(&existing.cancel),
            };
            return Ok(PreviewStart::Joined(ticket));
        }
        if let Some(dir) = destination.parent() {
            std::fs::create_dir_all(dir).map_err(|e| PreviewError::Failed(e.to_string()))?;
        }
        if self.cache.disk.is_below_floor(&destination) {
            return Err(PreviewError::DiskLow);
        }
        self.next_flight += 1;
        let id = self.next_flight;
        self.flights.insert(
            key.clone(),
            Flight { id, waiters: 1, slot, content_key: content, superseded: false, cancel: Arc::clone(&cancel) },
        );
        self.version += 1;
        let temp = Self::temp_for(&destination, id);
        Ok(PreviewStart::Generate(PreviewTicket { key, id, request: request.clone(), destination, temp, cancel }))
    }

    fn temp_for(destination: &Path, id: u64) -> PathBuf {
        destination.with_file_name(format!(".tmp-{id}"))
    }

    /// The provider finished (or failed) for the ticket `begin` returned as `Generate`. Moves the file into the cache and
    /// returns its path, or the error; callers that joined get the same result from `take_outcome`.
    pub fn complete(
        &mut self,
        ticket: &PreviewTicket,
        generated: Result<(), PreviewError>,
    ) -> Result<PathBuf, PreviewError> {
        let result = self.finish_generation(ticket, generated);
        let waiters = self.flights.get(&ticket.key).filter(|f| f.id == ticket.id).map_or(0, |f| f.waiters);
        self.flights.remove(&ticket.key);
        if waiters > 1 {
            self.outcomes.insert((ticket.key.clone(), ticket.id), (result.clone(), waiters - 1));
        }
        self.version += 1;
        result
    }

    fn finish_generation(
        &mut self,
        ticket: &PreviewTicket,
        generated: Result<(), PreviewError>,
    ) -> Result<PathBuf, PreviewError> {
        let superseded = self.flights.get(&ticket.key).is_some_and(|f| f.id == ticket.id && f.superseded);
        let outcome = if superseded {
            Err(PreviewError::Stale)
        } else if ticket.cancel.load(AtomicOrdering::SeqCst) {
            Err(PreviewError::Cancelled)
        } else {
            generated
        };
        if let Err(e) = outcome {
            let _ = std::fs::remove_file(&ticket.temp);
            return Err(e);
        }
        let moved = (|| {
            if ticket.destination.exists() {
                std::fs::remove_file(&ticket.destination)?;
            }
            std::fs::rename(&ticket.temp, &ticket.destination)
        })();
        if let Err(e) = moved {
            let _ = std::fs::remove_file(&ticket.temp);
            return Err(PreviewError::Failed(e.to_string()));
        }
        // The final staleness check: the flight must still be ours, not superseded, and the latest content of its slot.
        let Some(f) = self.flights.get(&ticket.key).filter(|f| f.id == ticket.id) else {
            let _ = std::fs::remove_file(&ticket.destination);
            return Err(PreviewError::Stale);
        };
        let current = self.latest_content.get(&f.slot).is_some_and(|l| l.key == f.content_key);
        if f.superseded || !current {
            let _ = std::fs::remove_file(&ticket.destination);
            return Err(PreviewError::Stale);
        }
        let (slot, content) = (f.slot.clone(), ticket.request.content_hash.key());
        self.cache.touch(&ticket.destination);
        self.cache.evict(0, &BTreeSet::from([ticket.destination.clone()]));
        self.known_files.entry(slot).or_default().entry(content).or_default().insert(ticket.destination.clone());
        Ok(ticket.destination.clone())
    }

    /// The result of the job a `Joined` ticket waited for; `None` while it still runs.
    pub fn take_outcome(&mut self, ticket: &PreviewTicket) -> Option<Result<PathBuf, PreviewError>> {
        let key = (ticket.key.clone(), ticket.id);
        let (result, left) = self.outcomes.get_mut(&key)?;
        let out = result.clone();
        *left -= 1;
        if *left == 0 {
            self.outcomes.remove(&key);
        }
        Some(out)
    }

    /// A waiter gave up. The last one to leave cancels the work.
    pub fn leave(&mut self, ticket: &PreviewTicket) {
        let Some(f) = self.flights.get_mut(&ticket.key).filter(|f| f.id == ticket.id) else { return };
        f.waiters -= 1;
        if f.waiters == 0 {
            f.cancel.store(true, AtomicOrdering::SeqCst);
            self.flights.remove(&ticket.key);
        }
        self.version += 1;
    }

    /// Cancels work and deletes cached files of older content versions of the same entry/kind.
    fn supersede(&mut self, slot: &Slot, keeping: &str) {
        for f in self.flights.values_mut().filter(|f| f.slot == *slot && f.content_key != keeping) {
            f.superseded = true;
            f.cancel.store(true, AtomicOrdering::SeqCst);
        }
        if let Some(by_content) = self.known_files.get_mut(slot) {
            for (old, urls) in by_content.iter().filter(|(c, _)| c.as_str() != keeping) {
                debug_assert_ne!(old, keeping);
                for u in urls {
                    let _ = std::fs::remove_file(u);
                }
            }
            by_content.retain(|c, _| c == keeping);
        }
        self.version += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use crate::library_item_kind::LibraryItemKind;
    use sq_core_time::Id;
    use std::sync::atomic::AtomicUsize;
    use std::time::{Duration, SystemTime};

    fn entry() -> LibraryEntryID {
        LibraryEntryID { folder_id: Id::fixed(1), relative_path: "a.mov".into() }
    }

    fn hash(size: i64) -> ContentHash {
        ContentHash { path: "/a.mov".into(), modified: DISTANT_PAST, size }
    }

    fn req_with(hash: ContentHash, kind: PreviewKind, w: i64, h: i64) -> PreviewRequest {
        PreviewRequest { entry_id: entry(), kind, pixel_width: w, pixel_height: h, content_hash: hash }
    }

    fn req(size: i64) -> PreviewRequest {
        req_with(hash(size), PreviewKind::Thumbnail, 160, 90)
    }

    /// Writes a small file; counts calls; sees the cancel flag.
    #[derive(Default)]
    struct FakeProvider {
        calls: AtomicUsize,
        cancelled: AtomicUsize,
    }

    impl PreviewProvider for FakeProvider {
        fn generate(&self, _: &PreviewRequest, destination: &Path, cancel: &AtomicBool) -> Result<(), PreviewError> {
            self.calls.fetch_add(1, AtomicOrdering::SeqCst);
            if cancel.load(AtomicOrdering::SeqCst) {
                self.cancelled.fetch_add(1, AtomicOrdering::SeqCst);
                return Err(PreviewError::Cancelled);
            }
            std::fs::write(destination, b"preview").map_err(|e| PreviewError::Failed(e.to_string()))
        }
    }

    fn cache(dir: &TempDir) -> PreviewCache {
        PreviewCache::in_caches_directory(dir.path(), PreviewCache::DEFAULT_BYTE_CAP, CacheDiskPolicy::unchecked())
    }

    fn coordinator(dir: &TempDir) -> PreviewCoordinator {
        PreviewCoordinator::new(cache(dir))
    }

    fn generate(p: &FakeProvider, t: &PreviewTicket) -> Result<(), PreviewError> {
        p.generate(t.request(), t.temp_path(), t.cancel_flag())
    }

    fn started(s: Result<PreviewStart, PreviewError>) -> PreviewTicket {
        match s {
            Ok(PreviewStart::Generate(t)) => t,
            other => panic!("expected a new job, got {other:?}"),
        }
    }

    /// The whole path for a caller without concurrent requests.
    fn preview(c: &mut PreviewCoordinator, p: &FakeProvider, r: &PreviewRequest) -> Result<PathBuf, PreviewError> {
        match c.begin(r)? {
            PreviewStart::Ready(path) => Ok(path),
            PreviewStart::Generate(t) => {
                let generated = generate(p, &t);
                c.complete(&t, generated)
            }
            PreviewStart::Joined(_) => panic!("nothing runs"),
        }
    }

    #[test]
    fn content_hash_is_stable_and_sensitive() {
        let d = Timestamp::from_unix_seconds(1000.0);
        let h = |p: &str, m: Timestamp, s: i64| ContentHash { path: p.into(), modified: m, size: s }.key();
        let base = h("/a/b.mov", d, 10);
        assert_eq!(base, h("/a/b.mov", d, 10));
        assert_ne!(base, h("/a/c.mov", d, 10));
        assert_ne!(base, h("/a/b.mov", Timestamp::from_unix_seconds(1001.0), 10));
        assert_ne!(base, h("/a/b.mov", d, 11));
        assert_eq!(base.len(), 16);
        // FNV-1a 64 of "|0|0" (empty path, epoch, size 0), computed independently: guards the on-disk key format.
        assert_eq!(h("", Timestamp::from_unix_seconds(0.0), 0), "2ca8903035899505");
    }

    #[test]
    fn cache_paths_live_under_injected_directory_and_differ() {
        let cache = PreviewCache::in_caches_directory(Path::new("/tmp/caches-test"), 1, CacheDiskPolicy::unchecked());
        let thumb = cache.file_url(&req(1));
        assert!(thumb.starts_with("/tmp/caches-test/Sequence Studio/Previews/"));
        assert_ne!(thumb, cache.file_url(&req_with(hash(1), PreviewKind::Waveform, 160, 90)));
        assert_ne!(thumb, cache.file_url(&req_with(hash(1), PreviewKind::Thumbnail, 320, 180)));
        assert_eq!(thumb, cache.file_url(&req(1)));
        let in_root = PreviewCache::in_cache_root(Path::new("/Volumes/Fast/C"), 1, CacheDiskPolicy::unchecked());
        assert_eq!(in_root.root, Path::new("/Volumes/Fast/C/Previews"));
    }

    #[test]
    fn request_from_entry() {
        let e = LibraryEntry {
            folder_id: Id::fixed(1),
            relative_path: "x/y.mov".into(),
            kind: LibraryItemKind::Video,
            size: 5,
            modified: Timestamp::from_unix_seconds(7.0),
        };
        let f = WatchedFolder::new(e.folder_id, PathBuf::from("/m"), None, None);
        let r = PreviewRequest::for_entry(&e, &f, PreviewKind::Waveform, 100, 20);
        assert_eq!(r.entry_id, e.id());
        assert_eq!(r.content_hash, ContentHash { path: "/m/x/y.mov".into(), modified: e.modified, size: 5 });
    }

    #[test]
    fn cached_result_skips_provider() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let a = preview(&mut c, &p, &req(1));
        let b = preview(&mut c, &p, &req(1));
        assert_eq!(a, b);
        assert!(a.is_ok_and(|path| path.exists()));
        assert_eq!(p.calls.load(AtomicOrdering::SeqCst), 1);
    }

    #[test]
    fn below_disk_floor_generates_nothing() {
        let dir = TempDir::new();
        let low = CacheDiskPolicy::new(|_| sq_core_project::cache_disk_policy::VolumeSpace {
            free: Some(1 << 30),
            total: Some(256 << 30),
        });
        let mut c = PreviewCoordinator::new(PreviewCache::in_caches_directory(dir.path(), 1 << 40, low));
        let p = FakeProvider::default();
        assert_eq!(preview(&mut c, &p, &req(1)), Err(PreviewError::DiskLow));
        assert_eq!(p.calls.load(AtomicOrdering::SeqCst), 0);
        assert_eq!(c.in_flight_count(), 0);
    }

    #[test]
    fn concurrent_identical_requests_are_coalesced() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let first = started(c.begin(&req(1)));
        let Ok(PreviewStart::Joined(second)) = c.begin(&req(1)) else { panic!("second caller joins") };
        assert_eq!((c.in_flight_count(), c.waiter_count(&req(1))), (1, 2));
        assert!(c.take_outcome(&second).is_none());
        let generated = generate(&p, &first);
        let a = c.complete(&first, generated);
        let b = c.take_outcome(&second);
        assert!(a.is_ok());
        assert_eq!(Some(a), b);
        assert!(c.take_outcome(&second).is_none());
        assert_eq!((p.calls.load(AtomicOrdering::SeqCst), c.in_flight_count()), (1, 0));
    }

    #[test]
    fn cancelling_the_only_waiter_cancels_provider() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let t = started(c.begin(&req(1)));
        c.leave(&t);
        assert_eq!(c.in_flight_count(), 0);
        let generated = generate(&p, &t);
        assert_eq!(generated, Err(PreviewError::Cancelled));
        assert_eq!(p.cancelled.load(AtomicOrdering::SeqCst), 1);
        assert_eq!(c.complete(&t, generated), Err(PreviewError::Cancelled));
        assert_eq!(c.in_flight_count(), 0);
    }

    #[test]
    fn one_cancelled_waiter_keeps_shared_work_alive() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let t1 = started(c.begin(&req(1)));
        let Ok(PreviewStart::Joined(t2)) = c.begin(&req(1)) else { panic!("joins") };
        assert_eq!(c.waiter_count(&req(1)), 2);
        c.leave(&t2);
        assert_eq!(c.waiter_count(&req(1)), 1);
        let generated = generate(&p, &t1);
        let url = c.complete(&t1, generated);
        assert!(url.is_ok_and(|u| u.exists()));
        assert_eq!(p.cancelled.load(AtomicOrdering::SeqCst), 0);
    }

    #[test]
    fn file_change_supersedes_in_flight_and_removes_old_cache() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let old = preview(&mut c, &p, &req(1)).unwrap_or_default();
        assert!(old.exists());
        let new = preview(&mut c, &p, &req(2)).unwrap_or_default();
        assert_ne!(new, old);
        assert!(!old.exists() && new.exists());
    }

    #[test]
    fn stale_in_flight_request_fails() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let stale = started(c.begin(&req(1)));
        let fresh = started(c.begin(&req(2)));
        assert!(stale.cancel_flag().load(AtomicOrdering::SeqCst));
        let fresh_generated = generate(&p, &fresh);
        let fresh_url = c.complete(&fresh, fresh_generated);
        assert!(fresh_url.is_ok_and(|u| u.exists()));
        let stale_generated = generate(&p, &stale);
        assert_eq!(c.complete(&stale, stale_generated), Err(PreviewError::Stale));
        assert_eq!(c.in_flight_count(), 0);
    }

    /// L1a: a request for older content must not supersede the newer flight or delete its files.
    #[test]
    fn older_content_request_is_ignored_and_keeps_newer() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let fresh = started(c.begin(&req(2)));
        assert_eq!(c.begin(&req(1)).err(), Some(PreviewError::Stale));
        assert_eq!(c.in_flight_count(), 1);
        let generated = generate(&p, &fresh);
        let url = c.complete(&fresh, generated).unwrap_or_default();
        assert!(url.exists());
        // A late old request after the newer one is cached must not delete the newer file either.
        assert_eq!(c.begin(&req(1)).err(), Some(PreviewError::Stale));
        assert!(url.exists());
    }

    /// L1b: a supersede that lands after the provider wrote its file must not leave the file behind.
    #[test]
    fn supersede_after_generation_leaves_no_orphan() {
        let dir = TempDir::new();
        let (mut c, p) = (coordinator(&dir), FakeProvider::default());
        let (old_req, new_req) = (req(1), req(2));
        let old = started(c.begin(&old_req));
        let generated = generate(&p, &old);
        // The provider already wrote its file when the newer version arrives.
        let _ = std::fs::write(old.temp_path(), b"preview");
        assert!(preview(&mut c, &p, &new_req).is_ok());
        assert_eq!(c.complete(&old, generated), Err(PreviewError::Stale));
        assert!(!c.cache().file_url(&old_req).exists() && !old.temp_path().exists());
        assert!(c.cache().file_url(&new_req).exists());
    }

    #[test]
    fn provider_failure_is_propagated_and_not_cached() {
        let dir = TempDir::new();
        let mut c = coordinator(&dir);
        let t = started(c.begin(&req(1)));
        assert_eq!(c.complete(&t, Err(PreviewError::Failed("boom".into()))), Err(PreviewError::Failed("boom".into())));
        assert_eq!(c.in_flight_count(), 0);
        assert!(!c.cache().file_url(&req(1)).exists());
    }

    // MARK: LRU

    fn lru_cache(dir: &TempDir, cap: i64) -> PreviewCache {
        PreviewCache::in_caches_directory(dir.path(), cap, CacheDiskPolicy::unchecked())
    }

    fn file(dir: &TempDir, cache: &PreviewCache, name: &str, bytes: usize, age: u64) -> PathBuf {
        let relative = cache.root.strip_prefix(dir.path()).unwrap_or(Path::new("")).join("thumbnail").join(name);
        let path = dir.write(&relative.to_string_lossy(), bytes);
        dir.set_modified(&path, SystemTime::now() - Duration::from_secs(age));
        path
    }

    fn names(paths: &[PathBuf]) -> Vec<String> {
        paths.iter().map(|p| crate::watched_folder::last_component(p)).collect()
    }

    #[test]
    fn default_cap_is_two_gb() {
        assert_eq!(PreviewCache::DEFAULT_BYTE_CAP, 2 * 1024 * 1024 * 1024);
    }

    #[test]
    fn evicts_oldest_first_down_to_cap() {
        let dir = TempDir::new();
        let cache = lru_cache(&dir, 250);
        let a = file(&dir, &cache, "a", 100, 400);
        let b = file(&dir, &cache, "b", 100, 300);
        let c = file(&dir, &cache, "c", 100, 200);
        let d = file(&dir, &cache, "d", 100, 100);
        assert_eq!(cache.total_size(), 400);
        let removed = cache.evict(0, &BTreeSet::new());
        assert_eq!(names(&removed), ["a", "b"]);
        assert_eq!(cache.total_size(), 200);
        assert!(!a.exists() && !b.exists() && c.exists() && d.exists());
    }

    #[test]
    fn no_eviction_under_cap_and_additional_bytes_count() {
        let dir = TempDir::new();
        let cache = lru_cache(&dir, 250);
        file(&dir, &cache, "a", 100, 20);
        file(&dir, &cache, "b", 100, 10);
        assert!(cache.evict(0, &BTreeSet::new()).is_empty());
        assert_eq!(names(&cache.evict(100, &BTreeSet::new())), ["a"]);
    }

    #[test]
    fn protected_file_is_never_removed() {
        let dir = TempDir::new();
        let cache = lru_cache(&dir, 100);
        let a = file(&dir, &cache, "a", 100, 400);
        let b = file(&dir, &cache, "b", 100, 300);
        let removed = cache.evict(0, &BTreeSet::from([a.clone()]));
        assert_eq!(names(&removed), ["b"]);
        assert!(a.exists() && !b.exists());
    }

    #[test]
    fn touch_refreshes_lru_order() {
        let dir = TempDir::new();
        let cache = lru_cache(&dir, 100);
        let a = file(&dir, &cache, "a", 100, 400);
        file(&dir, &cache, "b", 100, 300);
        cache.touch(&a);
        assert_eq!(names(&cache.evict(0, &BTreeSet::new())), ["b"]);
        assert!(a.exists());
    }

    #[test]
    fn files_outside_root_are_never_touched_or_evicted() {
        let dir = TempDir::new();
        let cache = lru_cache(&dir, 10);
        let outside = dir.write("elsewhere/x.png", 500);
        let old = SystemTime::now() - Duration::from_secs(1000);
        dir.set_modified(&outside, old);
        file(&dir, &cache, "a", 100, 50);
        cache.touch(&outside);
        assert_eq!(std::fs::metadata(&outside).and_then(|m| m.modified()).ok(), Some(old));
        cache.evict(0, &BTreeSet::new());
        assert!(outside.exists());
    }

    #[test]
    fn coordinator_hit_refreshes_and_generate_evicts_protecting_new_file() {
        let dir = TempDir::new();
        let mut c = PreviewCoordinator::new(lru_cache(&dir, 10)); // the provider writes 7 bytes: a second file forces eviction
        let p = FakeProvider::default();
        let r = |n: i64| PreviewRequest {
            entry_id: LibraryEntryID { folder_id: Id::fixed(1), relative_path: format!("e{n}") },
            kind: PreviewKind::Thumbnail,
            pixel_width: 10,
            pixel_height: 10,
            content_hash: ContentHash { path: format!("/m{n}"), modified: Timestamp::from_unix_seconds(1.0), size: n },
        };
        let first = preview(&mut c, &p, &r(1)).unwrap_or_default();
        dir.set_modified(&first, SystemTime::now() - Duration::from_secs(500));
        assert!(preview(&mut c, &p, &r(1)).is_ok()); // hit
        let age = std::fs::metadata(&first).and_then(|m| m.modified()).ok().and_then(|m| m.elapsed().ok());
        assert!(age.is_some_and(|a| a < Duration::from_secs(60)));
        let second = preview(&mut c, &p, &r(2)).unwrap_or_default();
        assert!(second.exists() && !first.exists());
    }
}
