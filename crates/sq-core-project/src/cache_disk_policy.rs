// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared disk-space rule for every cache.
// Swift: CacheDiskPolicy.swift
//
// Not ported: `volumeSpace(of:)` / `realSpace` read the volume through Foundation resource values, a platform backend.
// The caller passes the reader to `CacheDiskPolicy::new`; there is no `standard` policy in this crate.

use sq_core_time::Timestamp;
use std::collections::BTreeSet;
use std::path::Path;

/// One cached file for `CacheDiskPolicy::eviction_plan`.
#[derive(Clone, Debug, PartialEq)]
pub struct CacheEntry {
    /// Identity (a key or file name).
    pub id: String,
    /// Size on disk.
    pub bytes: i64,
    /// When it was last used.
    pub last_use: Timestamp,
}

/// Free and total bytes of a volume; `None` when unknown.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VolumeSpace {
    /// Free bytes.
    pub free: Option<i64>,
    /// Total bytes.
    pub total: Option<i64>,
}

/// Shared disk-space rule for every cache (proxies, previews, waveforms): stop writing when the volume would drop
/// below max(5 GB, min(5 % of its size, 10 GB)) free, and evict least recently used files beyond a size cap.
/// The free-space reader is injectable; unknown space allows the write.
pub struct CacheDiskPolicy {
    space: Box<dyn Fn(&Path) -> VolumeSpace>,
}

impl CacheDiskPolicy {
    /// Smallest floor: 5 GB.
    pub const MINIMUM_FLOOR_BYTES: i64 = 5 << 30;
    /// Share of the volume kept free.
    pub const FLOOR_FRACTION: f64 = 0.05;
    /// A 1 TB disk would otherwise demand 50 GB free and block every cache on a normally full Mac.
    pub const MAXIMUM_FLOOR_BYTES: i64 = 10 << 30;

    /// A policy reading the volume with `space`.
    pub fn new(space: impl Fn(&Path) -> VolumeSpace + 'static) -> CacheDiskPolicy {
        CacheDiskPolicy { space: Box::new(space) }
    }

    /// Never blocks (free space unknown): for tests that must not depend on this machine's disk.
    pub fn unchecked() -> CacheDiskPolicy {
        CacheDiskPolicy::new(|_| VolumeSpace::default())
    }

    /// The free bytes the volume must keep.
    pub fn floor_bytes(volume_bytes: Option<i64>) -> i64 {
        let share = (volume_bytes.unwrap_or(0) as f64 * Self::FLOOR_FRACTION) as i64;
        Self::MINIMUM_FLOOR_BYTES.max(Self::MAXIMUM_FLOOR_BYTES.min(share))
    }

    /// True when the volume is already at or under the floor.
    pub fn is_below_floor(&self, url: &Path) -> bool {
        !self.allows_write(0, url)
    }

    /// True when writing `bytes` leaves at least the floor free.
    pub fn allows_write(&self, bytes: i64, url: &Path) -> bool {
        let s = (self.space)(url);
        let Some(free) = s.free else { return true };
        free - bytes.max(0) >= Self::floor_bytes(s.total)
    }

    /// IDs to delete (oldest use first) so the rest fits `limit_bytes`; `protecting` entries are never chosen.
    pub fn eviction_plan(entries: &[CacheEntry], limit_bytes: i64, protecting: &BTreeSet<String>) -> Vec<String> {
        let mut total: i64 = entries.iter().map(|e| e.bytes).sum();
        let mut sorted: Vec<&CacheEntry> = entries.iter().collect();
        sorted.sort_by(|a, b| {
            a.last_use.partial_cmp(&b.last_use).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.id.cmp(&b.id))
        });
        let mut out = Vec::new();
        for e in sorted {
            if total <= limit_bytes {
                break;
            }
            if protecting.contains(&e.id) {
                continue;
            }
            out.push(e.id.clone());
            total -= e.bytes;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: i64 = 1 << 30;

    fn space(free: Option<i64>, total: Option<i64>) -> CacheDiskPolicy {
        CacheDiskPolicy::new(move |_| VolumeSpace { free, total })
    }

    fn entry(id: &str, last_use: f64) -> CacheEntry {
        CacheEntry { id: id.into(), bytes: 4, last_use: Timestamp::from_unix_seconds(last_use) }
    }

    #[test]
    fn floor_is_five_gb_or_five_percent() {
        assert_eq!(CacheDiskPolicy::floor_bytes(Some(64 * GB)), 5 * GB);
        assert_eq!(CacheDiskPolicy::floor_bytes(Some(2000 * GB)), 10 * GB);
        assert_eq!(CacheDiskPolicy::floor_bytes(None), 5 * GB);
    }

    #[test]
    fn floor_of_128_gb_disk() {
        assert_eq!(CacheDiskPolicy::floor_bytes(Some(128 * GB)), ((128 * GB) as f64 * 0.05) as i64);
    }

    #[test]
    fn allows_only_while_above_floor_after_write() {
        let p = space(Some(20 * GB), Some(256 * GB));
        let url = Path::new("/x");
        assert!(p.allows_write(GB, url));
        assert!(!p.allows_write(11 * GB, url)); // 20 - 11 < 10 (floor capped at 10 GB)
    }

    #[test]
    fn unknown_space_allows_write() {
        assert!(space(None, None).allows_write(100 * GB, Path::new("/x")));
        assert!(CacheDiskPolicy::unchecked().allows_write(100 * GB, Path::new("/x")));
    }

    #[test]
    fn below_floor_blocks_even_zero_bytes() {
        let p = space(Some(2 * GB), Some(256 * GB));
        assert!(p.is_below_floor(Path::new("/x")));
        assert!(!p.allows_write(0, Path::new("/x")));
    }

    #[test]
    fn lru_plan_removes_oldest_first_until_fits() {
        let entries = [entry("a", 3.0), entry("b", 1.0), entry("c", 2.0)];
        let none = BTreeSet::new();
        assert_eq!(CacheDiskPolicy::eviction_plan(&entries, 8, &none), ["b"]);
        assert_eq!(CacheDiskPolicy::eviction_plan(&entries, 4, &none), ["b", "c"]);
        assert!(CacheDiskPolicy::eviction_plan(&entries, 12, &none).is_empty());
    }

    #[test]
    fn lru_plan_skips_protected() {
        let entries = [entry("a", 1.0), entry("b", 2.0)];
        let protecting = BTreeSet::from(["a".to_string()]);
        assert_eq!(CacheDiskPolicy::eviction_plan(&entries, 4, &protecting), ["b"]);
    }
}
