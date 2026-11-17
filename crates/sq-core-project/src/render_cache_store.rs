// SPDX-License-Identifier: GPL-3.0-or-later
//! Preview render cache, model part 4: files and index in one folder (`<cache root>/RenderCache`). One file per segment key
//! (`<key>.mov`), `index.json` beside them. Writes obey the shared disk floor (`CacheDiskPolicy`); the byte cap and age
//! purge delete files through `RenderCacheIndex`.
// Swift: RenderCacheStore.swift
//
// `index.json` keeps Swift's shape: `lastUse` is seconds since 1970 (the store's `.secondsSince1970` date strategy), not
// the reference-date seconds `Timestamp` writes by itself, so the file is converted at the boundary.

use crate::cache_disk_policy::CacheDiskPolicy;
use crate::render_cache_index::RenderCacheIndex;
use serde::{Deserialize, Serialize};
use sq_core_time::{Time, Timestamp};
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::PathBuf;

/// Files and index of the preview render cache.
pub struct RenderCacheStore {
    /// The cache folder.
    pub directory: PathBuf,
    /// Most bytes the cache keeps.
    pub byte_cap: i64,
    /// The shared disk-space rule.
    pub disk: CacheDiskPolicy,
}

#[derive(Serialize, Deserialize)]
struct WireIndex {
    entries: BTreeMap<String, WireEntry>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireEntry {
    bytes: i64,
    last_use: f64,
    duration: Time,
}

impl RenderCacheStore {
    /// 20 GB.
    pub const DEFAULT_BYTE_CAP: i64 = 20 << 30;
    /// 14 days, in seconds.
    pub const DEFAULT_MAX_AGE: f64 = 14.0 * 86400.0;

    /// A store over `directory`.
    pub fn new(directory: PathBuf, byte_cap: i64, disk: CacheDiskPolicy) -> RenderCacheStore {
        RenderCacheStore { directory, byte_cap, disk }
    }

    /// The rendered file of a segment key.
    pub fn file_url(&self, key: &str) -> PathBuf {
        self.directory.join(format!("{key}.mov"))
    }

    fn index_url(&self) -> PathBuf {
        self.directory.join("index.json")
    }

    /// Missing or unreadable index = empty cache; entries whose file is gone are dropped.
    pub fn load(&self) -> RenderCacheIndex {
        let Some(wire) = fs::read(self.index_url()).ok().and_then(|d| serde_json::from_slice::<WireIndex>(&d).ok())
        else {
            return RenderCacheIndex::new();
        };
        let mut index = RenderCacheIndex::new();
        for (key, e) in wire.entries {
            if self.file_url(&key).exists() {
                index.record(&key, e.bytes, e.duration, Timestamp::from_unix_seconds(e.last_use));
            }
        }
        index
    }

    /// Writes `index.json`.
    pub fn save(&self, index: &RenderCacheIndex) -> io::Result<()> {
        fs::create_dir_all(&self.directory)?;
        let entries = index
            .entries()
            .iter()
            .map(|(k, e)| {
                (k.clone(), WireEntry { bytes: e.bytes, last_use: e.last_use.unix_seconds(), duration: e.duration })
            })
            .collect();
        let data = serde_json::to_vec(&WireIndex { entries }).map_err(io::Error::other)?;
        let tmp = self.directory.join(".index.json.tmp");
        fs::write(&tmp, data)?;
        fs::rename(&tmp, self.index_url())
    }

    /// False when writing `bytes` would drop the volume below the free-space floor.
    pub fn may_write(&self, bytes: i64) -> bool {
        self.disk.allows_write(bytes, &self.directory)
    }

    /// Registers a finished segment file, then applies age purge and the byte cap; deletes the freed files.
    pub fn commit(
        &self,
        key: &str,
        duration: Time,
        index: &mut RenderCacheIndex,
        protecting: &BTreeSet<String>,
        now: Timestamp,
    ) -> io::Result<()> {
        let size = i64::try_from(fs::metadata(self.file_url(key))?.len()).unwrap_or(0);
        index.record(key, size, duration, now);
        let mut keep = protecting.clone();
        keep.insert(key.to_string());
        let mut gone = index.purge(Self::DEFAULT_MAX_AGE, now, &keep);
        gone.extend(index.evict(self.byte_cap, &keep));
        for k in gone {
            let _ = fs::remove_file(self.file_url(&k));
        }
        self.save(index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::tests::TempDir;

    #[test]
    fn store_commits_caps_and_reloads() {
        let dir = TempDir::new();
        let store = RenderCacheStore::new(dir.path(), 150, CacheDiskPolicy::unchecked());
        let mut idx = store.load();
        let t0 = 5000.0;
        for (n, k) in ["a", "b"].into_iter().enumerate() {
            fs::write(store.file_url(k), vec![1u8; 100]).unwrap();
            let now = Timestamp::from_unix_seconds(t0 + n as f64);
            store.commit(k, Time::seconds(1), &mut idx, &BTreeSet::new(), now).unwrap();
        }
        assert!(!idx.contains("a") && idx.contains("b"));
        assert!(!store.file_url("a").exists());
        assert!(store.load().contains("b"));
        fs::remove_file(store.file_url("b")).unwrap();
        assert!(!store.load().contains("b"));
        assert!(store.may_write(1 << 40));
    }

    #[test]
    fn index_file_keeps_unix_seconds() {
        let dir = TempDir::new();
        let store = RenderCacheStore::new(dir.path(), RenderCacheStore::DEFAULT_BYTE_CAP, CacheDiskPolicy::unchecked());
        fs::write(store.file_url("k"), [1u8; 10]).unwrap();
        let mut idx = RenderCacheIndex::new();
        store.commit("k", Time::seconds(2), &mut idx, &BTreeSet::new(), Timestamp::from_unix_seconds(5000.0)).unwrap();
        let text = fs::read_to_string(dir.path().join("index.json")).unwrap();
        assert!(text.contains("\"lastUse\":5000"), "{text}");
        assert!(store.load().entries().get("k").is_some_and(|e| e.last_use == Timestamp::from_unix_seconds(5000.0)));
    }
}
