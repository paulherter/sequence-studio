// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagicMatteStore+Unavailable.swift (the `!canImport(Vision)` form; the Mac store lives in MagicMask.swift, not ported)
//! This is the non-Vision form of Swift's store: empty, keeps nothing, and no Rust build uses it. Every OS, the Mac
//! included, runs Magic Mask through `FrameMatteStore`, the portable store that really keeps mattes.

/// Some stored frames of one key (none here): the undo state of deleting tracked frames.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MagicFrameSnapshot {
    key: String,
}

impl MagicFrameSnapshot {
    /// Always empty.
    pub fn is_empty(&self) -> bool {
        true
    }

    /// Always 0.
    pub fn count(&self) -> usize {
        0
    }

    /// Always empty.
    pub fn times(&self) -> Vec<f64> {
        Vec::new()
    }

    /// The key the frames belonged to.
    pub fn store_key(&self) -> &str {
        &self.key
    }
}

/// Per-frame Magic mattes by cache key: always empty here.
#[derive(Clone, Copy, Debug, Default)]
pub struct MagicMatteStore;

static SHARED: MagicMatteStore = MagicMatteStore;

impl MagicMatteStore {
    /// The app's store.
    pub fn shared() -> &'static MagicMatteStore {
        &SHARED
    }

    /// An empty store.
    pub fn new() -> MagicMatteStore {
        MagicMatteStore
    }

    /// Always empty.
    pub fn times(&self, _key: &str) -> Vec<f64> {
        Vec::new()
    }

    /// Removes nothing; returns 0.
    pub fn remove_frames(&self, _key: &str, _times: &[f64]) -> usize {
        0
    }

    /// Removes nothing; returns no times.
    pub fn remove_frames_matching(&self, _snapshot: &MagicFrameSnapshot) -> Vec<f64> {
        Vec::new()
    }

    /// An empty snapshot of `key`.
    pub fn snapshot_frames(&self, key: &str, _times: &[f64]) -> MagicFrameSnapshot {
        MagicFrameSnapshot { key: key.to_string() }
    }

    /// Restores nothing.
    pub fn restore(&self, _snapshot: &MagicFrameSnapshot) {}

    /// Saves nothing.
    pub fn save(&self, _key: &str) {}

    /// Saves nothing.
    pub fn save_later(&self, _key: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_store_is_always_empty_and_keeps_nothing() {
        let s = MagicMatteStore::shared();
        assert!(s.times("k").is_empty());
        assert_eq!(s.remove_frames("k", &[1.0]), 0);
        let snap = s.snapshot_frames("k", &[1.0]);
        assert!(snap.is_empty() && snap.count() == 0 && snap.times().is_empty());
        assert_eq!(snap.store_key(), "k");
        assert!(s.remove_frames_matching(&snap).is_empty());
    }
}
