// Swift: DuckPreset.swift
//! One-click live duck settings: an amount plus a timing. Unsourced values, tuned by ear for TikTok-style speech.

use sq_core_audio::{DuckTimingExt, Ducking};
use sq_core_model::DuckTiming;

/// A named amount plus timing.
#[derive(Clone, Debug, PartialEq)]
pub struct DuckPreset {
    /// Menu title.
    pub title: &'static str,
    /// Duck depth in dB.
    pub amount_db: f64,
    /// Attack, hold and recovery.
    pub timing: DuckTiming,
}

impl DuckPreset {
    /// Voice-over under a steady bed: shallow duck, slow recovery so the music swells back gently.
    pub fn soft() -> DuckPreset {
        DuckPreset {
            title: "Soft (voice-over)",
            amount_db: 9.0,
            timing: DuckTiming {
                lookahead_ms: 30.0,
                attack_ms: 250.0,
                hold_ms: 300.0,
                recovery_ms: 1200.0,
                min_pause_ms: 500.0,
            },
        }
    }

    /// Fast speech: deep duck, quick ramps, short breaths bridged so the music does not pump.
    pub fn hard() -> DuckPreset {
        DuckPreset {
            title: "Hard (fast speech)",
            amount_db: 18.0,
            timing: DuckTiming {
                lookahead_ms: 15.0,
                attack_ms: 40.0,
                hold_ms: 200.0,
                recovery_ms: 500.0,
                min_pause_ms: 350.0,
            },
        }
    }

    /// Both presets, soft first.
    pub fn all() -> [DuckPreset; 2] {
        [Self::soft(), Self::hard()]
    }

    /// The preset matching `amount_db` and `timing`, if any.
    pub fn matching(amount_db: f64, timing: &DuckTiming) -> Option<DuckPreset> {
        let clamped = timing.clamped();
        Self::all().into_iter().find(|p| p.amount_db == amount_db && p.timing == clamped)
    }

    /// Any amount the user types: finite, above 0 (0 = off), at most 40 dB, rounded to 0.5 dB.
    pub fn clamped_amount(db: f64) -> f64 {
        if !db.is_finite() {
            return Ducking::DEFAULT_AMOUNT_DB;
        }
        (db.clamp(0.5, 40.0) * 2.0).round() / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_differ_and_match() {
        assert!(DuckPreset::soft().amount_db < DuckPreset::hard().amount_db);
        assert_eq!(DuckPreset::matching(18.0, &DuckPreset::hard().timing), Some(DuckPreset::hard()));
        assert_eq!(DuckPreset::matching(12.0, &DuckPreset::hard().timing), None);
    }

    #[test]
    fn amount_is_clamped() {
        assert_eq!(DuckPreset::clamped_amount(100.0), 40.0);
        assert_eq!(DuckPreset::clamped_amount(-3.0), 0.5);
        assert_eq!(DuckPreset::clamped_amount(7.3), 7.5);
        assert_eq!(DuckPreset::clamped_amount(f64::NAN), Ducking::DEFAULT_AMOUNT_DB);
    }

    #[test]
    fn preset_timings_survive_clamping() {
        for p in DuckPreset::all() {
            assert_eq!(p.timing, p.timing.clamped());
        }
    }
}
