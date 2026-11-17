// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizerPerspective.swift
//! Stabilizer v2: the residual perspective. The analysis fits a homography per frame pair and reduces it to the camera
//! similarity (turn, zoom, shift). What the similarity cannot express stays here as `PerspectiveResidual`: the homography
//! R = S^-1 H of the pair, as eight numbers (R minus the identity, h33 = 1) in picture px about the picture center. The
//! residual path is the running sum of the pairs (first order: the terms are small), smoothed by the same second
//! difference solver as the similarity channels, scaled by Strength, and written as the Stabilizer's perspective keys.
//! The render side warps with I + correction in the existing Stabilizer warp pass, before the stage's similarity: one
//! resampling for both.
// Same as Swift (StabilizerPerspective.swift:10): the weights are the base ones (the crop-aware relaxing of the similarity does not apply, the edge is held in
// the warp instead), and a pair below `Stabilizer::MIN_CONFIDENCE` contributes no residual; upgrade when a clip shows it.

use crate::stabilizer::{FramePick, StabilizationAnalysis, StabilizationPlan, Stabilizer, pick_frame};
use sq_core_time::{Time, Vec2};
use std::ops::Range;

/// A homography near the identity: `values` = (m00-1, m01, m02, m10, m11-1, m12, m20, m21) of the 3x3 map
/// p -> (m00 x + m01 y + m02, m10 x + m11 y + m12) / (m20 x + m21 y + 1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PerspectiveResidual {
    /// The eight numbers.
    pub values: [f64; 8],
}

impl PerspectiveResidual {
    /// The identity.
    pub const ZERO: PerspectiveResidual = PerspectiveResidual { values: [0.0; 8] };

    /// From a slice; anything but eight numbers is the identity, like the Swift initializer.
    pub fn new(values: &[f64]) -> PerspectiveResidual {
        match <[f64; 8]>::try_from(values) {
            Ok(values) => PerspectiveResidual { values },
            Err(_) => PerspectiveResidual::ZERO,
        }
    }

    /// Every value is 0.
    pub fn is_zero(&self) -> bool {
        self.values.iter().all(|v| *v == 0.0)
    }

    /// The map this residual describes.
    pub fn map(&self, p: Vec2) -> Vec2 {
        let v = &self.values;
        let w = v[6] * p.x + v[7] * p.y + 1.0;
        if w.abs() <= 1e-9 {
            return p;
        }
        Vec2::new(((1.0 + v[0]) * p.x + v[1] * p.y + v[2]) / w, (v[3] * p.x + (1.0 + v[4]) * p.y + v[5]) / w)
    }

    /// The residual of the map `m` (row-major 3x3, any h33 != 0), `None` when degenerate or not finite.
    pub fn from_matrix(m: &[f64]) -> Option<PerspectiveResidual> {
        if m.len() != 9 || m[8].abs() <= 1e-12 {
            return None;
        }
        let k = 1.0 / m[8];
        let v = [m[0] * k - 1.0, m[1] * k, m[2] * k, m[3] * k, m[4] * k - 1.0, m[5] * k, m[6] * k, m[7] * k];
        v.iter().all(|x| x.is_finite()).then_some(PerspectiveResidual { values: v })
    }

    /// The same map in a picture whose x and y are scaled by `fx`, `fy` (analysis px -> picture px): D R D^-1.
    pub fn scaled(&self, fx: f64, fy: f64) -> PerspectiveResidual {
        let v = &self.values;
        PerspectiveResidual {
            values: [v[0], v[1] * fx / fy, v[2] * fx, v[3] * fy / fx, v[4], v[5] * fy, v[6] / fx, v[7] / fy],
        }
    }

    /// Blend towards `o`, `f` = 0 is self.
    pub fn lerp(&self, o: &PerspectiveResidual, f: f64) -> PerspectiveResidual {
        PerspectiveResidual { values: std::array::from_fn(|i| self.values[i] + (o.values[i] - self.values[i]) * f) }
    }

    /// Largest stored size, for deciding whether anything is left to warp.
    pub fn magnitude(&self) -> f64 {
        self.values.iter().map(|v| v.abs()).fold(0.0, f64::max)
    }
}

