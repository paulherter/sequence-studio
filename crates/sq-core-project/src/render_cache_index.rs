// Swift: RenderCacheIndex.swift
//! Preview render cache, model parts 2 and 3: which segment keys have a rendered file, how big, last used, and when and
//! what the background renderer works on.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use sq_core_time::{Time, Timestamp};

use crate::cache_disk_policy::{CacheDiskPolicy, CacheEntry};
use crate::render_cache_plan::RenderCacheSegment;

/// One rendered file of the cache.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderCacheIndexEntry {
    pub bytes: i64,
    pub last_use: Timestamp,
    pub duration: Time,
}

/// Lives next to the files in the cache folder (never in the project file). Entries are keyed by content, so an edit does
/// not "invalidate" anything: the changed segment gets a new key and the old entry ages out (`evict`, `purge`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RenderCacheIndex {
    entries: BTreeMap<String, RenderCacheIndexEntry>,
}

impl RenderCacheIndex {
    /// An empty index.
    pub fn new() -> RenderCacheIndex {
        RenderCacheIndex::default()
    }

    /// Key to entry.
    pub fn entries(&self) -> &BTreeMap<String, RenderCacheIndexEntry> {
        &self.entries
    }

    /// True when `key` has a rendered file.
    pub fn contains(&self, key: &str) -> bool {
        self.entries.contains_key(key)
    }

    /// Bytes of all rendered files together.
    pub fn total_bytes(&self) -> i64 {
        self.entries.values().map(|e| e.bytes).sum()
    }

    /// Adds or replaces the entry of `key`.
    pub fn record(&mut self, key: &str, bytes: i64, duration: Time, now: Timestamp) {
        self.entries.insert(key.to_string(), RenderCacheIndexEntry { bytes, last_use: now, duration });
    }

    /// Marks `key` as used now.
    pub fn touch(&mut self, key: &str, now: Timestamp) {
        if let Some(e) = self.entries.get_mut(key) {
            e.last_use = now;
        }
    }

    /// Forgets `key`.
    pub fn remove(&mut self, key: &str) {
        self.entries.remove(key);
    }

    /// Removes entries unused for `max_age` seconds; returns their keys (the caller deletes the files).
    pub fn purge(&mut self, max_age: f64, now: Timestamp, protecting: &BTreeSet<String>) -> Vec<String> {
        let gone: Vec<String> = self
            .entries
            .iter()
            .filter(|(k, e)| {
                now.reference_seconds() - e.last_use.reference_seconds() > max_age && !protecting.contains(*k)
            })
            .map(|(k, _)| k.clone())
            .collect();
        for k in &gone {
            self.entries.remove(k);
        }
        gone // BTreeMap order is sorted
    }

    /// Removes least recently used entries until the rest fits `limit_bytes`; `protecting` (keys of the current timeline)
    /// stay unless nothing else is left to free.
    pub fn evict(&mut self, limit_bytes: i64, protecting: &BTreeSet<String>) -> Vec<String> {
        let list: Vec<CacheEntry> = self
            .entries
            .iter()
            .map(|(k, e)| CacheEntry { id: k.clone(), bytes: e.bytes, last_use: e.last_use })
            .collect();
        let mut gone = CacheDiskPolicy::eviction_plan(&list, limit_bytes, protecting);
        let freed: i64 = gone.iter().map(|k| self.entries.get(k).map_or(0, |e| e.bytes)).sum();
        if self.total_bytes() - freed > limit_bytes {
            gone = CacheDiskPolicy::eviction_plan(&list, limit_bytes, &BTreeSet::new());
        }
        for k in &gone {
            self.entries.remove(k);
        }
        gone
    }

    /// The cached heavy segment that covers `t`, for playback to read instead of rendering.
    pub fn cached_segment<'a>(&self, t: Time, segments: &'a [RenderCacheSegment]) -> Option<&'a RenderCacheSegment> {
        segments.iter().find(|s| s.is_heavy && s.range.contains(t) && self.contains(&s.key))
    }
}

/// When and what the background renderer works on.
pub struct RenderCacheScheduler;

/// Everything `RenderCacheScheduler::next_job` looks at besides the segments.
pub struct SchedulerState<'a> {
    pub index: &'a RenderCacheIndex,
    pub playhead: Time,
    pub dropped_frames: &'a [Time],
    pub playing: bool,
    pub throttled: bool,
    pub last_edit: Timestamp,
    pub now: Timestamp,
    pub idle_delay: f64,
}

impl RenderCacheScheduler {
    /// F1: 0.3 s idle.
    pub const DEFAULT_IDLE_DELAY: f64 = 0.3;

