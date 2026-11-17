// Swift: ProxyCache.swift (`AsyncStream` listeners are `mpsc` channels; a dropped receiver unsubscribes on the next send)
//! On-disk proxy store keyed by (fingerprint, kind).

use crate::model::{ProxyKind, ProxyRecord, ProxySettings, SourceFingerprint};
use serde::Serialize;
use sq_core_time::Timestamp;
use sq_os::Platform;
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// Identity of a cached proxy (source fingerprint + kind).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ProxyRecordID {
    /// `SourceFingerprint::id` of the source.
    pub fingerprint_id: String,
    /// Which proxy.
    pub kind: ProxyKind,
}

impl ProxyRecordID {
    /// The identity of a record.
    pub fn new(r: &ProxyRecord) -> ProxyRecordID {
        ProxyRecordID { fingerprint_id: r.fingerprint.id(), kind: r.kind }
    }

    /// The identity of a (source, kind) pair.
    pub fn of(fingerprint: &SourceFingerprint, kind: ProxyKind) -> ProxyRecordID {
        ProxyRecordID { fingerprint_id: fingerprint.id(), kind }
    }
}

type Key = (String, ProxyKind);

#[derive(Default)]
struct State {
    records: BTreeMap<Key, ProxyRecord>,
    listeners: Vec<Sender<ProxyRecord>>,
    removed_listeners: Vec<Sender<ProxyRecord>>,
    settings: ProxySettings,
    /// Records in use (e.g. open in a monitor): eviction never removes them.
    protected: BTreeSet<ProxyRecordID>,
}

/// On-disk proxy store keyed by (fingerprint, kind). Thread-safe; all methods are synchronous and cheap.
pub struct ProxyCache {
    directory: PathBuf,
    state: Mutex<State>,
}

/// Keys come out sorted, like Swift's `.sortedKeys`.
fn sorted_json<T: Serialize>(value: &T) -> io::Result<Vec<u8>> {
    let v = sq_core_time::json_sorted::to_value(value).map_err(io::Error::other)?;
    serde_json::to_vec(&v).map_err(io::Error::other)
}

/// Writes next to `path` and renames over it, so a reader never sees half a file.
fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path)
}

fn file_size(path: &Path) -> i64 {
    fs::metadata(path).map(|m| i64::try_from(m.len()).unwrap_or(i64::MAX)).unwrap_or(0)
}

/// Orders by date, then by file name.
fn by_time_then_name(a: (Timestamp, &str), b: (Timestamp, &str)) -> Ordering {
    a.0.reference_seconds().total_cmp(&b.0.reference_seconds()).then_with(|| a.1.cmp(b.1))
}

fn broadcast(listeners: &mut Vec<Sender<ProxyRecord>>, record: &ProxyRecord) {
    listeners.retain(|l| l.send(record.clone()).is_ok());
}

impl ProxyCache {
    /// `Sequence Studio/Proxies` inside the system's cache folder (the one name every cache folder uses) (`Platform::cache_dir`: `~/Library/Caches`,
    /// `%LOCALAPPDATA%`, `$XDG_CACHE_HOME` or `~/.cache`); the temporary folder when the environment names none.
    /// `env` reads environment variables.
    pub fn default_directory(env: impl Fn(&str) -> Option<String>) -> PathBuf {
        let platform = Platform::current();
        let (dir, old) = (Self::default_directory_for(platform, &env), Self::legacy_directory_for(platform, &env));
        // Proxies before 2026-11-17 lived under the bundle name `SequenceStudio`, waveforms and previews under `Sequence
        // Studio`. Moving the folder keeps the finished proxies; a failed move only means they are made again.
        if !dir.exists() && old.is_dir() {
            if let Some(parent) = dir.parent() {
                fs::create_dir_all(parent).ok();
            }
            fs::rename(&old, &dir).ok();
        }
        dir
    }

    fn legacy_directory_for(platform: Platform, env: impl Fn(&str) -> Option<String>) -> PathBuf {
        let base = platform.cache_dir(|k| env(k).map(OsString::from)).unwrap_or_else(std::env::temp_dir);
        base.join("SequenceStudio").join("Proxies")
    }

