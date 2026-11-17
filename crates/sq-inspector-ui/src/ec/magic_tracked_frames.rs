// Swift: MagicTrackedFrames.swift
//! Source times (seconds) of the tracked frames of Magic masks, by matte cache key, for the keyframe lanes.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;

use crate::ec::prelude::*;
use sq_analysis::magic_matte_store_unavailable::{MagicFrameSnapshot, MagicMatteStore};
use sq_core_masks::magic_follow::MagicFollower;
use sq_core_model::{Clip, ClipMask};
use sq_core_time::{Id, Time};

// shortcut: the store is read synchronously on first ask (Swift's `loadsInBackground: false` path) and `changed` is the
// `revision` counter, not a notification. Upgrade when the matte store loads on a worker.
/// The Magic tracked frames of the lanes: the matte store plus a cache of its times.
pub struct MagicTrackedFrames {
    store: MagicMatteStore,
    cache: RefCell<BTreeMap<String, Vec<f64>>>,
    /// Bumped on every change (lane display caches compare it).
    revision: Cell<u64>,
}

impl MagicTrackedFrames {
    pub fn new(store: MagicMatteStore) -> MagicTrackedFrames {
        MagicTrackedFrames { store, cache: RefCell::new(BTreeMap::new()), revision: Cell::new(0) }
    }

    pub fn store(&self) -> &MagicMatteStore {
        &self.store
    }

    pub fn revision(&self) -> u64 {
        self.revision.get()
    }

    /// Sorted source seconds of the frames tracked under `key`.
    pub fn times(&self, key: &str) -> Vec<f64> {
        if let Some(t) = self.cache.borrow().get(key) {
            return t.clone();
        }
        let t = self.store.times(key);
        self.cache.borrow_mut().insert(key.to_string(), t.clone());
        t
    }

    /// Tracking (or anything else) changed the stored mattes: every key is read again on its next ask.
    pub fn forget(&self) {
        self.cache.borrow_mut().clear();
        self.bump();
    }

    /// Deletes the mattes at `times` (source seconds) of `key` from the store and its file. Returns what went (for undo).
    pub fn remove(&self, key: &str, times: &[f64]) -> MagicFrameSnapshot {
        let snap = self.store.snapshot_frames(key, times);
        if times.is_empty() {
            return snap;
        }
        self.store.remove_frames(key, times);
        self.store.save(key);
        if let Some(t) = self.cache.borrow_mut().get_mut(key) {
            t.retain(|p| !times.iter().any(|x| (x - p).abs() < 1e-6));
        }
        self.bump();
        snap
    }

    /// Redo of a delete: removes the frames of `snapshot`, leaving a frame that was tracked again at the same time since.
    pub fn remove_matching(&self, snapshot: &MagicFrameSnapshot) {
        let gone = self.store.remove_frames_matching(snapshot);
        if gone.is_empty() {
            return;
        }
        self.store.save(snapshot.store_key());
        if let Some(t) = self.cache.borrow_mut().get_mut(snapshot.store_key()) {
            t.retain(|p| !gone.iter().any(|x| (x - p).abs() < 1e-6));
        }
        self.bump();
    }

    /// Puts back frames `remove` returned (undo of a delete).
    pub fn restore(&self, snapshot: &MagicFrameSnapshot) {
        if snapshot.is_empty() {
            return;
        }
        self.store.restore(snapshot);
        self.store.save(snapshot.store_key());
        self.cache.borrow_mut().remove(snapshot.store_key());
        self.bump();
    }

    /// `MagicFrameKey::keys` of `mask` under `key`.
    pub fn keys(&self, clip: &Clip, mask: &ClipMask, key: &str, frame_duration: Time) -> Vec<MagicFrameKey> {
        MagicFrameKey::keys(clip, mask, &self.times(key), frame_duration)
    }

    fn bump(&self) {
        self.revision.set(self.revision.get() + 1);
    }
}

/// One tracked frame of a Magic mask as a key in the lanes. Not movable or easable; deletable.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MagicFrameKey {
    /// Stable per mask and frame (the selection holds it).
    pub id: Id,
    /// Clip-local.
    pub time: Time,
    /// Source seconds as stored (`MagicMatteStore`).
    pub pts: f64,
    /// A correction point was set on this frame: drawn as a normal key, deleting it also drops the point.
    pub is_correction: bool,
    /// Seconds this source frame is shown (to the next frame of the file).
    pub span: f64,
}

impl MagicFrameKey {
    /// Whether `p` is a correction point made on this frame. The pick's own points never are.
    pub fn holds_correction(&self, p: &sq_core_model::MagicPoint, anchor: Option<Time>) -> bool {
        if Some(p.source_time) == anchor {
            return false;
        }
        MagicFollower::belongs(
            p.source_time.value() as f64 / p.source_time.timescale().max(1) as f64,
            self.pts,
            self.span,
        )
    }

    /// The tracked frames `times` (source seconds) of `mask` that fall inside `clip`, one per clip frame, as lane keys.
    pub fn keys(clip: &Clip, mask: &ClipMask, times: &[f64], frame_duration: Time) -> Vec<MagicFrameKey> {
        let points: &[sq_core_model::MagicPoint] = mask.magic.as_ref().map_or(&[], |m| m.points.as_slice());
        let anchor = mask.magic.as_ref().and_then(|m| m.anchor_time());
        let fd = if frame_duration > Time::ZERO { frame_duration } else { Time::new(1, 30) };
        // The file's frame spacing: the smallest step between tracked frames (the sequence's frame when that says nothing).
        let mut sorted = times.to_vec();
        sorted.sort_by(f64::total_cmp);
        let step = sorted.windows(2).map(|w| w[1] - w[0]).filter(|d| *d > 1e-6).fold(f64::INFINITY, f64::min);
        let span = if step <= 0.1 { step } else { fd.value() as f64 / fd.timescale().max(1) as f64 };
        let mut out: Vec<MagicFrameKey> = Vec::new();
        let mut seen: std::collections::BTreeSet<Time> = std::collections::BTreeSet::new();
        for pts in times {
            let src = Time::new((pts * 1_000_000.0).round() as i64, 1_000_000);
            let local = (clip.timeline_time_for_source(src, frame_duration) - clip.start).snapped(fd);
            if local < Time::ZERO || local >= clip.duration() || !seen.insert(local) {
                continue;
            }
            let mut key =
                MagicFrameKey { id: Self::id(mask.id, *pts), time: local, pts: *pts, is_correction: false, span };
            key.is_correction = points.iter().any(|p| key.holds_correction(p, anchor));
            out.push(key);
        }
        out.sort_by_key(|k| k.time);
        out
    }

    /// The mask's id with the frame's time mixed into its last 8 bytes.
    pub fn id(mask: Id, pts: f64) -> Id {
        let bits = ((pts * 1_000_000.0).round() as i64) as u64;
        let mut u = mask.as_u128();
        for i in 0..8 {
            u ^= u128::from((bits >> (8 * i)) as u8) << (8 * (7 - i));
        }
        Id::from_u128(u)
    }
}
