// Swift: WhiteBalanceSolver.swift
//! White-balance eyedropper maths. Given a color sampled from the Program monitor (working-linear Rec.709, i.e. after
//! everything the clip already has) it returns the Temperature and Tint that make that color neutral. The sample already
//! contains the current Temperature/Tint, so the correction is found as an extra white balance on top of it and added to
//! the current values (mired offsets, so the sum is exact for Temperature and a close approximation for Tint).

use sq_core_model::BasicCorrection;

use super::gamut::Gamut;
use super::stages::PreparedBasic;
use super::vec::Vec3;

/// The solved sliders.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WhiteBalanceResult {
    /// Temperature slider, one decimal.
    pub temperature: f32,
    /// Tint slider, one decimal.
    pub tint: f32,
    /// The pick is too saturated: a slider hit its end (+-100) and the result is not fully neutral.
    pub clamped: bool,
}

/// The eyedropper solver.
pub struct WhiteBalanceSolver;

impl WhiteBalanceSolver {
    /// Temperature and tint that make `picked` neutral, or `None` for an unusable sample.
    pub fn solve(picked: Vec3, temperature: f32, tint: f32) -> Option<WhiteBalanceResult> {
        if !(picked.is_finite() && picked.y > 1e-4 && picked.x >= 0.0 && picked.z >= 0.0) {
            return None;
        }
        // Error = chromaticity ratios of the corrected pick; zero when r = g = b.
        let err = |t: f32, n: f32| -> [f32; 2] {
            let b = BasicCorrection { temperature: t, tint: n, ..BasicCorrection::default() };
            let c = PreparedBasic::new(&b, Gamut::rec709()).wb.mul_vec(picked);
            [c.x / c.y - 1.0, c.z / c.y - 1.0]
        };
        let (mut t, mut n) = (0f32, 0f32);
        let h = 0.5f32;
        for _ in 0..24 {
            let e = err(t, n);
            if (e[0] * e[0] + e[1] * e[1]).sqrt() < 1e-5 {
                break;
            }
            let (tp, tm) = (err(t + h, n), err(t - h, n));
            let (np, nm) = (err(t, n + h), err(t, n - h));
            let et = [(tp[0] - tm[0]) / (2.0 * h), (tp[1] - tm[1]) / (2.0 * h)];
            let en = [(np[0] - nm[0]) / (2.0 * h), (np[1] - nm[1]) / (2.0 * h)];
            // The 2x2 matrix has the columns (et, en); `d` solves `j * d = e`.
            let det = et[0] * en[1] - en[0] * et[1];
            if det.abs() <= 1e-12 {
                break;
            }
            let d = [(e[0] * en[1] - en[0] * e[1]) / det, (et[0] * e[1] - e[0] * et[1]) / det];
            t = (t - d[0]).clamp(-200.0, 200.0);
            n = (n - d[1]).clamp(-200.0, 200.0);
        }
        let (wt, wn) = (temperature + t, tint + n);
        let rt = wt.clamp(-100.0, 100.0);
        let rn = wn.clamp(-100.0, 100.0);
        Some(WhiteBalanceResult {
            temperature: (rt * 10.0).round() / 10.0,
            tint: (rn * 10.0).round() / 10.0,
            clamped: wt.abs() > 100.0 || wn.abs() > 100.0,
        })
    }
}

#[cfg(test)]
mod clamp_tests {
    use super::*;

    #[test]
    fn a_saturated_pick_reports_that_it_clamped_and_a_gray_does_not() {
        let gray = WhiteBalanceSolver::solve(Vec3::new(0.5, 0.5, 0.5), 0.0, 0.0).expect("gray solves");
        assert!(!gray.clamped);
        let red = WhiteBalanceSolver::solve(Vec3::new(1.0, 0.02, 0.0), 0.0, 0.0).expect("red solves");
        assert!(red.clamped, "{red:?}");
    }
}