    /// [`Self::default_directory`] for a given system.
    pub fn default_directory_for(platform: Platform, env: impl Fn(&str) -> Option<String>) -> PathBuf {
        let base = platform.cache_dir(|k| env(k).map(OsString::from)).unwrap_or_else(std::env::temp_dir);
        base.join("Sequence Studio").join("Proxies")
    }

    /// Opens (and creates) the cache folder and reads its index and settings.
    pub fn new(directory: PathBuf) -> ProxyCache {
        fs::create_dir_all(&directory).ok();
        let mut state = State::default();
        if let Some(list) = fs::read(directory.join("index.json"))
            .ok()
            .and_then(|d| serde_json::from_slice::<Vec<ProxyRecord>>(&d).ok())
        {
            for r in list {
                state.records.insert((r.fingerprint.id(), r.kind), r);
            }
        }
        if let Some(s) = fs::read(directory.join("settings.json"))
            .ok()
            .and_then(|d| serde_json::from_slice::<ProxySettings>(&d).ok())
        {
            state.settings = s;
        }
        ProxyCache { directory, state: Mutex::new(state) }
    }

    /// The cache folder.
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn index_path(&self) -> PathBuf {
        self.directory.join("index.json")
    }

    /// The current settings.
    pub fn settings(&self) -> ProxySettings {
        self.lock().settings
    }

    /// Changes the settings and writes them. The write happens under the lock so the file always matches the last
    /// in-memory state.
    pub fn update_settings(&self, change: impl FnOnce(&mut ProxySettings)) -> io::Result<()> {
        let mut st = self.lock();
        change(&mut st.settings);
        write_atomic(&self.directory.join("settings.json"), &sorted_json(&st.settings)?)
    }

    /// File name of the proxy of `fingerprint` and `kind`.
    pub fn file_name(fingerprint: &SourceFingerprint, kind: ProxyKind) -> String {
        format!("{}.{}.mov", fingerprint.id(), kind.raw_value())
    }

    /// Where the record's file lives.
    pub fn file_url(&self, record: &ProxyRecord) -> PathBuf {
        self.directory.join(&record.file_name)
    }

    /// Staging location for an in-progress transcode. Never reported as ready.
    pub fn partial_url(&self, fingerprint: &SourceFingerprint, kind: ProxyKind) -> PathBuf {
        self.directory.join(Self::file_name(fingerprint, kind) + ".partial")
    }

    /// Returns the record only if its file still exists; otherwise drops the stale entry.
    /// A hit refreshes `last_access` (in memory; persisted with the next index write or `flush_index()`).
    pub fn lookup(&self, fingerprint: &SourceFingerprint, kind: ProxyKind, now: Timestamp) -> Option<ProxyRecord> {
        let key = (fingerprint.id(), kind);
        let r0 = self.lock().records.get(&key).cloned()?;
        if self.file_url(&r0).exists() {
            let mut r = r0.clone();
            r.last_access = now;
            let mut st = self.lock();
            if st.records.get(&key) == Some(&r0) {
                st.records.insert(key, r.clone());
            }
            return Some(r);
        }
        // Drop only the record we examined; a concurrent commit may have replaced it meanwhile.
        let dropped = {
            let mut st = self.lock();
            if st.records.get(&key) == Some(&r0) {
                st.records.remove(&key);
                true
            } else {
                false
            }
        };
        if dropped {
            self.write_index().ok();
        }
        None
    }

    /// `lookup`, but `None` for a record of an older transcoder that has not been checked yet (`ProxyRecord::build`).
    pub fn current_lookup(
        &self,
        fingerprint: &SourceFingerprint,
        kind: ProxyKind,
        now: Timestamp,
    ) -> Option<ProxyRecord> {
        self.lookup(fingerprint, kind, now).filter(|r| r.is_current())
    }

