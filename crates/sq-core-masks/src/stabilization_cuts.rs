// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizationCuts.swift
//! Scene cuts in edited footage. A registration nearly always "matches" two frames, even across a cut (Vision returned
//! zoom 0.84 / 8 degree turns there), so a cut is also recognized from how the picture changed: a jump in the color
//! histogram, a jump in the photometric residual left after aligning the frames, or a frame-to-frame zoom / turn no
//! hand-held camera makes. Jumps are judged against the neighboring frames (local median), so a busy scene or a whip pan
//! that changes a lot on every frame is no cut.

use crate::stabilizer::{CameraMotion, Stabilizer};

/// Which score found a cut (the first that fires, in this order). Diagnostics.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CutReason {
    /// Color histogram jump.
    Histogram,
    /// Photometric residual jump.
    Residual,
    /// Zoom or turn no camera makes.
    Motion,
}

/// Cut detection.
pub struct StabilizationCuts;

impl StabilizationCuts {
    /// Neighbors on each side for the local median (the frame itself and its direct neighbors are left out).
    const WINDOW: usize = 15;
    /// A histogram cut needs at least this distance (0...1, half L1 of normalized histograms) ...
    const HISTOGRAM_FLOOR: f64 = 0.15;
    /// ... and more than `JUMP_FACTOR` x the local median + this.
    const HISTOGRAM_MARGIN: f64 = 0.08;
    /// Mean absolute gray difference (0...255) after alignment: at least this ...
    const RESIDUAL_FLOOR: f64 = 10.0;
    /// ... more than `JUMP_FACTOR` x the local median + this.
    const RESIDUAL_MARGIN: f64 = 4.0;
    const JUMP_FACTOR: f64 = 3.0;
    /// Frame-to-frame zoom (|log scale| beyond the local median) no camera makes in one frame.
    const MAX_LOG_SCALE_STEP: f64 = 0.1;
    /// Frame-to-frame turn (degrees) no camera makes in one frame.
    const MAX_TURN_STEP: f64 = 5.0;

    /// Frame indices (> 0) where a new shot starts. Scores are per frame (index i: frame i-1 to frame i, index 0 ignored);
    /// an empty or short score array is not used.
    ///
    /// A cut only matters to the stabilizer where the camera path cannot be followed across it, so two refinements (both
    /// off when the arrays are empty):
    /// - `confidence[k]` (Vision and the independent check agree, `Stabilizer::MIN_CONFIDENCE`): a histogram or residual
    ///   jump on a pair both registrations agree on is a light / exposure change or a passing subject, no cut.
    /// - `checks[k]` (the check's own motion, `None` where it could not measure): a zoom / turn jump only Vision sees,
    ///   while the check measures the steady camera, is Vision's error (low confidence replaces it), no cut.
    pub fn detect(
        motions: &[CameraMotion],
        histogram: &[f64],
        residual: &[f64],
        checks: &[Option<CameraMotion>],
        confidence: &[f64],
    ) -> Vec<usize> {
        Self::detect_with_reasons(motions, histogram, residual, checks, confidence).into_iter().map(|c| c.0).collect()
    }

    /// `detect` with the score that fired per cut.
    pub fn detect_with_reasons(
        motions: &[CameraMotion],
        histogram: &[f64],
        residual: &[f64],
        checks: &[Option<CameraMotion>],
        confidence: &[f64],
    ) -> Vec<(usize, CutReason)> {
        let n = motions.len();
        if n <= 1 {
            return Vec::new();
        }
        let log_of = |m: &CameraMotion| if m.scale.is_finite() && m.scale > 0.0 { m.scale.ln() } else { 0.0 };
        let log_scale: Vec<f64> = motions.iter().map(log_of).collect();
        let turn: Vec<f64> = motions.iter().map(|m| m.rotation).collect();
        let jumps_in_motion = |m: &CameraMotion, k: usize| -> bool {
            (log_of(m) - Self::local_median(&log_scale, k)).abs() > Self::MAX_LOG_SCALE_STEP
                || (m.rotation - Self::local_median(&turn, k)).abs() > Self::MAX_TURN_STEP
        };
        let mut cuts = Vec::new();
        for k in 1..n {
            let agreed = k < confidence.len() && confidence[k] >= Stabilizer::MIN_CONFIDENCE;
            if !agreed {
                if Self::jumps(histogram, k, Self::HISTOGRAM_FLOOR, Self::HISTOGRAM_MARGIN) {
                    cuts.push((k, CutReason::Histogram));
                    continue;
                }
                if Self::jumps(residual, k, Self::RESIDUAL_FLOOR, Self::RESIDUAL_MARGIN) {
                    cuts.push((k, CutReason::Residual));
                    continue;
                }
            }
            if jumps_in_motion(&motions[k], k) {
                if k < checks.len()
                    && let Some(c) = &checks[k]
                    && !jumps_in_motion(c, k)
                {
                    continue;
                }
                cuts.push((k, CutReason::Motion));
            }
        }
        cuts
    }

    /// The local median a score at `k` is judged against (diagnostics).
    pub fn local_reference(xs: &[f64], k: usize) -> f64 {
        Self::local_median(xs, k)
    }

    fn jumps(xs: &[f64], k: usize, floor: f64, margin: f64) -> bool {
        if !(k < xs.len() && xs[k].is_finite() && xs[k] >= floor) {
            return false;
        }
        xs[k] > Self::JUMP_FACTOR * Self::local_median(xs, k) + margin
    }

    /// Median of xs[k-window ... k+window] without k-1, k, k+1 (a one-frame flash flags both its frames); 0 when empty.
    fn local_median(xs: &[f64], k: usize) -> f64 {
        let lo = k.saturating_sub(Self::WINDOW).max(1);
        let hi = (xs.len() as i64 - 1).min((k + Self::WINDOW) as i64);
        if (lo as i64) > hi {
            return 0.0; // fewer than two scores: a bare range would trap
        }
        let mut v: Vec<f64> =
            (lo..=hi as usize).filter(|i| i.abs_diff(k) > 1 && xs[*i].is_finite()).map(|i| xs[i]).collect();
        if v.is_empty() {
            return 0.0;
        }
        v.sort_by(f64::total_cmp);
        v[v.len() / 2]
    }
}
