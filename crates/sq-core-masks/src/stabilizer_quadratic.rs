// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizerQuadratic.swift
//! Stabilizer v2 smoothing: the wanted camera path minimizes the distance to the real path plus a per-frame weighted
//! second difference (a quadratic path optimization, one banded solve per channel). The weights start equal and are
//! relaxed around every frame whose picture would not cover its frame within the crop limit, then the path is solved
//! again, until all frames pass. So the smoothing is not a fixed width: it gives way exactly where the crop limit would be
//! violated.

use crate::stabilizer::{CameraPose, Stabilizer};
use sq_core_time::Vec2;

impl Stabilizer {
    /// Solves (I + D^T diag(lambda) D) s = p for a pentadiagonal SPD system; D rows are second differences, `lambda[r]`
    /// weighs the row centered on frame r + 1 (count n - 2). Straight lines are not changed, the ends stay free.
    /// With `data_weight` mu the system is (diag(mu) + D^T diag(lambda) D) s = mu * p.
    pub(crate) fn solve_second_difference(p: &[f64], lambda: &[f64], data_weight: Option<&[f64]>) -> Vec<f64> {
        let n = p.len();
        if !(n > 2 && lambda.len() == n - 2) {
            return p.to_vec();
        }
        // Bands of the symmetric matrix: d[i] = A[i][i], e[i] = A[i][i+1], f[i] = A[i][i+2].
        let mut d: Vec<f64> = data_weight.map_or_else(|| vec![1.0; n], <[f64]>::to_vec);
        let mut e = vec![0.0_f64; n];
        let mut f = vec![0.0_f64; n];
        for r in 0..n - 2 {
            let l = lambda[r];
            // Row r = (1, -2, 1) on frames r, r + 1, r + 2.
            d[r] += l;
            d[r + 1] += 4.0 * l;
            d[r + 2] += l;
            e[r] -= 2.0 * l;
            e[r + 1] -= 2.0 * l;
            f[r] += l;
        }
        // LDL^T for bandwidth 2.
        let mut ld = d;
        let mut l1 = e.clone(); // l1[i] = L[i+1][i]
        let mut l2 = f.clone(); // l2[i] = L[i+2][i] (after the loop)
        let mut x: Vec<f64> = match data_weight {
            Some(w) => (0..n).map(|i| w[i] * p[i]).collect(),
            None => p.to_vec(),
        };
        for i in 0..n {
            if i >= 1 {
                ld[i] -= l1[i - 1] * l1[i - 1] * ld[i - 1];
            }
            if i >= 2 {
                ld[i] -= l2[i - 2] * l2[i - 2] * ld[i - 2];
            }
            if i + 1 < n {
                let mut v = e[i];
                if i >= 1 {
                    v -= l1[i - 1] * l2[i - 1] * ld[i - 1];
                }
                l1[i] = v / ld[i];
            }
            if i + 2 < n {
                l2[i] = f[i] / ld[i];
            }
        }
        for i in 0..n {
            // forward: L y = p
            if i >= 1 {
                x[i] -= l1[i - 1] * x[i - 1];
            }
            if i >= 2 {
                x[i] -= l2[i - 2] * x[i - 2];
            }
        }
        for i in 0..n {
            x[i] /= ld[i];
        }
        for i in (0..n).rev() {
            // backward: L^T s = z
            if i + 1 < n {
                x[i] -= l1[i] * x[i + 1];
            }
            if i + 2 < n {
                x[i] -= l2[i] * x[i + 2];
            }
        }
        x
    }

    /// The second-difference weight whose response matches a Gaussian of `sigma` frames at half amplitude.
    pub(crate) fn base_lambda(sigma: f64) -> f64 {
        let s = sigma / 1.1774;
        s * s * s * s
    }

    pub(crate) fn quadratic_path(real: &[CameraPose], lambda: &[f64]) -> Vec<CameraPose> {
        let channel = |f: fn(&CameraPose) -> f64| {
            Self::solve_second_difference(&real.iter().map(f).collect::<Vec<_>>(), lambda, None)
        };
        let tx = channel(|p| p.translation.x);
        let ty = channel(|p| p.translation.y);
        let r = channel(|p| p.rotation);
        let s = channel(|p| p.log_scale);
        (0..real.len()).map(|i| CameraPose::new(Vec2::new(tx[i], ty[i]), r[i], s[i])).collect()
    }

    /// The smoothed path of one segment, crop-aware: `fits(wanted, k)` says whether frame k stays within the crop limit.
    /// Frames that do not fit lower the weight of their neighbors (out to 3 sigma, Gaussian falloff) and the path is solved
    /// again; every 5th round the reach grows. Frames still violating after `rounds` follow the real path.
    pub(crate) fn adaptive_quadratic_path(
        real: &[CameraPose],
        sigma: f64,
        rounds: usize,
        fits: &dyn Fn(&CameraPose, usize) -> bool,
    ) -> Vec<CameraPose> {
        let n = real.len();
        if !(n > 2 && sigma.is_finite() && sigma > 0.0) {
            return real.to_vec();
        }
        let base = Self::base_lambda(sigma);
        let mut lambda = vec![base; n - 2];
        let mut reach = (sigma / 3.0).max(1.0);
        let mut wanted = Self::quadratic_path(real, &lambda);
        for round in 0..=rounds {
            let bad: Vec<usize> = (0..wanted.len()).filter(|&i| !fits(&wanted[i], i)).collect();
            if bad.is_empty() {
                return wanted;
            }
            if round == rounds {
                return (0..wanted.len()).map(|i| if fits(&wanted[i], i) { wanted[i] } else { real[i] }).collect();
            }
            let span = (3.0 * reach).ceil() as i64;
            for b in bad {
                for k in -span..=span {
                    let row = b as i64 - 1 + k; // lambda row centered on frame b + k
                    if row < 0 || row >= n as i64 - 2 {
                        continue;
                    }
                    lambda[row as usize] *= 1.0 - 0.5 * (-((k * k) as f64) / (reach * reach)).exp();
                }
            }
            if round % 5 == 4 {
                reach += 2.0;
            }
            wanted = Self::quadratic_path(real, &lambda);
        }
        wanted
    }
}