    /// Kinds of `fingerprint` whose record is from an older transcoder.
    pub fn outdated_kinds(&self, fingerprint: &SourceFingerprint) -> Vec<ProxyKind> {
        let st = self.lock();
        let id = fingerprint.id();
        ProxyKind::ALL
            .into_iter()
            .filter(|k| st.records.get(&(id.clone(), *k)).is_some_and(|r| !r.is_current()))
            .collect()
    }

    /// The old record's file is as good as a new one (its source has no fields): hand it out from now on.
    pub fn mark_current(&self, fingerprint: &SourceFingerprint, kind: ProxyKind) {
        let changed = {
            let mut st = self.lock();
            match st.records.get_mut(&(fingerprint.id(), kind)) {
                Some(r) if !r.is_current() => {
                    r.build = ProxyRecord::CURRENT_BUILD;
                    true
                }
                _ => false,
            }
        };
        if changed {
            self.write_index().ok();
        }
    }

    /// Every record whose file exists, oldest first.
    pub fn all_records(&self) -> Vec<ProxyRecord> {
        let all: Vec<ProxyRecord> = self.lock().records.values().cloned().collect();
        let mut out: Vec<ProxyRecord> = all.into_iter().filter(|r| self.file_url(r).exists()).collect();
        out.sort_by(|a, b| by_time_then_name((a.created_at, &a.file_name), (b.created_at, &b.file_name)));
        out
    }

    /// Persists pending `last_access` updates.
    pub fn flush_index(&self) {
        self.write_index().ok();
    }

    /// Moves the finished partial file into place and indexes it. Atomic for readers: the final name only ever
    /// refers to a complete file.
    pub fn commit(&self, partial: &Path, record: &ProxyRecord) -> io::Result<()> {
        let dest = self.file_url(record);
        // `rename` replaces an existing file in one step on both systems, so a concurrent lookup never misses the file.
        fs::rename(partial, dest)?;
        self.lock().records.insert((record.fingerprint.id(), record.kind), record.clone());
        self.write_index()?;
        broadcast(&mut self.lock().listeners, record);
        Ok(())
    }

    /// Deletes the proxy file and its record and reports the removal.
    pub fn remove(&self, fingerprint: &SourceFingerprint, kind: ProxyKind) {
        let removed = self.lock().records.remove(&(fingerprint.id(), kind));
        if let Some(r) = removed {
            fs::remove_file(self.file_url(&r)).ok();
            self.write_index().ok();
            broadcast(&mut self.lock().removed_listeners, &r);
        }
    }

    /// `remove`, but only while the record is still from an older transcoder: a proxy made (or marked current)
    /// meanwhile stays.
    pub fn remove_outdated(&self, fingerprint: &SourceFingerprint, kind: ProxyKind) {
        let key = (fingerprint.id(), kind);
        let removed = {
            let mut st = self.lock();
            match st.records.get(&key) {
                Some(r) if !r.is_current() => st.records.remove(&key),
                _ => None,
            }
        };
        if let Some(r) = removed {
            // A new proxy has the same file name; it is committed over this one, so delete only when none came since.
            if !self.lock().records.contains_key(&key) {
                fs::remove_file(self.file_url(&r)).ok();
            }
            self.write_index().ok();
            broadcast(&mut self.lock().removed_listeners, &r);
        }
    }

    /// Replaces the set of records in use; `evict`/`enforce_cap` never remove them.
    pub fn set_protected(&self, ids: BTreeSet<ProxyRecordID>) {
        self.lock().protected = ids;
    }

    /// The records in use.
    pub fn protected(&self) -> BTreeSet<ProxyRecordID> {
        self.lock().protected.clone()
    }

    /// Bytes of the protected records' files: when this reaches the cap, generating more proxies would only evict them.
    pub fn protected_bytes(&self) -> i64 {
        let ids = self.protected();
        self.all_records()
            .iter()
            .filter(|r| ids.contains(&ProxyRecordID::new(r)))
            .map(|r| file_size(&self.file_url(r)))
            .sum()
    }

    /// Removes every kind of `fingerprint`.
    pub fn remove_all(&self, fingerprint: &SourceFingerprint) {
        for k in ProxyKind::ALL {
            self.remove(fingerprint, k);
        }
    }

