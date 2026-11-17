//! What the speed band hands the host: one edit of a clip's speed track, and the key or transition Delete acts on.

use sq_core_model::SpeedKeys;
use sq_core_time::Id;

use super::speed_band::SpeedBandHit;

/// Phase of a speed band drag.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedEditPhase {
    Began,
    Changed,
    Ended,
}

/// One speed band edit for the host: the clip and its new speed track. `keeping_keys` comes from the track at mouse-down
/// (`SpeedBandGesture::keeps_keys`), so every change of one drag is decided the same way.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedEdit {
    // Swift: SpeedEdit.swift:8
    pub clip: Id,
    // Swift: SpeedEdit.swift:9
    pub keys: SpeedKeys,
    // Swift: SpeedEdit.swift:10
    pub phase: SpeedEditPhase,
    // Swift: SpeedEdit.swift:11
    pub keeping_keys: bool,
}

impl SpeedEdit {
    /// `keeping_keys` is false in Swift's default.
    // Swift: SpeedEdit.swift:12
    pub fn new(clip: Id, keys: SpeedKeys, phase: SpeedEditPhase, keeping_keys: bool) -> SpeedEdit {
        SpeedEdit { clip, keys, phase, keeping_keys }
    }
}

/// Which kind of band element a [`SpeedBandKeyHit`] is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedBandKeyKind {
    Key(usize),
    Ramp(usize),
}

/// A key or a transition of a speed band (what the context menu and Delete act on).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeedBandKeyHit {
    // Swift: SpeedEdit.swift:21
    pub hit: SpeedBandKeyKind,
}

impl SpeedBandKeyHit {
    // Swift: SpeedEdit.swift:22
    pub fn new(hit: SpeedBandKeyKind) -> SpeedBandKeyHit {
        SpeedBandKeyHit { hit }
    }

    // Swift: SpeedEdit.swift:23
    pub fn band(&self) -> SpeedBandHit {
        match self.hit {
            SpeedBandKeyKind::Key(b) => SpeedBandHit::Key(b),
            SpeedBandKeyKind::Ramp(i) => SpeedBandHit::Ramp(i),
        }
    }

    // Swift: SpeedEdit.swift:29
    pub fn title(&self) -> &'static str {
        match self.hit {
            SpeedBandKeyKind::Key(_) => "Delete Speed Keyframe",
            SpeedBandKeyKind::Ramp(_) => "Remove Speed Transition",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_hits_map_to_band_hits_and_titles() {
        let k = SpeedBandKeyHit::new(SpeedBandKeyKind::Key(2));
        assert_eq!((k.band(), k.title()), (SpeedBandHit::Key(2), "Delete Speed Keyframe"));
        let r = SpeedBandKeyHit::new(SpeedBandKeyKind::Ramp(1));
        assert_eq!((r.band(), r.title()), (SpeedBandHit::Ramp(1), "Remove Speed Transition"));
    }
}