/// The eight stored perspective correction keys (never rename), generated data like the stage keys.
pub fn stabilize_perspective_keys() -> Vec<String> {
    (0..8).map(|i| format!("stabilizePerspective{i}")).collect()
}

impl Stabilizer {
    /// Smallest correction worth a warp: below it the keys are not written (no pass for nothing).
    pub const PERSPECTIVE_FLOOR: f64 = 1e-9;

    /// The perspective correction per analyzed frame (`n` entries), or empty when no frame needs one. `skip[i]`: segment i
    /// is left uncorrected (the guard's verdict). Pairs are the analysis' residuals, each pair `i` taking frame i-1 to i.
    pub(crate) fn perspective_corrections(
        a: &StabilizationAnalysis,
        n: usize,
        segments: &[Range<usize>],
        skip: &[bool],
        locked: bool,
        sigma: f64,
        strength: f64,
    ) -> Vec<PerspectiveResidual> {
        if !(a.perspective.len() >= n && strength > 0.0 && a.perspective.iter().any(|p| !p.is_zero())) {
            return Vec::new();
        }
        let mut out = vec![PerspectiveResidual::ZERO; n];
        for (i, seg) in segments.iter().enumerate() {
            if skip[i] || seg.len() <= 2 {
                continue;
            }
            // Running sum of the pairs from the segment start; untrusted pairs add nothing. Stored confidence: the check
            // vouches for the similarity only, so a poor-inlier homography stays untrusted when the check agrees.
            let mut real = vec![[0.0_f64; 8]; seg.len()];
            for (j, k) in seg.clone().enumerate() {
                if j == 0 {
                    continue;
                }
                let pair =
                    if a.stored_confidence(k) >= Self::MIN_CONFIDENCE { a.perspective[k].values } else { [0.0; 8] };
                for c in 0..8 {
                    real[j][c] = real[j - 1][c] + pair[c];
                }
            }
            let mut wanted = real.clone();
            if locked {
                let mean: Vec<f64> =
                    (0..8).map(|c| real.iter().fold(0.0, |s, r| s + r[c]) / seg.len() as f64).collect();
                for w in &mut wanted {
                    w.copy_from_slice(&mean);
                }
            } else if sigma.is_finite() && sigma > 0.0 {
                let lambda = vec![Self::base_lambda(sigma); seg.len() - 2];
                let channels: Vec<Vec<f64>> = (0..8)
                    .map(|c| {
                        Self::solve_second_difference(&real.iter().map(|r| r[c]).collect::<Vec<_>>(), &lambda, None)
                    })
                    .collect();
                for (j, w) in wanted.iter_mut().enumerate() {
                    for c in 0..8 {
                        w[c] = channels[c][j];
                    }
                }
            }
            for (j, k) in seg.clone().enumerate() {
                let mut values = [0.0; 8];
                for c in 0..8 {
                    values[c] = strength * (wanted[j][c] - real[j][c]);
                }
                out[k] = PerspectiveResidual { values };
            }
        }
        if out.iter().any(|p| p.magnitude() > Self::PERSPECTIVE_FLOOR) { out } else { Vec::new() }
    }

    /// The perspective correction at source time `t`: the analyzed frame's own, linear between two analyzed frames, held
    /// before the first, after the last and across a cut (as `correction`). Zero when the plan has none.
    pub fn perspective_correction(
        plan: &StabilizationPlan,
        analysis: &StabilizationAnalysis,
        t: Time,
    ) -> PerspectiveResidual {
        let cs = &plan.perspective;
        let n = cs.len().min(analysis.frame_times.len());
        match pick_frame(&analysis.frame_times, n, &analysis.cuts, t) {
            FramePick::Empty => PerspectiveResidual::ZERO,
            FramePick::Held(i) => cs[i],
            FramePick::Between(i, f) => cs[i].lerp(&cs[i + 1], f),
        }
    }

    /// Largest error of a stored perspective key against the exact correction, per key: every term moves a picture corner
    /// by at most 0.1 px.
    pub fn perspective_tolerances(picture_width: i64, picture_height: i64) -> [f64; 8] {
        let reach = (picture_width.max(picture_height) as f64 / 2.0).max(1.0);
        [0.1 / reach, 0.1 / reach, 0.1, 0.1 / reach, 0.1 / reach, 0.1, 0.1 / (reach * reach), 0.1 / (reach * reach)]
    }
}