    /// Total bytes of indexed proxy files.
    pub fn total_size(&self) -> i64 {
        self.all_records().iter().map(|r| file_size(&self.file_url(r))).sum()
    }

    /// Deletes least-recently-used records until the total is at most `max_bytes`, never touching `extra`
    /// (e.g. the proxy that just finished) or the protected set. Returns what was removed (also sent to `removed_records`).
    pub fn evict(&self, max_bytes: i64, extra: &BTreeSet<ProxyRecordID>) -> Vec<ProxyRecord> {
        let mut protecting = extra.clone();
        protecting.extend(self.protected());
        let mut total = self.total_size();
        let mut removed = Vec::new();
        let mut lru = self.all_records();
        lru.sort_by(|a, b| by_time_then_name((a.last_access, &a.file_name), (b.last_access, &b.file_name)));
        for r in lru {
            if total <= max_bytes {
                break;
            }
            if protecting.contains(&ProxyRecordID::new(&r)) {
                continue;
            }
            total -= file_size(&self.file_url(&r));
            self.remove(&r.fingerprint, r.kind);
            removed.push(r);
        }
        removed
    }

    /// LRU eviction down to `settings().cache_cap_bytes`. Call after each finished job and once at launch.
    pub fn enforce_cap(&self, protecting: &BTreeSet<ProxyRecordID>) -> Vec<ProxyRecord> {
        let removed = self.evict(self.settings().cache_cap_bytes, protecting);
        if removed.is_empty() {
            self.flush_index();
        }
        removed
    }

    /// Deletes leftover `.partial` files (call at launch, when no job can be running). Returns the count.
    pub fn purge_partials(&self, keep: &BTreeSet<PathBuf>) -> usize {
        let Ok(entries) = fs::read_dir(&self.directory) else { return 0 };
        let mut n = 0;
        for f in entries.flatten().map(|e| e.path()) {
            if f.extension() == Some(OsStr::new("partial")) && !keep.contains(&f) && fs::remove_file(&f).is_ok() {
                n += 1;
            }
        }
        n
    }

    /// Records removed (evicted or deleted) after subscribing.
    pub fn removed_records(&self) -> Receiver<ProxyRecord> {
        let (tx, rx) = mpsc::channel();
        self.lock().removed_listeners.push(tx);
        rx
    }

    /// Records that became ready after subscribing.
    pub fn ready_records(&self) -> Receiver<ProxyRecord> {
        let (tx, rx) = mpsc::channel();
        self.lock().listeners.push(tx);
        rx
    }

