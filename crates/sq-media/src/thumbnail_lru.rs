// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Thumbnailer.swift (ThumbnailKey, ThumbnailLRU)
//! Byte-capped LRU of decoded thumbnails. Pure value logic; the caller owns the pictures and says what each costs.

use sq_core_model::PixelAspect;
use sq_core_time::{Id, Time};
use std::collections::HashMap;

/// Key of one cached thumbnail. Time is quantized to microseconds so equal rational times compare equal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ThumbnailKey {
    pub media: Id,
    pub micros: i64,
    /// Pixel height; 0 means native size.
    pub height: i64,
    /// The pixel aspect the picture is shown with when it is not the file's own; None = as the file says.
    pub pixel_aspect: Option<PixelAspect>,
}

impl ThumbnailKey {
    pub fn new(media: Id, time: Time, height: i64, pixel_aspect: Option<PixelAspect>) -> ThumbnailKey {
        // Round half away from zero, like `CMTimeConvertScale(.roundHalfAwayFromZero)`.
        let num = i128::from(time.value()) * 1_000_000;
        let den = i128::from(time.timescale().max(1));
        let half = den / 2;
        let micros = if num >= 0 { (num + half) / den } else { -((-num + half) / den) };
        ThumbnailKey { media, micros: micros as i64, height: height.max(0), pixel_aspect }
    }

    /// Disk cache file name; the plain form is unchanged so existing caches stay valid.
    pub fn file_name(&self) -> String {
        let par = self.pixel_aspect.map(|p| format!("_par{}x{}", p.num(), p.den())).unwrap_or_default();
        format!("{}_{}_{}{}.png", self.media, self.micros, self.height, par)
    }
}

struct Entry<V> {
    value: V,
    cost: usize,
    stamp: u64,
}

/// Evicts the least recently used picture first; a picture larger than the cap is not stored.
pub struct ThumbnailLru<V> {
    bytes: usize,
    capacity: usize,
    /// `MemoryPressure::budget(capacity)` in force.
    limit: usize,
    entries: HashMap<ThumbnailKey, Entry<V>>,
    clock: u64,
}

impl<V: Clone> ThumbnailLru<V> {
    pub fn new(capacity: usize) -> ThumbnailLru<V> {
        ThumbnailLru { bytes: 0, capacity, limit: capacity, entries: HashMap::new(), clock: 0 }
    }

    pub fn bytes(&self) -> usize {
        self.bytes
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// The cap in force (the capacity, or its share under memory pressure).
    pub fn effective_capacity(&self) -> usize {
        self.limit
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }

    pub fn get(&mut self, k: &ThumbnailKey) -> Option<V> {
        let e = self.entries.get_mut(k)?;
        self.clock += 1;
        e.stamp = self.clock;
        Some(e.value.clone())
    }

    pub fn put(&mut self, k: ThumbnailKey, value: V, cost: usize) {
        let cost = cost.max(1);
        if let Some(old) = self.entries.remove(&k) {
            self.bytes -= old.cost;
        }
        if cost > self.limit {
            return;
        }
        self.clock += 1;
        self.entries.insert(k, Entry { value, cost, stamp: self.clock });
        self.bytes += cost;
        self.trim();
    }

    /// Memory pressure: caps the LRU at `limit` (the level's share of the capacity, `level.budget(capacity())`) and
    /// drops the oldest beyond it; the full capacity lifts the cap.
    pub fn apply_limit(&mut self, limit: usize) {
        self.limit = limit.min(self.capacity);
        self.trim();
    }

    fn trim(&mut self) {
        while self.bytes > self.limit {
            let Some(oldest) = self.entries.iter().min_by_key(|(_, e)| e.stamp).map(|(k, _)| *k) else { break };
            if let Some(e) = self.entries.remove(&oldest) {
                self.bytes -= e.cost;
            }
        }
    }

    /// Drops the pictures of one media (e.g. after relink).
    pub fn remove_media(&mut self, id: Id) {
        let keys: Vec<ThumbnailKey> = self.entries.keys().filter(|k| k.media == id).copied().collect();
        for k in keys {
            if let Some(e) = self.entries.remove(&k) {
                self.bytes -= e.cost;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ONE: usize = 100 * 100 * 4;

    fn keys(id: Id, n: i64) -> Vec<ThumbnailKey> {
        (0..n).map(|i| ThumbnailKey::new(id, Time::new(i, 1), 100, None)).collect()
    }

    #[test]
    fn lru_evicts_oldest_and_respects_cap() {
        let mut lru = ThumbnailLru::new(3 * ONE);
        let id = Id::from_u128(1);
        let k = keys(id, 4);
        for key in &k[..3] {
            lru.put(*key, 1, ONE);
        }
        lru.get(&k[0]); // k1 is now oldest
        lru.put(k[3], 1, ONE);
        assert!(lru.get(&k[1]).is_none() && lru.get(&k[0]).is_some() && lru.count() == 3);
        assert!(lru.bytes() <= lru.capacity());
        lru.put(ThumbnailKey::new(id, Time::ZERO, 9, None), 1, 4 * ONE); // larger than the cap: not stored
        assert!(lru.bytes() <= lru.capacity());
    }

    #[test]
    fn lru_shrinks_under_memory_pressure_and_grows_back() {
        let mut lru = ThumbnailLru::new(4 * ONE);
        let k = keys(Id::from_u128(1), 6);
        for key in &k[..4] {
            lru.put(*key, 1, ONE);
        }
        lru.get(&k[0]); // k1 is the oldest now
        lru.apply_limit(4 * ONE / 2); // warning: half, the newest two
        assert!(lru.count() == 2 && lru.bytes() <= 2 * ONE);
        assert!(lru.get(&k[0]).is_some() && lru.get(&k[3]).is_some());
        lru.put(k[4], 1, ONE); // the cap holds while the warning lasts
        assert_eq!(lru.count(), 2);
        lru.apply_limit(4 * ONE / 4); // critical: a quarter
        assert_eq!(lru.count(), 1);
        lru.apply_limit(4 * ONE);
        for i in [5, 1, 2] {
            lru.put(k[i], 1, ONE);
        }
        assert_eq!(lru.count(), 4);
    }

    #[test]
    fn key_quantises_equal_rational_times() {
        let id = Id::from_u128(1);
        assert_eq!(
            ThumbnailKey::new(id, Time::new(1, 2), 10, None),
            ThumbnailKey::new(id, Time::new(600, 1200), 10, None)
        );
    }

    #[test]
    fn file_names_keep_the_plain_form_and_separate_pixel_aspects() {
        let id = Id::from_u128(1);
        let plain = ThumbnailKey::new(id, Time::ZERO, 90, None);
        let wide = ThumbnailKey::new(id, Time::ZERO, 90, PixelAspect::new(2, 1));
        assert_ne!(plain, wide);
        assert_eq!(plain.file_name(), format!("{id}_0_90.png"));
        assert_eq!(wide.file_name(), format!("{id}_0_90_par2x1.png"));
    }

    #[test]
    fn remove_media_drops_only_that_media() {
        let (a, b) = (Id::from_u128(1), Id::from_u128(2));
        let mut lru = ThumbnailLru::new(10 * ONE);
        lru.put(keys(a, 1)[0], 1, ONE);
        lru.put(keys(b, 1)[0], 1, ONE);
        lru.remove_media(a);
        assert!(lru.count() == 1 && lru.bytes() == ONE);
    }
}