    /// The next heavy, uncached segment to render, or `None` to do nothing now. Nothing runs while playing, while the
    /// machine is throttled (`PowerPolicy`), or within `idle_delay` of the last edit. Segments where frames dropped come
    /// first, then the nearest to the playhead. A changed key simply makes a different segment pending, which is how
    /// running work is canceled: the caller re-asks after every edit and drops a job whose key is no longer the answer.
    pub fn next_job<'a>(
        segments: &'a [RenderCacheSegment],
        state: &SchedulerState<'_>,
    ) -> Option<&'a RenderCacheSegment> {
        if state.playing
            || state.throttled
            || state.now.reference_seconds() - state.last_edit.reference_seconds() < state.idle_delay
        {
            return None;
        }
        let distance = |s: &RenderCacheSegment| {
            if s.range.contains(state.playhead) {
                Time::ZERO
            } else if state.playhead < s.range.start {
                s.range.start - state.playhead
            } else {
                state.playhead - s.range.end()
            }
        };
        let dropped = |s: &RenderCacheSegment| state.dropped_frames.iter().any(|f| s.range.contains(*f));
        let before = |a: &RenderCacheSegment, b: &RenderCacheSegment| {
            if dropped(a) != dropped(b) {
                return dropped(a);
            }
            let (d0, d1) = (distance(a), distance(b));
            if d0 != d1 { d0 < d1 } else { a.range.start < b.range.start }
        };
        let mut best: Option<&RenderCacheSegment> = None;
        for s in segments.iter().filter(|s| s.is_heavy && !state.index.contains(&s.key)) {
            if best.is_none_or(|b| before(s, b)) {
                best = Some(s);
            }
        }
        best
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render_cache_plan::tests::{blur, clip, timeline};
    use crate::render_cache_plan::{RenderCacheContext, RenderCachePlan};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn at(seconds: f64) -> Timestamp {
        Timestamp::from_unix_seconds(seconds)
    }

    fn keys(v: &[&str]) -> BTreeSet<String> {
        v.iter().map(|k| k.to_string()).collect()
    }

    #[test]
    fn index_evicts_least_recently_used_and_protects_current() {
        let mut i = RenderCacheIndex::new();
        i.record("a", 100, s(1), at(1000.0));
        i.record("b", 100, s(1), at(1010.0));
        i.record("c", 100, s(1), at(1020.0));
        i.touch("a", at(1030.0));
        assert_eq!(i.evict(200, &BTreeSet::new()), ["b"]);
        assert_eq!(i.evict(100, &keys(&["a"])), ["c"]);
        assert!(i.contains("a") && !i.contains("c"));
        let gone = i.purge(5.0, at(1100.0), &BTreeSet::new());
        assert!(gone == ["a"] && i.entries().is_empty());
    }

    #[test]
    fn scheduler_waits_then_picks_dropped_frames_then_nearest() {
        let ctx = RenderCacheContext::new("r1", "rec709");
        let t = timeline(vec![vec![
            clip(0, 2, 1, vec![blur()]),
            clip(2, 2, 2, vec![blur()]),
            clip(4, 2, 3, vec![blur()]),
            clip(6, 2, 4, vec![]),
        ]]);
        let segs = RenderCachePlan::segments(&t, None, &ctx);
        let edit = at(0.0);
        let empty = RenderCacheIndex::new();
        let next =
            |idx: &RenderCacheIndex, playhead: i64, dropped: &[Time], playing: bool, throttled: bool, now: f64| {
                let state = SchedulerState {
                    index: idx,
                    playhead: s(playhead),
                    dropped_frames: dropped,
                    playing,
                    throttled,
                    last_edit: edit,
                    now: at(now),
                    idle_delay: RenderCacheScheduler::DEFAULT_IDLE_DELAY,
                };
                RenderCacheScheduler::next_job(&segs, &state).map(|g| g.range.start)
            };
        assert!(next(&empty, 0, &[], false, false, 0.1).is_none() && next(&empty, 0, &[], false, false, 0.5).is_some());
        assert!(next(&empty, 0, &[], true, false, 10.0).is_none() && next(&empty, 0, &[], false, true, 10.0).is_none());
        assert_eq!(next(&empty, 0, &[], false, false, 10.0), Some(s(0)));
        assert_eq!(next(&empty, 5, &[], false, false, 10.0), Some(s(4)));
        assert_eq!(next(&empty, 0, &[s(3)], false, false, 10.0), Some(s(2)));
        let mut idx = RenderCacheIndex::new();
        idx.record(&segs[0].key, 1, s(2), edit);
        assert_eq!(next(&idx, 0, &[], false, false, 10.0), Some(s(2)));
        assert_eq!(idx.cached_segment(s(1), &segs).map(|g| g.range.start), Some(s(0)));
        assert!(idx.cached_segment(s(3), &segs).is_none());
    }
}