    fn write_index(&self) -> io::Result<()> {
        // Records come out of the map in (fingerprint id, kind) order; Swift sorts by file name, which is the same string.
        let mut list: Vec<ProxyRecord> = self.lock().records.values().cloned().collect();
        list.sort_by(|a, b| a.file_name.cmp(&b.file_name));
        write_atomic(&self.index_path(), &sorted_json(&list)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ProxyDimensions;
    use crate::model::test_support::*;
    use sq_core_time::Time;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn the_old_bundle_named_folder_moves_to_the_one_cache_name() {
        let root = std::env::temp_dir().join(format!("sq-proxy-migrate-{}", std::process::id()));
        let root_s = root.to_string_lossy().into_owned();
        let env = |k: &str| matches!(k, "HOME" | "LOCALAPPDATA" | "XDG_CACHE_HOME").then(|| root_s.clone());
        let platform = Platform::current();
        let (new, old) =
            (ProxyCache::default_directory_for(platform, env), ProxyCache::legacy_directory_for(platform, env));
        assert_ne!(new, old);
        fs::create_dir_all(&old).ok();
        fs::write(old.join("a.proxyHalf.mov"), b"x").ok();
        assert_eq!(ProxyCache::default_directory(env), new);
        assert!(new.join("a.proxyHalf.mov").exists() && !old.exists(), "the proxies moved with the folder");
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn default_directory_follows_each_systems_cache_folder() {
        let env = |k: &str| {
            [("HOME", "/u"), ("LOCALAPPDATA", "C:/l"), ("XDG_CACHE_HOME", "/x")]
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| v.to_string())
        };
        let dir = |p| ProxyCache::default_directory_for(p, env);
        assert_eq!(dir(Platform::Mac), PathBuf::from("/u/Library/Caches/Sequence Studio/Proxies"));
        assert_eq!(dir(Platform::Windows), PathBuf::from("C:/l/Sequence Studio/Proxies"));
        assert_eq!(dir(Platform::Linux), PathBuf::from("/x/Sequence Studio/Proxies"));
        let home_only = |k: &str| (k == "HOME").then(|| "/u".to_string());
        assert_eq!(
            ProxyCache::default_directory_for(Platform::Linux, home_only),
            PathBuf::from("/u/.cache/Sequence Studio/Proxies")
        );
    }

    fn fp() -> SourceFingerprint {
        SourceFingerprint { size: 10, modified_millis: 5, head_hash: "aa".into(), tail_hash: "bb".into() }
    }

    fn record(kind: ProxyKind, f: &SourceFingerprint, created: f64) -> ProxyRecord {
        ProxyRecord::new(
            f.clone(),
            kind,
            ProxyCache::file_name(f, kind),
            ProxyDimensions { width: 1920, height: 1080 },
            Timestamp::from_unix_seconds(created),
            Time::new(5, 1),
        )
    }

    fn stage(cache: &ProxyCache, r: &ProxyRecord, bytes: usize) -> PathBuf {
        let p = cache.partial_url(&r.fingerprint, r.kind);
        write_file(&p, bytes, 1);
        p
    }

    fn add(cache: &ProxyCache, r: &ProxyRecord, bytes: usize) {
        cache.commit(&stage(cache, r, bytes), r).unwrap();
    }

    fn at(s: f64) -> Timestamp {
        Timestamp::from_unix_seconds(s)
    }

    /// Distinct fingerprint and record for the cap tests.
    fn rec(n: i64) -> ProxyRecord {
        let f =
            SourceFingerprint { size: n, modified_millis: 1, head_hash: format!("aa{n}"), tail_hash: format!("bb{n}") };
        let mut r = record(ProxyKind::ProxyHalf, &f, n as f64);
        r.dimensions = ProxyDimensions { width: 2, height: 2 };
        r
    }

    #[test]
    fn commit_lookup_and_persist() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let r = record(ProxyKind::ProxyHalf, &fp(), 1000.0);
        assert!(cache.lookup(&fp(), ProxyKind::ProxyHalf, at(1.0)).is_none());
        let p = stage(&cache, &r, 100);
        cache.commit(&p, &r).unwrap();
        assert!(!p.exists());
        assert_eq!(cache.lookup(&fp(), ProxyKind::ProxyHalf, at(1.0)), Some(r.clone()));
        assert!(cache.lookup(&fp(), ProxyKind::Optimized, at(1.0)).is_none());
        let reopened = ProxyCache::new(dir.0.clone());
        assert_eq!(reopened.lookup(&fp(), ProxyKind::ProxyHalf, at(1.0)), Some(r.clone()));
        assert!(reopened.file_url(&r).exists());
    }

    #[test]
    fn missing_file_drops_entry() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let r = record(ProxyKind::ProxyHalf, &fp(), 1000.0);
        add(&cache, &r, 100);
        fs::remove_file(cache.file_url(&r)).unwrap();
        assert!(cache.lookup(&fp(), ProxyKind::ProxyHalf, at(1.0)).is_none());
        assert!(cache.all_records().is_empty());
    }

