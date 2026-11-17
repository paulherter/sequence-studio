// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizerSolve.swift
//! Stabilizer rebuild, stage B: the wanted camera path is a bilateral low-pass of the real path (a temporal Gaussian whose
//! weights also fall with the distance between the two path values, so a sudden intended move such as a whip or a pan
//! start is followed instead of averaged away), blended per frame with the real path by a strength that steps down
//! wherever the picture would not cover its frame within the crop limit. The last step sets a still-violating frame to "no
//! correction", so the limit always holds.

use crate::stabilizer::{CameraPose, Stabilizer};
use sq_core_time::Vec2;

impl Stabilizer {
    /// Distance between two path values in px: translation plus the displacement of a point at `reach` from the center
    /// that turn and zoom cause (the L1 measure, cheap and monotone).
    pub(crate) fn path_distance(a: &CameraPose, b: &CameraPose, reach: f64) -> f64 {
        let dt = a.translation - b.translation;
        dt.x.abs()
            + dt.y.abs()
            + reach
                * ((a.rotation - b.rotation).abs() * std::f64::consts::PI / 180.0 + (a.log_scale - b.log_scale).abs())
    }

    /// Bilateral low-pass of a path: temporal Gaussian `sigma` frames, motion Gaussian `motion_sigma` px; the ends are
    /// reflected oddly (a straight line stays straight, the first and last pose stay).
    pub(crate) fn bilateral_smooth(poses: &[CameraPose], sigma: f64, motion_sigma: f64, reach: f64) -> Vec<CameraPose> {
        let n = poses.len();
        if !(n > 2 && sigma.is_finite() && sigma > 0.0 && motion_sigma > 0.0) {
            return poses.to_vec();
        }
        let radius = ((3.0 * sigma).ceil() as usize).min(n - 1);
        if radius == 0 {
            return poses.to_vec();
        }
        let at = |i: i64| -> CameraPose {
            if i >= 0 && (i as usize) < n {
                return poses[i as usize];
            }
            let edge = if i < 0 { 0 } else { n - 1 };
            let mirror = if i < 0 { ((-i) as usize).min(n - 1) } else { ((2 * (n as i64 - 1) - i).max(0)) as usize };
            let (e, m) = (poses[edge], poses[mirror]);
            CameraPose::new(
                e.translation * 2.0 - m.translation,
                2.0 * e.rotation - m.rotation,
                2.0 * e.log_scale - m.log_scale,
            )
        };
        let time: Vec<f64> = (0..=radius).map(|k| (-((k * k) as f64) / (2.0 * sigma * sigma)).exp()).collect();
        let m2 = 2.0 * motion_sigma * motion_sigma;
        (0..n)
            .map(|t| {
                let c = poses[t];
                let (mut sum, mut tx, mut ty, mut rot, mut scale) = (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
                for k in -(radius as i64)..=(radius as i64) {
                    let p = at(t as i64 + k);
                    let d = Self::path_distance(&c, &p, reach);
                    let w = time[k.unsigned_abs() as usize] * (-(d * d) / m2).exp();
                    sum += w;
                    tx += w * p.translation.x;
                    ty += w * p.translation.y;
                    rot += w * p.rotation;
                    scale += w * p.log_scale;
                }
                if sum > 0.0 { CameraPose::new(Vec2::new(tx / sum, ty / sum), rot / sum, scale / sum) } else { c }
            })
            .collect()
    }

    /// The wanted path between the real one (`strength` 0) and the bilateral low-pass of it (1), per frame.
    #[doc(hidden)]
    pub fn blended(real: &[CameraPose], smooth: &[CameraPose], strength: &[f64]) -> Vec<CameraPose> {
        (0..real.len()).map(|i| CameraPose::lerp(&real[i], &smooth[i], strength[i])).collect()
    }
}