    #[test]
    fn partials_are_not_ready() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let r = record(ProxyKind::ProxyHalf, &fp(), 1000.0);
        stage(&cache, &r, 100);
        assert!(cache.lookup(&fp(), ProxyKind::ProxyHalf, at(1.0)).is_none());
        assert_eq!(cache.purge_partials(&BTreeSet::new()), 1);
        assert!(!cache.partial_url(&fp(), ProxyKind::ProxyHalf).exists());
    }

    #[test]
    fn remove_and_size() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let r1 = record(ProxyKind::ProxyHalf, &fp(), 1000.0);
        let r2 = record(ProxyKind::ProxyQuarter, &fp(), 1000.0);
        add(&cache, &r1, 100);
        add(&cache, &r2, 50);
        assert_eq!(cache.total_size(), 150);
        cache.remove(&fp(), ProxyKind::ProxyHalf);
        assert_eq!(cache.total_size(), 50);
        cache.remove_all(&fp());
        assert!(cache.all_records().is_empty() && cache.total_size() == 0);
    }

    #[test]
    fn evict_oldest_first() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let f2 = SourceFingerprint { size: 11, modified_millis: 5, head_hash: "cc".into(), tail_hash: "dd".into() };
        let old = record(ProxyKind::ProxyHalf, &fp(), 1.0);
        let new = record(ProxyKind::ProxyHalf, &f2, 2.0);
        add(&cache, &old, 100);
        add(&cache, &new, 100);
        let removed = cache.evict(100, &BTreeSet::new());
        assert_eq!(removed, vec![old]);
        assert!(cache.lookup(&f2, ProxyKind::ProxyHalf, at(1.0)).is_some());
    }

    #[test]
    fn commit_broadcasts_change() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let rx = cache.ready_records();
        let r = record(ProxyKind::ProxyHalf, &fp(), 1000.0);
        add(&cache, &r, 100);
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).ok(), Some(r));
    }

    /// A lookup racing with a replacing commit must never drop the record the commit just stored.
    #[test]
    fn lookup_never_drops_record_replaced_by_commit() {
        let dir = TempDir::new();
        let src = dir.join("s.bin");
        write_file(&src, 200_000, 1);
        let f = SourceFingerprint::compute(&src).unwrap();
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let rec = record(ProxyKind::ProxyHalf, &f, 1000.0);
        add(&cache, &rec, 1);
        for _ in 0..100 {
            let p = stage(&cache, &rec, 1);
            let reader = {
                let (cache, f) = (Arc::clone(&cache), f.clone());
                std::thread::spawn(move || {
                    for _ in 0..500 {
                        cache.lookup(&f, ProxyKind::ProxyHalf, at(1.0));
                    }
                })
            };
            cache.commit(&p, &rec).unwrap();
            reader.join().unwrap();
            assert!(cache.lookup(&f, ProxyKind::ProxyHalf, at(1.0)).is_some());
        }
    }

    /// Concurrent `update_settings` must leave disk equal to memory.
    #[test]
    fn concurrent_settings_updates_end_consistent_on_disk() {
        let dir = TempDir::new();
        for round in 0..20 {
            let cache = Arc::new(ProxyCache::new(dir.join(&format!("c-{round}"))));
            let threads: Vec<_> = (1..=16)
                .map(|i| {
                    let cache = Arc::clone(&cache);
                    std::thread::spawn(move || cache.update_settings(|s| s.cache_cap_bytes = i).ok())
                })
                .collect();
            for t in threads {
                t.join().unwrap();
            }
            assert_eq!(ProxyCache::new(cache.directory().to_path_buf()).settings(), cache.settings());
        }
    }

    #[test]
    fn default_cap_is_50_gb() {
        let dir = TempDir::new();
        assert_eq!(ProxyCache::new(dir.0.clone()).settings().cache_cap_bytes, 50_000_000_000);
    }

    #[test]
    fn settings_persist() {
        let dir = TempDir::new();
        let c = ProxyCache::new(dir.0.clone());
        c.update_settings(|s| {
            s.cache_cap_bytes = 123;
            s.use_proxies_for_playback = true;
        })
        .unwrap();
        let c2 = ProxyCache::new(dir.0.clone());
        assert_eq!(c2.settings(), ProxySettings { cache_cap_bytes: 123, use_proxies_for_playback: true });
    }

    #[test]
    fn lookup_refreshes_lru_so_older_unused_goes_first() {
        let dir = TempDir::new();
        let c = ProxyCache::new(dir.0.clone());
        let (a, b, d) = (rec(1), rec(2), rec(3));
        for r in [&a, &b, &d] {
            add(&c, r, 100);
        }
        // a is oldest by creation but was just used
        assert!(c.lookup(&a.fingerprint, ProxyKind::ProxyHalf, at(100.0)).is_some());
        c.update_settings(|s| s.cache_cap_bytes = 200).unwrap();
        let removed = c.enforce_cap(&BTreeSet::new());
        assert_eq!(removed.iter().map(|r| r.file_name.clone()).collect::<Vec<_>>(), vec![b.file_name.clone()]);
        assert_eq!(c.total_size(), 200);
    }

    #[test]
    fn evicts_until_under_cap_and_persists_last_access() {
        let dir = TempDir::new();
        let c = ProxyCache::new(dir.0.clone());
        for i in 1..=4 {
            add(&c, &rec(i), 100);
        }
        c.update_settings(|s| s.cache_cap_bytes = 150).unwrap();
        let removed = c.enforce_cap(&BTreeSet::new());
        assert!(removed.len() == 3 && c.total_size() == 100);
        assert!(c.lookup(&rec(4).fingerprint, ProxyKind::ProxyHalf, at(1.0)).is_some());
        c.flush_index();
        assert_eq!(ProxyCache::new(dir.0.clone()).all_records().len(), 1);
    }

    #[test]
    fn protected_record_survives_even_above_cap() {
        let dir = TempDir::new();
        let c = ProxyCache::new(dir.0.clone());
        let only = rec(1);
        add(&c, &only, 100);
        c.update_settings(|s| s.cache_cap_bytes = 10).unwrap();
        assert!(c.enforce_cap(&BTreeSet::from([ProxyRecordID::new(&only)])).is_empty());
        assert!(c.lookup(&only.fingerprint, ProxyKind::ProxyHalf, at(1.0)).is_some());
        // unprotected it would go
        assert_eq!(c.enforce_cap(&BTreeSet::new()).len(), 1);
    }

    #[test]
    fn protected_records_are_never_evicted() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let (in_use, other, newest) = (rec(1), rec(2), rec(3));
        for r in [&in_use, &other, &newest] {
            add(&cache, r, 100);
        }
        cache.set_protected(BTreeSet::from([ProxyRecordID::new(&in_use)]));
        // The in-use proxy is the least recently used one (its last access is stale), yet it stays.
        let removed = cache.evict(200, &BTreeSet::from([ProxyRecordID::new(&newest)]));
        assert_eq!(removed, vec![other]);
        assert!(cache.lookup(&in_use.fingerprint, ProxyKind::ProxyHalf, at(1.0)).is_some());
        assert_eq!(cache.protected_bytes(), 100);
    }

    #[test]
    fn removals_are_broadcast() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let (a, b) = (rec(1), rec(2));
        add(&cache, &a, 100);
        add(&cache, &b, 100);
        let rx = cache.removed_records();
        cache.evict(100, &BTreeSet::new());
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).ok(), Some(a));
        cache.remove(&b.fingerprint, ProxyKind::ProxyHalf);
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).ok(), Some(b));
    }

    /// The build is part of a record's identity (the "still the record I read" checks must see `mark_current`),
    /// and `remove_outdated` leaves a record that became current.
    #[test]
    fn a_record_marked_current_is_not_the_old_one() {
        let dir = TempDir::new();
        let cache = ProxyCache::new(dir.0.clone());
        let f = SourceFingerprint { size: 1, modified_millis: 2, head_hash: "a".into(), tail_hash: "b".into() };
        let mut old = record(ProxyKind::ProxyHalf, &f, 10.0);
        old.build = 0;
        let mut new = old.clone();
        new.build = ProxyRecord::CURRENT_BUILD;
        assert_ne!(old, new);
        add(&cache, &old, 1);
        cache.mark_current(&f, ProxyKind::ProxyHalf);
        cache.remove_outdated(&f, ProxyKind::ProxyHalf);
        let kept = cache.current_lookup(&f, ProxyKind::ProxyHalf, at(1.0)).unwrap();
        assert!(cache.file_url(&kept).exists());
    }
}
